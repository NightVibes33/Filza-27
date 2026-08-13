@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"

static NSString *const FQAppsType = @"com.nightvibes33.filzaslop.apps-manager";
static NSString *const FQMusicType = @"com.nightvibes33.filzaslop.music-library";

static IMP gFQPreviousShortcutHandler = NULL;
static BOOL gFQShortcutHookInstalled = NO;

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
    if ([type isEqualToString:FQAppsType] || [type isEqualToString:FQMusicType]) {
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
    if (gFQShortcutHookInstalled) return;
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;

    Class cls = object_getClass(delegate);
    SEL selector = @selector(application:performActionForShortcutItem:completionHandler:);
    Method resolved = class_getInstanceMethod(cls, selector);
    if (resolved) {
        IMP current = method_getImplementation(resolved);
        if (current == (IMP)FQShortcutHandler) {
            gFQShortcutHookInstalled = YES;
            return;
        }
        gFQPreviousShortcutHandler = current;
        const char *types = method_getTypeEncoding(resolved);
        if (!class_addMethod(cls, selector, (IMP)FQShortcutHandler, types))
            method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)FQShortcutHandler);
    } else {
        class_addMethod(cls, selector, (IMP)FQShortcutHandler, "v@:@@@?");
    }

    gFQShortcutHookInstalled = YES;
    FilzaDiagnosticsAppend(@"QuickAction",
        [NSString stringWithFormat:@"Apps/Music delegate hook installed on %@", NSStringFromClass(cls)]);
}

static void FQRemoveDynamicShortcutDuplicates(void)
{
    // UIApplication.shortcutItems is the dynamic-only list. The Gestalt
    // manager previously added a second dynamic copy; clearing this list leaves
    // the packaged static actions intact.
    UIApplication.sharedApplication.shortcutItems = @[];
    FilzaDiagnosticsAppend(@"QuickAction", @"cleared legacy dynamic shortcut items");
}

static void FQRefreshRuntimeRouting(void)
{
    FQInstallShortcutHandler();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        FQRemoveDynamicShortcutDuplicates();
        FQInstallShortcutHandler();
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
