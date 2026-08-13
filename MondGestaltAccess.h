#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Acquires access to the MobileGestalt cache using the same ContainerManager
/// query shape used by the integrated Gestalt editor. Returns the exact plist
/// path only after a write-capable open succeeds.
FOUNDATION_EXPORT NSString * _Nullable FilzaMondGestaltAcquireAccess(NSString * _Nullable * _Nullable detail);

/// Returns the libMobileGestalt CacheData byte offset for a Gestalt key using
/// the __cstring -> __AUTH_CONST/__DATA_CONST lookup used by the editor.
FOUNDATION_EXPORT NSUInteger FilzaMondGestaltCacheDataOffset(NSString *key);

NS_ASSUME_NONNULL_END
