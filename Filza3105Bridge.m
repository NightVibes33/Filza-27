@import UIKit;

#import <objc/message.h>

#import "Filza3105Bridge.h"
#import "FilzaDiagnostics.h"

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
