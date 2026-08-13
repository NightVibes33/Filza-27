@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"

static NSString *const FQAppsType = @"com.nightvibes33.filzaslop.apps-manager";
static NSString *const FQMusicType = @"com.nightvibes33.filzaslop.music-library";
static NSString *const FQGestaltType = @"com.nightvibes33.filzaslop.gestalt-manager";

static IMP gFQPreviousShortcutHandler = NULL;
static IMP gFQPreviousSetShortcutItems = NULL;
static BOOL gFQShortcutHookInstalled = NO;
static BOOL gFQShortcutSetterHookInstalled = NO;

static BOOL FQIsStaticShortcutType(NSString *type)
{
    return [type isEqualToString:FQAppsType] ||
           [type isEqualToString:FQMusicType] ||
           [type isEqualToString:FQGestaltType];
}

static UIViewController *FQActiveController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window.isKeyWindow) break;
    }
    if (!window) {
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
    }

    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static UIViewController *FQCreateController(NSString *className)
{
    Class cls = NSClassFromString(className);
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) return nil;

    id controller = [cls alloc];
    SEL nibInit = @selector(initWithNibName:bundle:);
    if ([controller respondsToSelector:nibInit])
        controller = ((id (*)(id, SEL, id, id))objc_msgSend)(controller, nibInit, nil, nil);
    else
        controller = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(init));
    return [controller isKindOfClass:UIViewController.class] ? controller : nil;
}

static BOOL FQPresentFilzaController(NSString *className, NSString *label)
{
    UIViewController *controller = FQCreateController(className);
    UIViewController *source = FQActiveController();
    if (!controller || !source) {
        FilzaDiagnosticsAppend(@"QuickAction",
            [NSString stringWithFormat:@"%@ unavailable class=%@ source=%@",
             label, className, source ? NSStringFromClass(source.class) : @"nil"]);
        return NO;
    }

    UINavigationController *navigation = source.navigationController;
    if (navigation && !source.presentedViewController) {
        [navigation pushViewController:controller animated:NO];
    } else {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:controller];
        wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
        [source presentViewController:wrapper animated:NO completion:nil];
    }
    FilzaDiagnosticsAppend(@"QuickAction",
        [NSString stringWithFormat:@"opened %@ using %@", label, className]);
    return YES;
}

static void FQOpenWithRetry(NSString *type, NSUInteger attempts)
{
    if (attempts == 0) {
        FilzaDiagnosticsAppend(@"QuickAction",
            [NSString stringWithFormat:@"gave up opening %@ after launch retries", type]);
        return;
    }

    BOOL opened = NO;
    if ([type isEqualToString:FQAppsType])
        opened = FQPresentFilzaController(@"TGApplicationsViewController", @"Apps Manager");
    else if ([type isEqualToString:FQMusicType])
        opened = FQPresentFilzaController(@"TGMusicLibraryViewController", @"Music Library");
    else if ([type isEqualToString:FQGestaltType]) {
        UIViewController *source = FQActiveController();
        if (source) {
            FilzaMondPresentFromController(source);
            FilzaDiagnosticsAppend(@"QuickAction", @"opened complete Gestalt Editor");
            opened = YES;
        }
    }

    if (!opened) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ FQOpenWithRetry(type, attempts - 1); });
    }
}

static void FQShortcutHandler(id self, SEL _cmd, UIApplication *application,
                              UIApplicationShortcutItem *item,
                              void (^completion)(BOOL))
{
    NSString *type = item.type ?: @"";
    if (FQIsStaticShortcutType(type)) {
        FilzaDiagnosticsAppend(@"QuickAction",
            [NSString stringWithFormat:@"received %@", type]);
        dispatch_async(dispatch_get_main_queue(), ^{ FQOpenWithRetry(type, 16); });
        if (completion) completion(YES);
        return;
    }

    if (gFQPreviousShortcutHandler)
        ((void (*)(id, SEL, id, id, id))gFQPreviousShortcutHandler)(self, _cmd, application, item, completion);
    else if (completion)
        completion(NO);
}

static void FQInstallShortcutHandler(void)
{
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;

    Class cls = object_getClass(delegate);
    SEL selector = @selector(application:performActionForShortcutItem:completionHandler:);
    Method resolved = class_getInstanceMethod(cls, selector);
    IMP current = resolved ? method_getImplementation(resolved) : NULL;
    if (current == (IMP)FQShortcutHandler) {
        gFQShortcutHookInstalled = YES;
        return;
    }

    if (resolved) {
        gFQPreviousShortcutHandler = current;
        const char *types = method_getTypeEncoding(resolved);
        if (!class_addMethod(cls, selector, (IMP)FQShortcutHandler, types))
            method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)FQShortcutHandler);
    } else {
        class_addMethod(cls, selector, (IMP)FQShortcutHandler, "v@:@@@?");
    }

    gFQShortcutHookInstalled = YES;
    FilzaDiagnosticsAppend(@"QuickAction",
        [NSString stringWithFormat:@"three-action delegate hook installed on %@", NSStringFromClass(cls)]);
}

static void FQSetShortcutItems(id self, SEL _cmd, NSArray<UIApplicationShortcutItem *> *items)
{
    NSMutableArray *filtered = [NSMutableArray array];
    for (UIApplicationShortcutItem *item in items ?: @[]) {
        if (FQIsStaticShortcutType(item.type ?: @"")) {
            FilzaDiagnosticsAppend(@"QuickAction",
                [NSString stringWithFormat:@"blocked dynamic duplicate %@", item.type ?: @"unknown"]);
            continue;
        }
        [filtered addObject:item];
    }
    if (gFQPreviousSetShortcutItems)
        ((void (*)(id, SEL, id))gFQPreviousSetShortcutItems)(self, _cmd, filtered);
}

static void FQInstallShortcutSetterFilter(void)
{
    if (gFQShortcutSetterHookInstalled) return;
    Class cls = UIApplication.class;
    SEL selector = @selector(setShortcutItems:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    gFQPreviousSetShortcutItems = method_getImplementation(method);
    if (gFQPreviousSetShortcutItems != (IMP)FQSetShortcutItems)
        method_setImplementation(method, (IMP)FQSetShortcutItems);
    gFQShortcutSetterHookInstalled = YES;
    FilzaDiagnosticsAppend(@"QuickAction", @"dynamic shortcut duplicate filter installed");
}

static void FQRemoveDynamicShortcutDuplicates(void)
{
    UIApplication.sharedApplication.shortcutItems = @[];
    FilzaDiagnosticsAppend(@"QuickAction", @"cleared dynamic shortcut list");
}

static void FQRefreshRuntimeRouting(void)
{
    FQInstallShortcutSetterFilter();
    FQInstallShortcutHandler();
    FQRemoveDynamicShortcutDuplicates();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        FQInstallShortcutHandler();
        FQRemoveDynamicShortcutDuplicates();
    });
}

__attribute__((constructor)) static void FilzaQuickActionsInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { FQRefreshRuntimeRouting(); }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { FQRefreshRuntimeRouting(); }];
        FQRefreshRuntimeRouting();
    });
}
