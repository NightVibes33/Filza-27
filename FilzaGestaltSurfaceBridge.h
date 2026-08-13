#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL FilzaGestaltSurfaceReady(UIViewController *controller);
FOUNDATION_EXPORT NSMutableDictionary * _Nullable FilzaGestaltSurfacePlist(UIViewController *controller);
FOUNDATION_EXPORT NSMutableDictionary * _Nullable FilzaGestaltSurfaceCacheExtra(UIViewController *controller);
FOUNDATION_EXPORT NSMutableDictionary * _Nullable FilzaGestaltSurfaceArtwork(UIViewController *controller);
FOUNDATION_EXPORT NSString *FilzaGestaltSurfaceAccessDetail(UIViewController *controller);
FOUNDATION_EXPORT BOOL FilzaGestaltSurfaceFeatureEnabled(UIViewController *controller, NSDictionary *feature);
FOUNDATION_EXPORT void FilzaGestaltSurfaceSetFeature(UIViewController *controller, NSDictionary *feature, BOOL enabled);
FOUNDATION_EXPORT void FilzaGestaltSurfaceMarkDirty(UIViewController *controller);
FOUNDATION_EXPORT void FilzaGestaltSurfaceSave(UIViewController *controller);
FOUNDATION_EXPORT void FilzaGestaltSurfaceRevert(UIViewController *controller);
NS_ASSUME_NONNULL_END
