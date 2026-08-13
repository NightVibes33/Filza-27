@import UIKit;

#import <objc/message.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"
#import "GestaltManager.h"

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
        alertControllerWithTitle:@"Gestalt Editor unavailable"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [source presentViewController:alert animated:YES completion:nil];
}

static UIViewController *FMCreateHost(NSString *path)
{
    Class factory = NSClassFromString(@"MondGestaltHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewControllerWithPath:");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"Gestalt", @"complete embedded Gestalt host factory unavailable");
        return nil;
    }

    UIViewController *controller =
        ((id (*)(id, SEL, id))objc_msgSend)(factory, selector, path);
    if (![controller isKindOfClass:UIViewController.class]) {
        FilzaDiagnosticsAppend(@"Gestalt", @"complete embedded Gestalt host returned no controller");
        return nil;
    }
    return controller;
}

@interface FMGestaltNavigationController : UINavigationController
@end

@implementation FMGestaltNavigationController
- (void)fm_close
{
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static BOOL FMPresentHost(UIViewController *source, NSString *path)
{
    UIViewController *controller = FMCreateHost(path);
    if (!controller) {
        FMShowUnavailable(source, @"The complete Gestalt Editor could not be created.");
        return NO;
    }

    UINavigationController *navigation = source.navigationController;
    if (navigation && !source.presentedViewController) {
        [navigation pushViewController:controller animated:YES];
    } else {
        FMGestaltNavigationController *wrapper =
            [[FMGestaltNavigationController alloc] initWithRootViewController:controller];
        controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
            target:wrapper action:@selector(fm_close)];
        wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
        [source presentViewController:wrapper animated:YES completion:nil];
    }
    FilzaDiagnosticsAppend(@"Gestalt",
        [NSString stringWithFormat:@"presented complete Gestalt Editor directly using %@", path]);
    return YES;
}

void FilzaMondPresentFromController(UIViewController *source)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = source ?: FMActiveController();
        if (!presenter) {
            FilzaDiagnosticsAppend(@"Gestalt", @"no presenter available");
            return;
        }

        __weak UIViewController *weakPresenter = presenter;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *detail = nil;
            NSString *path = FilzaGestaltResolvePath(&detail);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *resolvedPresenter = weakPresenter ?: FMActiveController();
                if (!resolvedPresenter) return;
                if (!path.length) {
                    NSString *reason = detail ?:
                        @"The MobileGestalt property list could not be opened.";
                    FilzaDiagnosticsAppend(@"Gestalt",
                        [NSString stringWithFormat:@"MobileGestalt access failed: %@", reason]);
                    FMShowUnavailable(resolvedPresenter, reason);
                    return;
                }
                FilzaDiagnosticsAppend(@"Gestalt",
                    [NSString stringWithFormat:@"verified MobileGestalt access: %@", detail ?: path]);
                FMPresentHost(resolvedPresenter, path);
            });
        });
    });
}

void FilzaMondPresent(void)
{
    FilzaMondPresentFromController(FMActiveController());
}

__attribute__((constructor)) static void FilzaMondPrewarm(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *detail = nil;
        NSString *path = FilzaGestaltResolvePath(&detail);
        FilzaDiagnosticsAppend(@"Gestalt", path.length
            ? @"prewarmed MobileGestalt access for direct presentation"
            : [NSString stringWithFormat:@"MobileGestalt prewarm unavailable: %@", detail ?: @"unknown"]);
    });
}
