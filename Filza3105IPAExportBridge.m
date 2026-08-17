#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * _Nullable filzaAppBundlePathForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) return nil;

    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleID);
    if (!proxy) return nil;

    for (NSString *selectorName in @[@"bundleURL", @"bundleContainerURL"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![proxy respondsToSelector:selector]) continue;

        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        NSString *path = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            path = [(NSURL *)value path];
        } else if ([value isKindOfClass:[NSString class]]) {
            path = (NSString *)value;
        }

        if (path.length == 0) continue;

        // bundleURL should already point at the .app. Some releases expose the
        // containing UUID directory from alternate selectors, so only accept a
        // direct .app path here rather than guessing a child bundle name.
        if ([[path pathExtension] caseInsensitiveCompare:@"app"] == NSOrderedSame) {
            return path;
        }
    }

    return nil;
}
