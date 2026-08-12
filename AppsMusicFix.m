@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "MCMBridge.h"
#import "MCMFilzaIntegration.h"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
@end

static IMP gPreviousAllApplications = NULL;
static IMP gPreviousAppsDidSelect = NULL;

static NSString *FilzaProxyIdentifier(id proxy)
{
    SEL selector = NSSelectorFromString(@"applicationIdentifier");
    if ([proxy respondsToSelector:selector])
        return ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
    return nil;
}

static NSString *FilzaProxyDisplayName(id proxy)
{
    SEL selector = NSSelectorFromString(@"localizedName");
    if ([proxy respondsToSelector:selector]) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if (name.length) return name;
    }
    return FilzaProxyIdentifier(proxy) ?: @"";
}

static id FilzaAllApplications(id self, SEL _cmd)
{
    NSArray *existing = gPreviousAllApplications
        ? ((id (*)(id, SEL))gPreviousAllApplications)(self, _cmd) : @[];
    if (![existing isKindOfClass:NSArray.class]) existing = @[];

    NSMutableDictionary<NSString *, id> *byIdentifier = [NSMutableDictionary dictionary];
    for (id proxy in existing) {
        NSString *identifier = FilzaProxyIdentifier(proxy);
        if (identifier.length) byIdentifier[identifier] = proxy;
    }

    NSString *detail = nil;
    NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 2048, &detail);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        for (NSString *identifier in identifiers ?: @[]) {
            if (!identifier.length || byIdentifier[identifier]) continue;
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                proxySelector, identifier);
            if (proxy) byIdentifier[identifier] = proxy;
        }
    }

    NSArray *result = [byIdentifier.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(id left, id right) {
            return [FilzaProxyDisplayName(left) localizedCaseInsensitiveCompare:
                FilzaProxyDisplayName(right)];
        }];
    NSLog(@"[AppsManagerFix] workspace=%lu mcm=%lu merged=%lu detail=%@",
        (unsigned long)existing.count, (unsigned long)identifiers.count,
        (unsigned long)result.count, detail);
    return result;
}

static id FilzaObjectAtIndexSafely(id collection, NSUInteger index)
{
    if (![collection respondsToSelector:@selector(count)] ||
        ![collection respondsToSelector:@selector(objectAtIndex:)]) return nil;
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(collection, @selector(count));
    if (index >= count) return nil;
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection,
        @selector(objectAtIndex:), index);
}

static NSString *FilzaApplicationItemIdentifier(id item)
{
    for (NSString *name in @[@"bundleId", @"applicationIdentifier"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            NSString *value = ((id (*)(id, SEL))objc_msgSend)(item, selector);
            if ([value isKindOfClass:NSString.class] && value.length) return value;
        }
    }
    SEL proxySelector = NSSelectorFromString(@"appProxy");
    if ([item respondsToSelector:proxySelector])
        return FilzaProxyIdentifier(((id (*)(id, SEL))objc_msgSend)(item, proxySelector));
    return nil;
}

static void FilzaAppsDidSelect(id self, SEL _cmd, id browserView, id indexPath)
{
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    id fileList = [self respondsToSelector:fileListSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self, fileListSelector) : nil;
    NSUInteger row = [indexPath respondsToSelector:@selector(row)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row)) : NSNotFound;
    id item = row == NSNotFound ? nil : FilzaObjectAtIndexSafely(fileList, row);
    NSString *identifier = FilzaApplicationItemIdentifier(item);
    if (identifier.length) {
        NSString *detail = nil;
        NSString *container = MCMFilzaDataContainerPath(identifier, &detail);
        SEL setter = NSSelectorFromString(@"setDocumentPath:");
        if (container.length && [item respondsToSelector:setter])
            ((void (*)(id, SEL, id))objc_msgSend)(item, setter, container);
        NSLog(@"[AppsManagerFix] id=%@ container=%@ detail=%@",
              identifier, container, detail);
    }
    if (gPreviousAppsDidSelect)
        ((void (*)(id, SEL, id, id))gPreviousAppsDidSelect)(self, _cmd,
            browserView, indexPath);
}

static IMP FilzaReplaceInstanceMethod(Class cls, SEL selector, IMP replacement)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    IMP old = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return old;
}

static void FilzaInstallAppsManagerFixes(void)
{
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    gPreviousAllApplications = FilzaReplaceInstanceMethod(workspace,
        NSSelectorFromString(@"allApplications"), (IMP)FilzaAllApplications);

    Class apps = NSClassFromString(@"TGApplicationsViewController");
    gPreviousAppsDidSelect = FilzaReplaceInstanceMethod(apps,
        NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"),
        (IMP)FilzaAppsDidSelect);

    NSLog(@"[AppsManagerFix] ContainerManager-backed Apps Manager hooks installed");
}

__attribute__((constructor)) static void FilzaAppsManagerFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ FilzaInstallAppsManagerFixes(); });
}
