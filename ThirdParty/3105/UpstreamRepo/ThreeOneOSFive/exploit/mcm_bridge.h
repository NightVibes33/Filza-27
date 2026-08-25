#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t cls,
    NSUInteger limit,
    NSString * _Nullable * _Nullable error
);
NSString * _Nullable MCMContainerPathForIdentifier(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString * _Nullable * _Nullable error
);
NSString * _Nullable MCMActivateContainerPath(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString * _Nullable * _Nullable error
);
BOOL MCMBridgeAvailable(void);
int64_t MCMActivateContainer(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
