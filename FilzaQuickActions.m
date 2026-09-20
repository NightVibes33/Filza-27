@import UIKit;
#import <objc/runtime.h>
#import "FilzaFeatureRouter.h"
#import "FilzaDiagnostics.h"

static IMP gPreviousHandler = NULL;
static IMP gPreviousSetter = NULL;
static BOOL gHandlerInstalled = NO;
static BOOL gSetterInstalled = NO;

static NSString *FQCanonical(NSString *type) {
    if ([type isEqualToString:@"3105"] || [type isEqualToString:@"apps-manager"] ||
        [type isEqualToString:@"com.nightvibes33.filzaslop.apps-manager"])
        return FilzaFeatureAppsManager;
    if ([type isEqualToString:@"music-library"]) return FilzaFeatureMusic;
    if ([type isEqualToString:@"gestalt-manager"]) return FilzaFeatureGestalt;
    if ([type isEqualToString:@"aircard"]) return FilzaFeatureAirCard;
    return type ?: @"";
}

static BOOL FQIsCanonical(NSString *type) {
    return [FilzaCanonicalFeatureIdentifiers() containsObject:FQCanonical(type)];
}

static UIViewController *FQActiveController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window.isKeyWindow) break;
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class]) next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static void FQOpenWithRetry(NSString *type, NSUInteger attempts) {
    NSString *canonical = FQCanonical(type);
    if (FilzaPresentFeature(canonical, FQActiveController())) return;
    if (attempts == 0) {
        FilzaDiagnosticsAppend(@"QuickAction", [NSString stringWithFormat:@"gave up opening %@", canonical]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FQOpenWithRetry(canonical, attempts - 1);
    });
}

static void FQHandler(id self, SEL cmd, UIApplication *application, UIApplicationShortcutItem *item, void (^completion)(BOOL)) {
    if (FQIsCanonical(item.type)) {
        dispatch_async(dispatch_get_main_queue(), ^{ FQOpenWithRetry(item.type, 16); });
        if (completion) completion(YES);
        return;
    }
    if (gPreviousHandler) ((void (*)(id, SEL, id, id, id))gPreviousHandler)(self, cmd, application, item, completion);
    else if (completion) completion(NO);
}

static void FQInstallHandler(void) {
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(application:performActionForShortcutItem:completionHandler:);
    Method method = class_getInstanceMethod(cls, sel);
    IMP current = method ? method_getImplementation(method) : NULL;
    if (current == (IMP)FQHandler) { gHandlerInstalled = YES; return; }
    if (method) {
        gPreviousHandler = current;
        if (!class_addMethod(cls, sel, (IMP)FQHandler, method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)FQHandler);
    } else class_addMethod(cls, sel, (IMP)FQHandler, "v@:@@@?");
    gHandlerInstalled = YES;
    FilzaDiagnosticsAppend(@"QuickAction", @"four-feature delegate hook installed");
}

static void FQSetShortcutItems(id self, SEL cmd, NSArray<UIApplicationShortcutItem *> *items) {
    NSMutableArray *filtered = [NSMutableArray array];
    for (UIApplicationShortcutItem *item in items ?: @[]) {
        NSString *type = item.type ?: @"";
        if (FQIsCanonical(type) || [type isEqualToString:@"com.nightvibes33.filzaslop.patches"] || [type isEqualToString:@"patches"]) continue;
        [filtered addObject:item];
    }
    if (gPreviousSetter) ((void (*)(id, SEL, id))gPreviousSetter)(self, cmd, filtered);
}

static void FQRefresh(void) {
    if (!gSetterInstalled) {
        Method method = class_getInstanceMethod(UIApplication.class, @selector(setShortcutItems:));
        if (method) {
            gPreviousSetter = method_getImplementation(method);
            if (gPreviousSetter != (IMP)FQSetShortcutItems) method_setImplementation(method, (IMP)FQSetShortcutItems);
            gSetterInstalled = YES;
        }
    }
    FQInstallHandler();
    UIApplication.sharedApplication.shortcutItems = @[];
}

__attribute__((constructor)) static void FilzaQuickActionsInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ FQRefresh(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ FQRefresh(); }];
        FQRefresh();
    });
}
