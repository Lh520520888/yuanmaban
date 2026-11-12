#import <Foundation/Foundation.h>
#import "OWCommon.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, OWExploitType) {
    OWExploitTypeKernel = 0,
    OWExploitTypePAC,
    OWExploitTypePPL,
};

@interface OWExploitEntry : NSObject
@property (nonatomic, readonly) NSString *identifier;   // 如 "kfd"
@property (nonatomic, readonly) NSString *flavorName;   // 如 "smith"
@property (nonatomic, readonly) NSString *executablePath;
@property (nonatomic, readonly) OWExploitType type;
@property (nonatomic, readonly) uint64_t priority;
@property (nonatomic, readonly) NSArray<NSString *> *requirements;
@property (nonatomic, readonly) BOOL oneShot;           // 每次开机仅一次，失败即作废

- (instancetype)initWithPath:(NSString *)path
                        info:(NSDictionary *)info
                  flavorName:(NSString *)flavorName
                  flavorDict:(NSDictionary *)flavorDict;

- (BOOL)isSupported;
- (int)load;
- (int)run;
- (int)cleanup;
@end

@interface OWKernelChain : NSObject

@property (nonatomic) NSTimeInterval perAttemptTimeout;   // 单发超时，默认 60s
@property (nonatomic) NSTimeInterval totalBudget;         // 总预算，默认 240s
@property (nonatomic) NSUInteger maxCandidates;           // 最多试几个候选，默认 3
@property (nonatomic, readonly, nullable) NSString *lastError;
@property (nonatomic, readonly) BOOL hasKernelRW;
@property (nonatomic, readonly) BOOL offsetsResolved;

/// XPF patchfind 解出的内核基址 / slide（resolveOffsets: 成功后有效，否则为 0）
@property (nonatomic, readonly) uint64_t kernelBase;
@property (nonatomic, readonly) uint64_t kernelSlide;

- (NSArray<OWExploitEntry *> *)candidatesOfType:(OWExploitType)type;

// kernelcache：内嵌 → 缓存 → 下载（不走 TrollStore/root 本地路径）
- (nullable NSString *)resolveKernelCache:(NSError **)error;

// 偏移：XPF patchfind，按 boot-manifest-hash 缓存
- (BOOL)resolveOffsets:(NSError **)error;

// 按 priority 降序逐个尝试，带预算与失败落盘
- (BOOL)runKernelPass:(NSError **)error;

// 支撑利用：先跑 PAC，再跑 PPL（这类不产生 gPrimitives，只求返回 0）。
// 上游 Dopamine 的顺序就是 PAC → PPL → Kernel；缺这步时依赖 PPL 的内核 exploit 起不来。
// 返回成功个数；全部失败不算链路失败。
- (NSUInteger)runSupportPass:(NSError **)error;

// 静态门：该设备是否存在任一可用 kernel 候选
- (BOOL)kernelStaticallySupported;

@end

NS_ASSUME_NONNULL_END
