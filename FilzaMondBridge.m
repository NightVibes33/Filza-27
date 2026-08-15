@import UIKit;

#import <objc/message.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"

static UIViewController *FMActiveController(void)
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

static void FMShowUnavailable(UIViewController *source, NSString *message)
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"mond unavailable"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [source presentViewController:alert animated:YES completion:nil];
}

static UIViewController *FMCreateHost(void)
{
    Class factory = NSClassFromString(@"MondEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"mond", @"current embedded mond host factory unavailable");
        return nil;
    }

    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        if (![controller isKindOfClass:UIViewController.class]) {
            FilzaDiagnosticsAppend(@"mond", @"current embedded mond host returned no controller");
            return nil;
        }
        return controller;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"mond", [NSString stringWithFormat:
            @"current embedded mond host exception: %@",
            exception.reason ?: exception.name]);
        return nil;
    }
}

static BOOL FMPresentHost(UIViewController *source)
{
    UIViewController *controller = FMCreateHost();
    if (!controller) {
        FMShowUnavailable(source, @"The current mond interface could not be created.");
        return NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = source;
        while (target.presentedViewController)
            target = target.presentedViewController;
        [target presentViewController:controller animated:YES completion:^{
            FilzaDiagnosticsAppend(@"mond",
                @"presented full current mond root directly");
        }];
    });
    return YES;
}

void FilzaMondPresentFromController(UIViewController *source)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = source ?: FMActiveController();
        if (!presenter) {
            FilzaDiagnosticsAppend(@"mond", @"no presenter available");
            return;
        }
        FMPresentHost(presenter);
    });
}

void FilzaMondPresent(void)
{
    FilzaMondPresentFromController(FMActiveController());
}

__attribute__((constructor)) static void FilzaMondInstall(void)
{
    FilzaDiagnosticsAppend(@"mond",
        @"full current mond route installed commit=4a37bfca5cb4abb2c99891972365d872d700525e");
}
