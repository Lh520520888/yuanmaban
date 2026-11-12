//
//  OWMCMLease.h
//  OPENsrc
//
//  容器租约：申请 sandbox extension token 并消费它。
//
//  为什么必须这一步：
//    MCM 只给出容器路径，但目标容器目录在你的 sandbox profile 之外。
//    必须由 containermanagerd 签发 extension token，sandbox_extension_consume
//    消费后，本进程才获得该容器的读权限。否则 open/NSFileManager 一律 EPERM。
//
//  生命周期约束（目标包实测 active_leases=3）：
//    同时持有的 extension handle 数量有限，用完必须 release，否则后续申请失败。
//    本类用「LRU + 上限」模拟目标包的 lease 池。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OWMCMContainer;

@interface OWMCMLease : NSObject

+ (instancetype)shared;

/// 是否可用（sandbox_extension_consume 绑定成功）
@property (nonatomic, assign, readonly) BOOL available;

/// 当前持有的 lease 数（对应目标包日志 active_leases）
@property (nonatomic, assign, readonly) NSUInteger activeCount;

/// 同时持有上限，默认 3
@property (nonatomic, assign) NSUInteger maxConcurrent;

/// 激活一个容器：取 token → consume。
/// 成功返回 YES，之后可直接用 NSFileManager 读 con.path。
/// 失败时 reason 给出具体原因（无 token / consume 失败 / 已被拒）。
- (BOOL)activateContainer:(OWMCMContainer *)container reason:(NSString *_Nullable *_Nullable)reason;

/// 显式释放某容器（按 path 匹配）
- (void)releasePath:(NSString *)path;

/// 释放全部
- (void)releaseAll;

/// 该 path 当前是否持有有效 lease
- (BOOL)hasLeaseForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
