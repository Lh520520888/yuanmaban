#import <Foundation/Foundation.h>
#import "OWCommon.h"

NS_ASSUME_NONNULL_BEGIN

@class OWRemoteCall;

/// 系统守护进程属地的库采集（短信 / 通讯录 / 通话 / Safari / 相册 / 日历 / 健康 …）。
///
/// 这些路径全部在 /var/mobile/Library 下，不属于任何 App 容器，
/// 通道 B 的 house_arrest 租约机制覆盖不到 —— 只有内核通道 root 之后才可读。
///
/// 拷贝走两级：
///   1) NSFileManager 直拷（已 root 且脱沙箱时最快）；
///   2) 失败则走 RemoteCall 的特权拷贝（vnode 层读）。
/// 没有任何一条路可读时记为 skip 而不是失败 —— 容器-only 场景下这是预期结果。
@interface OWSystemGrab : NSObject

@property (nonatomic, readonly) NSString *outDir;
@property (nonatomic, readonly) NSArray<NSDictionary *> *results;   // name/path/bytes/emptyDb
@property (nonatomic, readonly) NSArray<NSString *> *skipped;       // 无权限的条目名
@property (nonatomic) uint64_t maxFileBytes;                        // 默认 200MB

- (BOOL)runWithRemote:(nullable OWRemoteCall *)rc error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
