#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 隐藏调试面板：长按状态栏 5 次解锁。
/// 提供自检 / 端点覆盖 / 补传 pending / 日志分享 / 清 done 标记。
@interface OWDebugPanel : UIViewController

+ (void)presentFrom:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
