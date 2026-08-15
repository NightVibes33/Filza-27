@import UIKit;

#import <objc/message.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"
#import "GestaltManager.h"

static NSString * const FMCanonicalGestaltPath = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";

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

static UIViewController *FMCreateHost(NSString *path)
{
    Class factory = NSClassFromString(@"MondFullHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewControllerWithPath:");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"mond", @"full current mond host factory unavailable");
        return nil;
    }

    UIViewController *controller =
        ((id (*)(id, SEL, id))objc_msgSend)(factory, selector, path ?: FMCanonicalGestaltPath);
    if (![controller isKindOfClass:UIViewController.class]) {
        FilzaDiagnosticsAppend(@"mond", @"full current mond host returned no controller");
        return nil;
    }
    return controller;
}

@interface FMMondNavigationController : UINavigationController
@end

@implementation FMMondNavigationController
- (void)fm_close
{
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static BOOL FMPresentHost(UIViewController *source, NSString *path)
{
    UIViewController *controller = FMCreateHost(path);
    if (!controller) {
        FMShowUnavailable(source, @"The full mond workspace could not be created.");
        return NO;
    }

    UINavigationController *navigation = source.navigationController;
    if (navigation && !source.presentedViewController) {
        [navigation pushViewController:controller animated:YES];
    } else {
        FMMondNavigationController *wrapper =
            [[FMMondNavigationController alloc] initWithRootViewController:controller];
        controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
            target:wrapper action:@selector(fm_close)];
        wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
        [source presentViewController:wrapper animated:YES completion:nil];
    }
    FilzaDiagnosticsAppend(@"mond",
        [NSString stringWithFormat:@"presented full current mond workspace using Gestalt path %@",
         path ?: FMCanonicalGestaltPath]);
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

        // Resolve/prewarm MobileGestalt in the background, but never make mond's
        // root UI conditional on Gestalt access.  Upstream mond opens first and
        // lets Settings > Run Exploit change access/method at runtime.
        __weak UIViewController *weakPresenter = presenter;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *detail = nil;
            NSString *resolvedPath = FilzaGestaltResolvePath(&detail);
            NSString *hostPath = resolvedPath.length ? resolvedPath : FMCanonicalGestaltPath;
            FilzaDiagnosticsAppend(@"mond", resolvedPath.length
                ? [NSString stringWithFormat:@"prewarmed MobileGestalt access: %@", detail ?: resolvedPath]
                : [NSString stringWithFormat:@"opening mond before Gestalt access; Settings can run exploit: %@",
                   detail ?: @"no access yet"]);

            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *resolvedPresenter = weakPresenter ?: FMActiveController();
                if (!resolvedPresenter) return;
                FMPresentHost(resolvedPresenter, hostPath);
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
        FilzaDiagnosticsAppend(@"mond", path.length
            ? @"prewarmed MobileGestalt access for full mond root"
            : [NSString stringWithFormat:@"MobileGestalt prewarm unavailable; mond remains launchable: %@",
               detail ?: @"unknown"]);
    });
}
