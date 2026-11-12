//
//  OWMCM.h
//  OPENsrc
//
//  libcontainer C API 封装（MCM 容器通道的底层）
//
//  设计要点：
//    - 所有函数用 dlsym 解析，不链接 libsystem_container（它在 dyld shared cache 里，
//      不同 iOS 版本导出名可能有差异，dlsym 更稳）
//    - 缺符号不崩，返回明确错误码，调用方降级
//    - 只做「查容器 + 取 token」，token 生命周期交给 OWMCMLease
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 容器类别
// 取自目标包 libuiopsersvc 的日志字符串（MHA-MCM class N ...）
typedef NS_ENUM(uint64_t, OWMCMClass) {
    OWMCMClassApplicationData = 2,
    OWMCMClassExtensionData   = 4,
    OWMCMClassVPNData         = 6,
    OWMCMClassAppGroup        = 7,
    OWMCMClassServiceData     = 10,
    OWMCMClassSystemData      = 12,
    OWMCMClassScopedPart      = 13,
    OWMCMClassProtectedData   = 15,
};

#pragma mark - 结果对象
// 一次查询命中的容器。path/identifier 由 OWMCM 内部 strdup，调用方不必 free。
@interface OWMCMContainer : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) OWMCMClass containerClass;
/// 原始 container_object_t 指针，仅供 OWMCMLease 取 token 用
@property (nonatomic, assign, readonly) void *rawObject;
/// 枚举时就已取好并缓存的 sandbox extension token。
/// 用它就不依赖 rawObject 存活，query/object free 后依然有效。
@property (nonatomic, copy, readonly, nullable) NSString *sandboxToken;
@end

#pragma mark - 错误码
typedef NS_ENUM(int, OWMCMStatus) {
    OWMCMStatusOK                = 0,
    OWMCMStatusLibNotFound       = -10,  // libsystem_container 加载失败
    OWMCMStatusSymbolMissing     = -11,  // 必需符号缺失
    OWMCMStatusIdentityRejected  = -12,  // 身份不是 MHA 白名单
    OWMCMStatusQueryCreateFailed = -13,
    OWMCMStatusQueryFailed       = -14,  // 带 posix errno
    OWMCMStatusNoSandboxToken    = -15,
    OWMCMStatusTokenConsumeFail  = -16,
    OWMCMStatusPathNotAbsolute   = -17,
    OWMCMStatusBadArgument       = -18,
};

@interface OWMCM : NSObject

+ (instancetype)shared;

/// 加载库 + 绑定符号 + 校验身份。可重复调用，自带 once 缓存。
/// 返回 OWMCMStatusOK 才可用。
- (OWMCMStatus)prepare;

/// 上一次 prepare 的详细错误（含缺失符号名 / 实际身份）
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

/// 是否可用
@property (nonatomic, assign, readonly) BOOL available;

/// 当前进程的签名身份（entitlement application-identifier 的 bundle 部分）
@property (nonatomic, copy, readonly, nullable) NSString *signedIdentity;

/// 签名身份是否等于 MHA（目标包要求）。NO 时 MCM 大概率被 containermanagerd 拒绝。
@property (nonatomic, assign, readonly) BOOL identityOK;

/// 枚举某类别下全部容器。identifiers 为 nil 表示不限。
/// 注意：返回的 OWMCMContainer.rawObject 在本次调用返回后仍有效（内部持有），
/// 但只在下一个 batch 到来前有效 —— 调用方应当立即取 path 并交给 OWMCMLease。
- (nullable NSArray<OWMCMContainer *> *)containersOfClass:(OWMCMClass)cls
                                              identifiers:(nullable NSArray<NSString *> *)identifiers
                                                    error:(NSError **)error;

/// 按 identifier 定向取单个容器
- (nullable OWMCMContainer *)containerOfClass:(OWMCMClass)cls
                                   identifier:(NSString *)identifier
                                        error:(NSError **)error;

/// 用于 os_log 的类别名
+ (NSString *)classNameFor:(OWMCMClass)cls;

@end

NS_ASSUME_NONNULL_END
