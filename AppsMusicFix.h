#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves the live class-2 data container for an installed application and
/// returns the Filza virtual path only after directory enumeration succeeds.
/// The implementation uses the existing MobileHouseArrest path first and the
/// already-pinned bad_query per-container fallback when needed.
FOUNDATION_EXPORT NSString * _Nullable
FilzaEnsureVirtualAppDataPath(NSString *identifier, NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
