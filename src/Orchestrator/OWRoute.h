#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, OWRoutePhase) {
    OWRoutePhaseIdle = 0,
    OWRoutePhaseContainer,
    OWRoutePhaseContainerUpload,
    OWRoutePhaseKernel,
    OWRoutePhaseKeys,
    OWRoutePhaseKeysUpload,
    OWRoutePhaseCleanup,
    OWRoutePhaseDone,
    OWRoutePhaseFailed
};

@interface OWRoute : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly) OWRoutePhase phase;
@property (nonatomic, readonly) NSString *phaseName;
@property (nonatomic, readonly, nullable) NSString *lastError;

- (void)start;
@end

NS_ASSUME_NONNULL_END
