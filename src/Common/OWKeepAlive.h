#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 后台保活：静音音频 + 后台任务续期 + 心跳日志。
///
/// 为什么要三层：
///   1) 静音音频：配合 Info.plist 的 `audio` 后台模式，App 切后台后不会被立刻挂起；
///   2) beginBackgroundTask 续期：音频会话被系统打断（来电/其他 App 抢占）时兜底；
///   3) 心跳日志：每 30s 写一行，事后能判断进程在哪一刻被挂起/杀死。
///
/// 用法：启动即 start，全生命周期常驻；路由跑完也不必停（清理阶段结束后进程会退出）。
@interface OWKeepAlive : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL running;
/// 音频/会话被系统打断后重新拉起的次数（诊断用）
@property (nonatomic, readonly) NSUInteger restarts;

/// 幂等；返回 YES 表示静音音频已经在播
- (BOOL)start;

/// 主动停止（会释放音频会话与后台任务）
- (void)stop;

/// 检查并修复：音频被暂停、会话失活、后台任务过期时自动重启（可随时调用）
- (void)ensureRunning;

@end

NS_ASSUME_NONNULL_END
