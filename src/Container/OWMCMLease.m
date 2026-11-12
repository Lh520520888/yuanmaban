//
//  OWMCMLease.m
//  OPENsrc
//

#import "OWMCMLease.h"
#import "OWMCM.h"
#import "OWCommon.h"
#import <dlfcn.h>
#import <os/lock.h>

#pragma mark - libsandbox 函数指针

typedef int64_t (*ow_sbx_consume_t)(const char *extension);
typedef int     (*ow_sbx_release_t)(int64_t handle);

// token 拷贝在 OWMCM 里，这里通过 internal category 调用，避免重复 dlsym。
@interface OWMCM (LeaseInternal)
- (nullable id)copySandboxTokenForContainer:(OWMCMContainer *)c;
@end

static ow_sbx_consume_t gConsume = NULL;
static ow_sbx_release_t gRelease = NULL;
static void *gSbxHandle = NULL;

static const char * const kOWSbxLibPaths[] = {
    "/usr/lib/system/libsystem_sandbox.dylib",
    "/usr/lib/libsandbox.1.dylib",
    "/usr/lib/libSystem.B.dylib",       // 兜底：部分版本 sandbox 符号在 libSystem
    NULL,
};

#pragma mark - Lease 记录

@interface OWMCMLeaseRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) int64_t handle;
@property (nonatomic, assign) NSUInteger seq;      // 用于 LRU
@end
@implementation OWMCMLeaseRecord
@end

#pragma mark - OWMCMLease

@interface OWMCMLease ()
@property (nonatomic, assign, readwrite) BOOL available;
@property (nonatomic, strong) NSMutableArray<OWMCMLeaseRecord *> *records;
@property (nonatomic, assign) os_unfair_lock lock;
@property (nonatomic, assign) NSUInteger counter;
@end

@implementation OWMCMLease

+ (instancetype)shared {
    static OWMCMLease *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [OWMCMLease new];
        s.records = [NSMutableArray array];
        s.maxConcurrent = 3;          // 对齐目标包 active_leases=3
        s.lock = OS_UNFAIR_LOCK_INIT;
        s.available = [s bindSandbox];
    });
    return s;
}

- (BOOL)bindSandbox {
    // 依次尝试各库；关键不是「句柄拿到」而是「符号能取到」。
    // libSystem.B.dylib 一定能 dlopen 成功，所以要靠 dlsym 是否命中来判定。
    for (int i = 0; kOWSbxLibPaths[i]; i++) {
        void *h = dlopen(kOWSbxLibPaths[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            OWLog(@"OWLease: dlopen 失败 %s (%s)", kOWSbxLibPaths[i], dlerror());
            continue;
        }
        ow_sbx_consume_t c = (ow_sbx_consume_t)dlsym(h, "sandbox_extension_consume");
        if (!c) {
            OWLog(@"OWLease: %s 无 sandbox_extension_consume，试下一个", kOWSbxLibPaths[i]);
            dlclose(h);
            continue;
        }
        gSbxHandle = h;
        gConsume = c;
        gRelease = (ow_sbx_release_t)dlsym(h, "sandbox_extension_release");
        OWLog(@"OWLease: bind OK from %s (consume=1 release=%d)",
              kOWSbxLibPaths[i], !!gRelease);
        if (!gRelease) {
            OWLog(@"OWLease: sandbox_extension_release 缺失，handle 不会归还");
        }
        return YES;
    }
    OWLog(@"OWLease: 所有候选库都没有 sandbox_extension_consume");
    return NO;
}

#pragma mark 池管理

- (NSUInteger)activeCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger n = _records.count;
    os_unfair_lock_unlock(&_lock);
    return n;
}

- (BOOL)hasLeaseForPath:(NSString *)path {
    os_unfair_lock_lock(&_lock);
    BOOL hit = NO;
    for (OWMCMLeaseRecord *r in _records) {
        if ([r.path isEqualToString:path]) { hit = YES; break; }
    }
    os_unfair_lock_unlock(&_lock);
    return hit;
}

- (void)releaseRecordLocked:(OWMCMLeaseRecord *)r {
    if (r.handle > 0 && gRelease) {
        int rc = gRelease(r.handle);
        if (rc != 0) {
            OWLog(@"OWLease: release 失败 handle=%lld rc=%d", (long long)r.handle, rc);
        }
    }
    r.handle = 0;
}

// 锁内只做「摘出」，实际 release 放到锁外（gRelease 是系统调用，不能持锁）
- (NSArray<OWMCMLeaseRecord *> *)evictIfNeededLocked {
    NSMutableArray<OWMCMLeaseRecord *> *evicted = [NSMutableArray array];
    while (_records.count >= _maxConcurrent && _records.count > 0) {
        OWMCMLeaseRecord *oldest = _records.firstObject;
        OWLog(@"OWLease: 池满(%lu)，淘汰最旧 id=%@",
              (unsigned long)_maxConcurrent, oldest.identifier);
        [evicted addObject:oldest];
        [_records removeObjectAtIndex:0];
    }
    return evicted;
}

// 锁外统一释放一批
- (void)releaseRecords:(NSArray<OWMCMLeaseRecord *> *)records {
    for (OWMCMLeaseRecord *r in records) [self releaseRecordLocked:r];
}

#pragma mark 激活

- (BOOL)activateContainer:(OWMCMContainer *)container reason:(NSString **)reason {
    if (!container.path.length) {
        if (reason) *reason = @"容器路径为空";
        return NO;
    }
    if (!self.available) {
        if (reason) *reason = @"libsystem_sandbox 不可用";
        return NO;
    }

    // ---- 阶段 1：锁内只做查重 + 摘出待淘汰，不做 IO ----
    BOOL alreadyLeased = NO;
    NSArray<OWMCMLeaseRecord *> *evicted = nil;
    os_unfair_lock_lock(&_lock);
    for (OWMCMLeaseRecord *r in _records) {
        if ([r.path isEqualToString:container.path]) { alreadyLeased = YES; break; }
    }
    if (!alreadyLeased) evicted = [self evictIfNeededLocked];
    os_unfair_lock_unlock(&_lock);

    // 锁外真正释放被淘汰的 handle
    if (evicted.count) [self releaseRecords:evicted];

    if (alreadyLeased) return YES;           // 已有 lease

    // ---- 阶段 2：锁外取 token + consume（可能阻塞，不能持锁） ----
    NSString *token = container.sandboxToken;
    if (!token.length) {
        id tokenObj = [[OWMCM shared] copySandboxTokenForContainer:container];
        if ([tokenObj isKindOfClass:[NSString class]]) token = tokenObj;
    }
    if (!token.length) {
        if (reason) *reason = [NSString stringWithFormat:@"[%d] MCM object contained no sandbox token",
                               (int)OWMCMStatusNoSandboxToken];
        OWLog(@"OWLease: [%d] %@ 无 token（id=%@）",
              (int)OWMCMStatusNoSandboxToken, container.path, container.identifier);
        return NO;
    }

    int64_t handle = gConsume(token.UTF8String);
    if (handle <= 0) {
        if (reason) *reason = [NSString stringWithFormat:@"[%d] consume 失败 handle=%lld",
                               (int)OWMCMStatusTokenConsumeFail, (long long)handle];
        OWLog(@"OWLease: [%d] consume 失败 id=%@ handle=%lld",
              (int)OWMCMStatusTokenConsumeFail, container.identifier, (long long)handle);
        return NO;
    }

    // ---- 阶段 3：锁内入池 ----
    os_unfair_lock_lock(&_lock);
    OWMCMLeaseRecord *r = [OWMCMLeaseRecord new];
    r.path = container.path;
    r.identifier = container.identifier;
    r.handle = handle;
    r.seq = ++_counter;
    [_records addObject:r];

    NSUInteger now = _records.count;
    os_unfair_lock_unlock(&_lock);

    OWLog(@"OWLease: lease ok id=%@ handle=%lld active=%lu",
          container.identifier, (long long)handle, (unsigned long)now);
    return YES;
}

- (void)releasePath:(NSString *)path {
    if (!path) return;
    NSMutableArray<OWMCMLeaseRecord *> *kill = [NSMutableArray array];

    os_unfair_lock_lock(&_lock);
    NSMutableIndexSet *idx = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _records.count; i++) {
        if ([_records[i].path isEqualToString:path]) {
            [kill addObject:_records[i]];
            [idx addIndex:i];
        }
    }
    [_records removeObjectsAtIndexes:idx];
    os_unfair_lock_unlock(&_lock);

    [self releaseRecords:kill];   // 锁外释放
}

- (void)releaseAll {
    NSArray<OWMCMLeaseRecord *> *all;
    os_unfair_lock_lock(&_lock);
    all = [_records copy];
    [_records removeAllObjects];
    os_unfair_lock_unlock(&_lock);

    [self releaseRecords:all];    // 锁外释放
    OWLog(@"OWLease: 全部释放（%lu 个）", (unsigned long)all.count);
}

@end
