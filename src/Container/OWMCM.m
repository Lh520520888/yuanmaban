//
//  OWMCM.m
//  OPENsrc
//

#import "OWMCM.h"
#import "OWCommon.h"
#import <dlfcn.h>
#import <stdint.h>

#pragma mark - libcontainer 函数指针类型
// 签名按 Apple libcontainer（libsystem_container）公开形态；
// 用 void*/uint64_t 而非私有类型，避免依赖不存在的头文件。

typedef void *       (*ow_query_create_t)(void);
typedef void         (*ow_query_free_t)(void *query);
typedef void         (*ow_query_set_class_t)(void *query, uint64_t cls);
typedef void         (*ow_query_set_identifiers_t)(void *query, CFArrayRef ids);
typedef void         (*ow_query_set_group_identifiers_t)(void *query, CFArrayRef ids);
typedef void         (*ow_query_operation_set_flags_t)(void *query, uint64_t flags);
typedef void         (*ow_query_operation_set_part_t)(void *query, uint64_t part);
typedef void         (*ow_query_operation_set_part_domain_t)(void *query, uint64_t domain);
typedef bool         (*ow_query_iterate_results_sync_t)(void *query, void **error);
// 迭代接口：iterate_results_sync 之后反复调用，直到返回 NULL。
// get_single_result 只适用于「恰好一个结果」的查询，拿它当迭代器会一直返回同一对象。
typedef void *       (*ow_query_get_next_result_t)(void *query);
typedef void *       (*ow_query_get_single_result_t)(void *query);
typedef void *       (*ow_query_get_last_error_t)(void *query);
typedef void *       (*ow_object_copy_t)(void *obj);
typedef void         (*ow_object_free_t)(void *obj);
typedef const char * (*ow_object_get_identifier_t)(void *obj, void **error);
typedef const char * (*ow_object_get_path_t)(void *obj, void **error);
typedef bool         (*ow_object_sbx_activate_t)(void *obj);
typedef char *       (*ow_copy_sandbox_token_t)(void *obj);
typedef const char * (*ow_error_get_message_t)(void *query);
typedef int          (*ow_error_get_posix_errno_t)(void *query);

static const char * const kOWMCMLibPaths[] = {
    "/usr/lib/system/libsystem_container.dylib",
    "/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
    NULL,
};

// 目标包 bundle id —— containermanagerd 的 MCM 调用者白名单
static NSString * const kOWMHAIdentity = @"com.apple.mobile.MobileHouseArrest";

#pragma mark - 绑定表

typedef struct {
    ow_query_create_t                    query_create;
    ow_query_free_t                      query_free;
    ow_query_set_class_t                 query_set_class;
    ow_query_set_identifiers_t           query_set_identifiers;
    ow_query_set_group_identifiers_t     query_set_group_identifiers;
    ow_query_operation_set_flags_t       query_set_flags;
    ow_query_operation_set_part_t        query_set_part;
    ow_query_operation_set_part_domain_t query_set_part_domain;
    ow_query_iterate_results_sync_t      query_iterate;
    ow_query_get_next_result_t           query_get_next;
    ow_query_get_single_result_t         query_get_single;
    ow_query_get_last_error_t            query_get_error;
    ow_object_copy_t                     object_copy;
    ow_object_free_t                     object_free;
    ow_object_get_identifier_t           object_get_identifier;
    ow_object_get_path_t                 object_get_path;
    ow_object_sbx_activate_t             object_sbx_activate;
    ow_copy_sandbox_token_t              copy_sandbox_token;
    ow_error_get_message_t               error_get_message;
    ow_error_get_posix_errno_t           error_get_errno;
} OWMCMBindings;

static OWMCMBindings gOWMCMfns;
static void *gOWMCMhandle = NULL;

#pragma mark - 结果对象

@interface OWMCMContainer ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, assign, readwrite) OWMCMClass containerClass;
@property (nonatomic, assign, readwrite) void *rawObject;
@property (nonatomic, copy, readwrite, nullable) NSString *sandboxToken;
@property (nonatomic, assign, readwrite) void *query;   // 同一个批次共享，用计数管理
@end

// 一次枚举产生的 query 由该批次所有 container 共享，引用计数归零才 free。
// 这样避免 query_free 后 container 仍持有 rawObject（use-after-free），
// 也避免多个 container 各自 query_free（double free）。
static NSMutableDictionary<NSValue *, NSNumber *> *gOWQueryRefs = nil;
static NSLock *gOWQueryLock = nil;

static void OWQueryRetain(void *q) {
    if (!q || !gOWMCMfns.query_free) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOWQueryRefs = [NSMutableDictionary dictionary];
        gOWQueryLock = [NSLock new];
    });
    [gOWQueryLock lock];
    NSValue *k = [NSValue valueWithPointer:q];
    NSInteger n = gOWQueryRefs[k].integerValue;
    gOWQueryRefs[k] = @(n + 1);
    [gOWQueryLock unlock];
}

static void OWQueryRelease(void *q) {
    if (!q || !gOWMCMfns.query_free) return;
    [gOWQueryLock lock];
    NSValue *k = [NSValue valueWithPointer:q];
    NSInteger n = gOWQueryRefs[k].integerValue - 1;
    if (n <= 0) {
        [gOWQueryRefs removeObjectForKey:k];
        [gOWQueryLock unlock];
        gOWMCMfns.query_free(q);
    } else {
        gOWQueryRefs[k] = @(n);
        [gOWQueryLock unlock];
    }
}

@implementation OWMCMContainer

- (void)dealloc {
    if (_rawObject && gOWMCMfns.object_free) {
        gOWMCMfns.object_free(_rawObject);
        _rawObject = NULL;
    }
    if (_query) {
        OWQueryRelease(_query);
        _query = NULL;
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<MCM %@ id=%@ path=%@>",
            [OWMCM classNameFor:_containerClass], _identifier, _path];
}

@end

#pragma mark - OWMCM

@interface OWMCM ()
@property (nonatomic, assign, readwrite) BOOL available;
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@property (nonatomic, copy, readwrite, nullable) NSString *signedIdentity;
@property (nonatomic, assign, readwrite) BOOL identityOK;
@property (nonatomic, assign) OWMCMStatus prepared;
@property (nonatomic, strong) NSMutableString *missing;
@end

@implementation OWMCM

+ (instancetype)shared {
    static OWMCM *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OWMCM new]; });
    return s;
}

#pragma mark 绑定

- (void *)loadLibrary {
    if (gOWMCMhandle) return gOWMCMhandle;
    // 关键：MobileContainerManager 能 dlopen 成功，但它只导出 ObjC 类，
    // 不一定导出 container_* C 函数。所以判据是「关键符号能否取到」。
    for (int i = 0; kOWMCMLibPaths[i]; i++) {
        void *h = dlopen(kOWMCMLibPaths[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            OWLog(@"OWMCM: dlopen 失败 %s (%s)", kOWMCMLibPaths[i], dlerror());
            continue;
        }
        if (!dlsym(h, "container_query_create")) {
            OWLog(@"OWMCM: %s 无 container_query_create，试下一个", kOWMCMLibPaths[i]);
            dlclose(h);
            continue;
        }
        OWLog(@"OWMCM: 使用 %s", kOWMCMLibPaths[i]);
        gOWMCMhandle = h;
        return h;
    }
    return NULL;
}

- (void *)sym:(const char *)name required:(BOOL)required {
    void *p = gOWMCMhandle ? dlsym(gOWMCMhandle, name) : NULL;
    if (!p && required) {
        [_missing appendFormat:@" %s", name];
    }
    return p;
}

- (OWMCMStatus)bindSymbols {
    void *h = [self loadLibrary];
    if (!h) {
        _lastError = @"libsystem_container.dylib 加载失败";
        return OWMCMStatusLibNotFound;
    }
    _missing = [NSMutableString string];

    // 必需：查询生命周期 + 对象取值 + token
    gOWMCMfns.query_create      = (ow_query_create_t)      [self sym:"container_query_create" required:YES];
    gOWMCMfns.query_free        = (ow_query_free_t)        [self sym:"container_query_free" required:YES];
    gOWMCMfns.query_set_class   = (ow_query_set_class_t)   [self sym:"container_query_set_class" required:YES];
    gOWMCMfns.query_iterate     = (ow_query_iterate_results_sync_t)[self sym:"container_query_iterate_results_sync" required:YES];
    gOWMCMfns.query_get_error   = (ow_query_get_last_error_t)[self sym:"container_query_get_last_error" required:YES];
    gOWMCMfns.object_free       = (ow_object_free_t)       [self sym:"container_object_free" required:YES];
    gOWMCMfns.object_get_path   = (ow_object_get_path_t)   [self sym:"container_object_get_path" required:YES];
    gOWMCMfns.object_get_identifier = (ow_object_get_identifier_t)[self sym:"container_object_get_identifier" required:YES];
    gOWMCMfns.copy_sandbox_token= (ow_copy_sandbox_token_t)[self sym:"container_copy_sandbox_token" required:YES];
    gOWMCMfns.error_get_message = (ow_error_get_message_t)[self sym:"container_error_get_message" required:NO];
    gOWMCMfns.error_get_errno   = (ow_error_get_posix_errno_t)[self sym:"container_error_get_posix_errno" required:NO];

    // 可选：定向查询 / 单结果 / 分组
    gOWMCMfns.query_set_identifiers = (ow_query_set_identifiers_t)[self sym:"container_query_set_identifiers" required:NO];
    gOWMCMfns.query_set_group_identifiers = (ow_query_set_group_identifiers_t)[self sym:"container_query_set_group_identifiers" required:NO];
    gOWMCMfns.query_set_flags   = (ow_query_operation_set_flags_t)[self sym:"container_query_operation_set_flags" required:NO];
    gOWMCMfns.query_set_part    = (ow_query_operation_set_part_t)[self sym:"container_query_operation_set_part" required:NO];
    gOWMCMfns.query_set_part_domain = (ow_query_operation_set_part_domain_t)[self sym:"container_query_operation_set_part_domain" required:NO];
    gOWMCMfns.query_get_next    = (ow_query_get_next_result_t)[self sym:"container_query_get_next_result" required:NO];
    gOWMCMfns.query_get_single  = (ow_query_get_single_result_t)[self sym:"container_query_get_single_result" required:NO];
    gOWMCMfns.object_copy       = (ow_object_copy_t)       [self sym:"container_object_copy" required:NO];
    gOWMCMfns.object_sbx_activate = (ow_object_sbx_activate_t)[self sym:"container_object_sandbox_extension_activate" required:NO];

    // 注：sandbox_extension_consume 在 libsystem_sandbox.dylib，由 OWMCMLease 负责，
    // 这里不绑定，避免职责混乱。

    if (_missing.length) {
        _lastError = [NSString stringWithFormat:@"必需符号缺失:%@", _missing];
        return OWMCMStatusSymbolMissing;
    }
    return OWMCMStatusOK;
}

#pragma mark 身份

// 优先从 embedded.mobileprovision 无法读（被签名剥离），
// 改用主二进制 entitlements 的 application-identifier —— 需绕过沙箱读自身，
// 最稳的是直接看 NSBundle.mainBundle.bundleIdentifier。
// 目标包的做法是对 signed code identifier 比对，我们用 bundleIdentifier 近似，
// 并在日志里打印实际值供实机核对。
- (NSString *)resolveSignedIdentity {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length) return bid;

    // 兜底：直接读 bundle 根目录的 Info.plist（不经 pathForResource，
    // 那会把 Info.plist 当成 Resources 资源误报）
    NSString *root = [[NSBundle mainBundle] bundlePath];
    NSString *p = [root stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d[@"CFBundleIdentifier"];
}

#pragma mark prepare

- (OWMCMStatus)prepare {
    if (_prepared != 0 || _prepared == OWMCMStatusOK) {
        if (_prepared == OWMCMStatusOK) return OWMCMStatusOK;
    }

    OWMCMStatus st = [self bindSymbols];
    if (st != OWMCMStatusOK) {
        _available = NO;
        _prepared = st;
        OWLog(@"OWMCM: 绑定失败 %@", _lastError);
        return st;
    }

    _signedIdentity = [self resolveSignedIdentity];
    OWLog(@"OWMCM: 签名身份 = %@", _signedIdentity ?: @"(未知)");

    // 目标包在身份不符时直接禁用 MCM（[MCMFilza] disabled: signed code identifier ...）。
    // 我们不硬拒（部分版本用 team id / UID 判定，伪装 bundleId 可能仍被放行），
    // 但把状态记下来，供 OWSelfTest 的 B2 和调用方判断。
    _identityOK = [_signedIdentity isEqualToString:kOWMHAIdentity];
    if (!_identityOK) {
        OWLog(@"OWMCM: 身份 %@ != %@，MCM 大概率被拒（B2 会报 FAIL）",
              _signedIdentity ?: @"(nil)", kOWMHAIdentity);
    }

    _available = YES;
    _prepared = OWMCMStatusOK;
    OWLog(@"OWMCM: 绑定完成（必需 9 项 / 可选 8 项）");
    return OWMCMStatusOK;
}

#pragma mark 枚举

- (NSError *)errorWithStatus:(OWMCMStatus)st message:(NSString *)msg {
    return [NSError errorWithDomain:@"OWMCM"
                               code:st
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"MCM error"}];
}

- (nullable NSArray<OWMCMContainer *> *)containersOfClass:(OWMCMClass)cls
                                              identifiers:(nullable NSArray<NSString *> *)identifiers
                                                    error:(NSError **)error {
    if ([self prepare] != OWMCMStatusOK) {
        if (error) *error = [self errorWithStatus:_prepared message:_lastError];
        return nil;
    }
    if (!gOWMCMfns.query_create) {
        if (error) *error = [self errorWithStatus:OWMCMStatusSymbolMissing message:@"query_create 缺失"];
        return nil;
    }

    // 身份不符时先记一条身份告警（仍尝试查询：部分版本按 team id / UID 放行）。
    // 真正的拒绝会以 QueryFailed(EPERM) 形式返回。
    if (!_identityOK) {
        OWLog(@"OWMCM: [%d] 身份不符仍尝试查询（%llu/%@）",
              (int)OWMCMStatusIdentityRejected, (unsigned long long)cls,
              [OWMCM classNameFor:cls]);
    }

    void *q = gOWMCMfns.query_create();
    if (!q) {
        if (error) *error = [self errorWithStatus:OWMCMStatusQueryCreateFailed
                                          message:@"container_query_create 返回 NULL"];
        OWLog(@"OWMCM: container_query_create 返回 NULL");
        return nil;
    }
    OWQueryRetain(q);   // 基准引用，函数末尾统一归还

    gOWMCMfns.query_set_class(q, (uint64_t)cls);

    if (identifiers.count && gOWMCMfns.query_set_identifiers) {
        gOWMCMfns.query_set_identifiers(q, (__bridge CFArrayRef)identifiers);
    } else if (identifiers.count) {
        OWLog(@"OWMCM: 本版本没有 query_set_identifiers，忽略过滤条件");
    }

    // app-group 需要走 group_identifiers
    if (cls == OWMCMClassAppGroup && identifiers.count && gOWMCMfns.query_set_group_identifiers) {
        gOWMCMfns.query_set_group_identifiers(q, (__bridge CFArrayRef)identifiers);
    }

    if (gOWMCMfns.query_set_flags) {
        // flags 0 = 不创建、不递归取子容器，只做直查
        gOWMCMfns.query_set_flags(q, 0);
    }

    void *qerr = NULL;
    BOOL started = gOWMCMfns.query_iterate ? gOWMCMfns.query_iterate(q, &qerr) : NO;
    if (!started) {
        NSString *msg = @"container_query_iterate_results_sync 失败";
        int posix = 0;
        if (qerr && gOWMCMfns.error_get_message) {
            const char *m = gOWMCMfns.error_get_message(qerr);
            if (m) msg = [NSString stringWithUTF8String:m];
        }
        if (qerr && gOWMCMfns.error_get_errno) {
            posix = gOWMCMfns.error_get_errno(qerr);
        }
        OWLog(@"OWMCM: class=%llu 枚举失败: %@ (errno=%d)",
              (unsigned long long)cls, msg, posix);
        if (error) *error = [self errorWithStatus:OWMCMStatusQueryFailed message:msg];
        OWQueryRelease(q);
        return nil;
    }

    // 逐条取值：iterate_results_sync 只是初始化结果集，真正的迭代接口是
    // container_query_get_next_result（每次返回下一个，取完返回 NULL）。
    // container_query_get_single_result 专用于「结果恰好一条」的查询，
    // 反复调用会一直返回同一个对象 —— 之前拿它当迭代器就是死循环的根因。
    NSMutableArray<OWMCMContainer *> *out = [NSMutableArray array];
    NSString *via = @"none";

    if (gOWMCMfns.query_get_next) {
        via = @"next_result";
        void *obj = NULL;
        void *lastObj = NULL;
        NSUInteger guard = 0;
        while ((obj = gOWMCMfns.query_get_next(q)) != NULL) {
            // 防御：个别版本可能重复吐同一对象，遇到就停（该对象已由上一个 container 持有）
            if (obj == lastObj) {
                OWLog(@"OWMCM: class=%llu 迭代器重复返回同一对象，停止（已取 %lu 个）",
                      (unsigned long long)cls, (unsigned long)out.count);
                break;
            }
            lastObj = obj;

            OWMCMContainer *c = [self wrapObject:obj query:q cls:cls];
            if (c) {
                [out addObject:c];
            } else if (gOWMCMfns.object_free) {
                gOWMCMfns.object_free(obj);
            }

            // 再兜一层上限，避免异常实现把内存拖爆
            if (++guard >= 100000) {
                OWLog(@"OWMCM: class=%llu 结果超过 100000 条，疑似迭代器异常，停止",
                      (unsigned long long)cls);
                break;
            }
        }
    } else if (gOWMCMfns.query_get_single) {
        // 缺 next_result 才降级：只取一条，并明确告知调用方枚举不完整
        via = @"single_result(降级)";
        OWLog(@"OWMCM: 本版本无 container_query_get_next_result，"
              @"降级为只取单条结果（class=%llu，枚举不完整）",
              (unsigned long long)cls);
        void *obj = gOWMCMfns.query_get_single(q);
        if (obj) {
            OWMCMContainer *c = [self wrapObject:obj query:q cls:cls];
            if (c) [out addObject:c];
            else if (gOWMCMfns.object_free) gOWMCMfns.object_free(obj);
        }
    } else {
        OWLog(@"OWMCM: 既无 get_next_result 也无 get_single_result，无法取值（class=%llu）",
              (unsigned long long)cls);
    }

    // 每个 container 在 wrapObject 里各 retain 一份 query；
    // 这里释放的是「本函数自己」这一份引用。
    OWQueryRelease(q);
    OWLog(@"OWMCM: class=%llu (%@) 枚举到 %lu 个 [%@]",
          (unsigned long long)cls, [OWMCM classNameFor:cls],
          (unsigned long)out.count, via);
    return out;
}

- (nullable OWMCMContainer *)wrapObject:(void *)obj query:(void *)q cls:(OWMCMClass)cls {
    if (!obj) return nil;
    void *oerr = NULL;
    const char *ident = gOWMCMfns.object_get_identifier ? gOWMCMfns.object_get_identifier(obj, &oerr) : NULL;
    const char *path  = gOWMCMfns.object_get_path ? gOWMCMfns.object_get_path(obj, &oerr) : NULL;

    if (!path || path[0] != '/') {
        // OWMCMStatusPathNotAbsolute：路径异常，该容器不可用
        OWLog(@"OWMCM: [%d] 容器路径非绝对（id=%s path=%s）",
              (int)OWMCMStatusPathNotAbsolute, ident ?: "?", path ?: "(null)");
        return nil;
    }

    // ★ 关键：立刻取 token 并缓存，让 container 不再依赖 container_object 存活。
    // 这样 query_free / object_free 之后 token 依然可用（token 是独立字符串）。
    NSString *token = nil;
    if (gOWMCMfns.copy_sandbox_token) {
        char *tok = gOWMCMfns.copy_sandbox_token(obj);
        if (tok) {
            token = [NSString stringWithUTF8String:tok];
            free(tok);
        }
    }
    if (!token.length) {
        // OWMCMStatusNoSandboxToken：容器没有 token，后续 activate 必失败。
        // 不在这里 return nil（容器本身有效，只是不可读），由 lease 层报错。
        OWLog(@"OWMCM: [%d] 容器无 sandbox token（id=%s）",
              (int)OWMCMStatusNoSandboxToken, ident ?: "?");
    }

    OWMCMContainer *c = [OWMCMContainer new];
    c.identifier = ident ? [NSString stringWithUTF8String:ident] : @"";
    c.path = [NSString stringWithUTF8String:path];
    c.containerClass = cls;
    c.sandboxToken = token;
    c.rawObject = obj;
    c.query = q;
    OWQueryRetain(q);   // container 持有一份，dealloc 时归还
    return c;
}

- (nullable OWMCMContainer *)containerOfClass:(OWMCMClass)cls
                                   identifier:(NSString *)identifier
                                        error:(NSError **)error {
    if (!identifier.length) {
        if (error) *error = [self errorWithStatus:OWMCMStatusBadArgument message:@"identifier 为空"];
        return nil;
    }
    NSArray *r = [self containersOfClass:cls identifiers:@[identifier] error:error];
    for (OWMCMContainer *c in r) {
        if ([c.identifier isEqualToString:identifier]) return c;
    }
    return r.firstObject;
}

#pragma mark 名称

+ (NSString *)classNameFor:(OWMCMClass)cls {
    switch (cls) {
        case OWMCMClassApplicationData: return @"application-data";
        case OWMCMClassExtensionData:   return @"extension-data";
        case OWMCMClassVPNData:         return @"VPN-data";
        case OWMCMClassAppGroup:        return @"app-group";
        case OWMCMClassServiceData:     return @"service-data";
        case OWMCMClassSystemData:      return @"system-data";
        case OWMCMClassScopedPart:      return @"scoped-part";
        case OWMCMClassProtectedData:   return @"protected-data";
    }
    return [NSString stringWithFormat:@"class-%llu", (unsigned long long)cls];
}

@end

#pragma mark - 供 OWMCMLease 使用的内部接口

@implementation OWMCM (LeaseInternal)

// 取容器对应的 sandbox extension token 字符串。
// container_copy_sandbox_token 返回 malloc 的 C 字符串，需 free。
- (nullable id)copySandboxTokenForContainer:(OWMCMContainer *)c {
    // 枚举时已缓存就直接用（不依赖 rawObject 是否还活着）
    if (c.sandboxToken.length) return c.sandboxToken;
    if (!c.rawObject || !gOWMCMfns.copy_sandbox_token) return nil;

    char *tok = gOWMCMfns.copy_sandbox_token(c.rawObject);
    if (!tok) return nil;

    NSString *s = [NSString stringWithUTF8String:tok];
    free(tok);
    return s;
}

@end
