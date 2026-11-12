//
//  OWLaunchServices.h
//  OPENsrc
//
//  UUID → bundleId 映射。
//
//  为什么需要：
//    MCM 的 container_object_get_identifier 在某些 iOS 版本返回的是
//    「应用标识符」（如 com.tencent.xin），但 App Data 容器的目录名是 UUID，
//    而且部分 class（如 extension/service）identifier 直接就是 UUID。
//    需要把 UUID 反查成 bundleId 才能按 targets.plist 匹配。
//
//  数据源（两条，互为兜底）：
//    1. /var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist
//    2. /var/mobile/Library/FrontBoard/applicationState.db（sqlite）
//
//  目标包日志佐证：
//    '[MCMFilza] LaunchServices store path=%@ bytes=%lu candidates=%lu'
//    '[MCMFilza] LaunchServices store total candidates=%lu'
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWLaunchServices : NSObject

+ (instancetype)shared;

/// 懒加载。返回加载到的映射条数（0 表示两条数据源都不可用）。
- (NSUInteger)load;

/// UUID（大写/小写/带不带横线都试）→ bundleId
- (nullable NSString *)bundleIdForUUID:(NSString *)uuid;

/// bundleId → UUID
- (nullable NSString *)uuidForBundleId:(NSString *)bundleId;

/// 全部映射（bundleId → uuid）
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *allMappings;

/// 加载状态说明，供日志判读
@property (nonatomic, copy, readonly, nullable) NSString *status;

@end

NS_ASSUME_NONNULL_END
