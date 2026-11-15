#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 日志

#define OWLog(fmt, ...) [OWLogger logFile:__FILE__ line:__LINE__ format:(fmt), ##__VA_ARGS__]

@interface OWLogger : NSObject
+ (void)logFile:(const char *)file line:(int)line format:(NSString *)fmt, ... NS_FORMAT_FUNCTION(3, 4);
+ (NSString *)logPath;
+ (nullable NSData *)tail:(NSUInteger)maxBytes;
+ (void)purge;
@end

#pragma mark - 状态（落盘，进程被杀/重启可续跑）

extern NSString * const OWStateKeyDone;
extern NSString * const OWStateKeyBootSession;
extern NSString * const OWStateKeyPayloads;
extern NSString * const OWStateKeyKernelAttempts;
extern NSString * const OWStateKeyKernelExhausted;
extern NSString * const OWStateKeyKeysAcquired;
extern NSString * const OWStateKeyLastError;
extern NSString * const OWStateKeyDoneAt;
extern NSString * const OWStateKeyNextRunAt;
extern NSString * const OWStateKeyRunId;
extern NSString * const OWStateKeyTargetsDone;

@interface OWState : NSObject
+ (instancetype)shared;

- (nullable id)objectForKey:(NSString *)key;
- (void)setObject:(nullable id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (void)synchronize;
- (void)reset;

- (NSUInteger)attemptsForExploit:(NSString *)identifier;
- (void)bumpAttemptForExploit:(NSString *)identifier;
- (void)markExploitExhausted:(NSString *)identifier;
- (BOOL)isExploitExhausted:(NSString *)identifier;

- (BOOL)isDone;
- (BOOL)markDoneIfPayloadValid:(BOOL)valid;
- (NSTimeInterval)doneAt;
- (NSTimeInterval)nextRunAt;
- (BOOL)shouldSkipForTTL:(NSTimeInterval)ttl;
/// 新一轮 / 重启后重跑：清掉本轮结果，保留一次性 exploit 的 exhausted/attempts
- (void)beginNewRun;
/// 断点续跑：保留本轮 runId / 目标断点 / 已采记录，只清临时错误与阶段
- (void)beginResume;

- (void)notePayload:(NSString *)name bytes:(uint64_t)bytes valid:(BOOL)valid;
/// 批量记账：一次落盘，避免每拷一个文件就写整份 plist
- (void)notePayloads:(NSArray<NSDictionary *> *)items;
- (NSArray<NSDictionary *> *)payloads;

#pragma mark 目标级断点（详见 docs/10 §10.1）

/// 本轮 runId；beginNewRun 时重新生成，旧目标的 .done 因 runId 不符自动作废
- (NSString *)runId;
/// 该目标本轮是否已完成（bundleId + containerPath + 文件数 + 字节数全部匹配才认）
- (BOOL)isTargetDone:(NSString *)bundleId
       containerPath:(NSString *)containerPath
           fileCount:(NSInteger)fileCount
               bytes:(uint64_t)bytes;
- (void)markTargetDone:(NSString *)bundleId
         containerPath:(NSString *)containerPath
             fileCount:(NSInteger)fileCount
                 bytes:(uint64_t)bytes
                   zip:(nullable NSString *)zip;
- (NSUInteger)targetsDoneCount;
@end

#pragma mark - 设备画像

typedef NS_ENUM(NSUInteger, OWSocTier) {
    OWSocTierUnknown = 0,
    OWSocTierPreA12,   // arm64（A8–A11），内核引擎多为 arm64e，加载不了
    OWSocTierA12A13,   // 覆盖最广：15.0–18.7.1 + 26.0–26.0.1
    OWSocTierA14M1,
    OWSocTierA15A16M2,
    OWSocTierA17Pro,
    OWSocTierA18Plus,  // 内核通道无解，仅 B
};

@interface OWDeviceProfile : NSObject
+ (instancetype)current;

@property (nonatomic, readonly) NSString *osVersion;
/// 系统 build（kern.osversion，如 20G5026e）。exploit 的 build 白名单要用它匹配。
@property (nonatomic, readonly) NSString *osBuild;
@property (nonatomic, readonly) NSInteger major;
@property (nonatomic, readonly) NSInteger minor;
@property (nonatomic, readonly) NSInteger patch;
@property (nonatomic, readonly) NSString *machine;
@property (nonatomic, readonly) OWSocTier socTier;
@property (nonatomic, readonly) NSString *socTierName;
@property (nonatomic, readonly) BOOL isArm64e;
@property (nonatomic, readonly, nullable) NSString *bootManifestHash;
@property (nonatomic, readonly) BOOL protectedDataAvailable;

- (BOOL)isAtLeastMajor:(NSInteger)maj minor:(NSInteger)min patch:(NSInteger)pat;
- (BOOL)isLessOrEqualMajor:(NSInteger)maj minor:(NSInteger)min patch:(NSInteger)pat;
@end

NS_ASSUME_NONNULL_END
