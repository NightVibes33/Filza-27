#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Real forcequitOS worse_query backend; only return actual verified grants.
FOUNDATION_EXPORT NSString * _Nullable FZWorseQueryGrantDirectory(NSString *path);
FOUNDATION_EXPORT NSString * _Nullable FZWorseQueryResolveAppDataContainer(NSString *bundleID);
FOUNDATION_EXPORT NSString *FZWorseQueryLastStatus(void);
FOUNDATION_EXPORT BOOL FZWorseQueryEntitlementPresent(void);

NS_ASSUME_NONNULL_END
