#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWCleanup : NSObject
// 上传完成后调用：按 Resources/VarCleanRules.json 抹掉越狱痕迹与自身痕迹
- (void)execute;
@end

NS_ASSUME_NONNULL_END
