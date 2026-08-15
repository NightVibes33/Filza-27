@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "Filza3105Bridge.h"
#import "FilzaDiagnostics.h"

static BOOL (*F3105OriginalApplicationOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *) = NULL;
static Class F3105HookedApplicationDelegateClass = Nil;
static NSURL *F3105PendingImportURL = nil;

static UIViewController *F3105ActiveController(void)
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
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;

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

static UIViewController *F3105MakeController(SEL selector, NSString *label)
{
    Class factory = NSClassFromString(@"Filza3105HostFactory");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"3105",
            [NSString stringWithFormat:@"%@ Swift host factory unavailable", label]);
        return nil;
    }

    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        if (!controller)
            FilzaDiagnosticsAppend(@"3105",
                [NSString stringWithFormat:@"%@ Swift host returned nil", label]);
        return controller;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"3105", [NSString stringWithFormat:
            @"%@ factory exception: %@", label,
            exception.reason ?: exception.name]);
        return nil;
    }
}

static UIViewController *F3105MakeImportController(NSURL *url)
{
    Class factory = NSClassFromString(@"Filza3105HostFactory");
    SEL selector = NSSelectorFromString(@"makePatchesImportControllerWithURL:");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"3105", @"3105 import host factory unavailable");
        return nil;
    }

    @try {
        return ((UIViewController *(*)(id, SEL, id))objc_msgSend)(factory, selector, url);
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"3105", [NSString stringWithFormat:
            @"3105 import factory exception: %@", exception.reason ?: exception.name]);
        return nil;
    }
}

static BOOL F3105Present(UIViewController *source, SEL selector, NSString *label)
{
    UIViewController *presenter = source ?: F3105ActiveController();
    if (!presenter) {
        FilzaDiagnosticsAppend(@"3105",
            [NSString stringWithFormat:@"%@ has no active presenter", label]);
        return NO;
    }
    UIViewController *controller = F3105MakeController(selector, label);
    if (!controller) return NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = presenter;
        while (target.presentedViewController)
            target = target.presentedViewController;
        [target presentViewController:controller animated:YES completion:^{
            FilzaDiagnosticsAppend(@"3105",
                [NSString stringWithFormat:@"presented complete %@ directly", label]);
        }];
    });
    return YES;
}

static BOOL F3105IsPatchImportURL(NSURL *url)
{
    if (!url) return NO;
    if (url.isFileURL)
        return [[url.pathExtension lowercaseString] isEqualToString:@"3105"];
    return [[url.scheme lowercaseString] isEqualToString:@"threeoneosfive"];
}

static BOOL F3105TryPresentPendingImport(void)
{
    NSURL *url = F3105PendingImportURL;
    if (!url) return YES;

    UIViewController *presenter = F3105ActiveController();
    if (!presenter) return NO;
    UIViewController *controller = F3105MakeImportController(url);
    if (!controller) return NO;

    F3105PendingImportURL = nil;
    UIViewController *target = presenter;
    while (target.presentedViewController)
        target = target.presentedViewController;
    [target presentViewController:controller animated:YES completion:^{
        FilzaDiagnosticsAppend(@"3105",
            [NSString stringWithFormat:@"presented 3105 1.0 import route for %@", url.lastPathComponent ?: url.absoluteString]);
    }];
    return YES;
}

static void F3105DrainPendingImport(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (F3105TryPresentPendingImport()) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            F3105TryPresentPendingImport();
        });
    });
}

static BOOL F3105ApplicationOpenURL(id delegate,
                                    SEL selector,
                                    UIApplication *application,
                                    NSURL *url,
                                    NSDictionary *options)
{
    if (F3105IsPatchImportURL(url)) {
        F3105PendingImportURL = [url copy];
        FilzaDiagnosticsAppend(@"3105",
            [NSString stringWithFormat:@"received external 3105 import URL scheme=%@ extension=%@",
             url.scheme ?: @"file", url.pathExtension ?: @""]);
        F3105DrainPendingImport();
        return YES;
    }

    return F3105OriginalApplicationOpenURL
        ? F3105OriginalApplicationOpenURL(delegate, selector, application, url, options)
        : NO;
}

static void F3105InstallOpenURLHook(void)
{
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;

    Class delegateClass = object_getClass(delegate);
    if (!delegateClass || delegateClass == F3105HookedApplicationDelegateClass) return;

    SEL selector = NSSelectorFromString(@"application:openURL:options:");
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (method) {
        IMP current = method_getImplementation(method);
        if (current != (IMP)F3105ApplicationOpenURL) {
            F3105OriginalApplicationOpenURL =
                (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))current;
            method_setImplementation(method, (IMP)F3105ApplicationOpenURL);
        }
    } else {
        class_addMethod(delegateClass,
                        selector,
                        (IMP)F3105ApplicationOpenURL,
                        "B40@0:8@16@24@32");
    }

    F3105HookedApplicationDelegateClass = delegateClass;
    FilzaDiagnosticsAppend(@"3105",
        @"installed 3105 1.0 document/custom-URL import bridge on Filza app delegate");
}

BOOL Filza3105PresentAppsFromController(UIViewController *source)
{
    return F3105Present(source, NSSelectorFromString(@"makeAppsManagerController"),
                        @"3105 Apps Manager");
}

BOOL Filza3105PresentPatchesFromController(UIViewController *source)
{
    return F3105Present(source, NSSelectorFromString(@"makePatchesController"),
                        @"3105 Patches");
}

__attribute__((constructor)) static void Filza3105BridgeInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            F3105InstallOpenURLHook();
            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                F3105InstallOpenURLHook();
                F3105DrainPendingImport();
            }];
            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                F3105InstallOpenURLHook();
                F3105DrainPendingImport();
            }];
        });
    }
}
