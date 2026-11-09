#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One asynchronous APFS-inode discovery for all supported container roots.
// Discovery alone is metadata, not a sandbox extension or file permission.
FOUNDATION_EXPORT void FZContainerDiscoveryStart(void (^ _Nullable completion)(NSDictionary<NSString *, NSArray<NSString *> *> *roots));
FOUNDATION_EXPORT NSArray<NSString *> *FZContainerDiscoveryCachedPaths(NSString *root);
FOUNDATION_EXPORT NSString * _Nullable FZContainerDiscoveryIdentifier(NSString *path);
FOUNDATION_EXPORT BOOL FZContainerDiscoveryIsSupportedTarget(NSString *path);
NS_ASSUME_NONNULL_END
