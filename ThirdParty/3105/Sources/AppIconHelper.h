#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "idevice.h"

NS_ASSUME_NONNULL_BEGIN

/// Returns a dictionary mapping bundleID -> @{ @"name": NSString, @"icon": UIImage }.
/// Uses the private LSApplicationWorkspace API (stable across iOS 14+).
NSDictionary<NSString *, NSDictionary *> *installedAppInfo(void);

/// Fetches an icon for a single bundle ID via LSApplicationProxy.
UIImage * _Nullable iconForBundleID(NSString *bundleID);

/// Fetches a rendered SpringBoard icon through the already-established shared
/// RSD transport owned by ByeTunes' DeviceManager.
UIImage * _Nullable filzaSpringBoardIconForBundleIDRSD(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    NSString *bundleID
);

/// Fetches a rendered SpringBoard icon through the already-established shared
/// classic lockdown provider owned by ByeTunes' DeviceManager.
UIImage * _Nullable filzaSpringBoardIconForBundleIDProvider(
    struct IdeviceProviderHandle *provider,
    NSString *bundleID
);

/// Returns @{ @"name": NSString, @"icon": UIImage } for a single bundle ID.
NSDictionary *appInfoForBundleID(NSString *bundleID);

/// Opens an installed app using LaunchServices. Returns NO when the private
/// selector is unavailable or the requested bundle cannot be opened.
BOOL openApplicationForBundleID(NSString *bundleID);

NS_ASSUME_NONNULL_END
