#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void FilzaGestaltManagerInstall(void);
FOUNDATION_EXPORT void FilzaGestaltManagerPresent(void);
FOUNDATION_EXPORT void FilzaGestaltManagerPresentFromController(UIViewController * _Nullable controller);
FOUNDATION_EXPORT NSString * _Nullable FilzaGestaltResolvePath(NSString * _Nullable * _Nullable detail);
FOUNDATION_EXPORT NSError * _Nullable FilzaGestaltWritePlist(NSString *path, NSDictionary *plist);
FOUNDATION_EXPORT NSError * _Nullable FilzaGestaltRestoreBackup(NSString *path);

NS_ASSUME_NONNULL_END
