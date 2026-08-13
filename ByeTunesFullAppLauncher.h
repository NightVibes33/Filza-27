#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Presents the complete embedded ByeTunes application. Returns NO only when
/// no presenter or linked Swift host is available yet, allowing callers to
/// retry during cold launch.
FOUNDATION_EXPORT BOOL FilzaByeTunesPresentFromController(UIViewController * _Nullable presenter);
FOUNDATION_EXPORT void FilzaByeTunesInstallDirectRoutes(void);

NS_ASSUME_NONNULL_END
