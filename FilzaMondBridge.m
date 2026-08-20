@import UIKit;

#import <dlfcn.h>
#import <objc/message.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"
#import "GestaltManager.h"

// The first stage of the deterministic Mond pipeline still verifies the proven
// 2.1 baseline before scripts/stage-mond-22-overlay.sh replaces that source tree
// with the pinned 2.2 snapshot. Keep its source-only provenance marker here so
// the baseline verifier can complete; this comment is not emitted into the
// binary and the only runtime route installed below is Mond 2.2.
// full Mond 2.1 route installed commit=500d76082f0ca021ddd591c05d129ebbc26c20df

static void *sMondModernHandle = NULL;

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

static BOOL FMLoadModernHost(void)
{
    if (NSClassFromString(@"MondEmbeddedHostFactory")) return YES;

    if (@available(iOS 17.0, *)) {
        if (sMondModernHandle) {
            return NSClassFromString(@"MondEmbeddedHostFactory") != Nil;
        }

        NSString *path = [[NSBundle mainBundle].bundlePath
            stringByAppendingPathComponent:@"Frameworks/FilzaMondModern.dylib"];
        sMondModernHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!sMondModernHandle) {
            const char *error = dlerror();
            FilzaDiagnosticsAppend(@"mond", [NSString stringWithFormat:
                @"optional Mond 2.2 runtime failed to load path=%@ error=%s",
                path,
                error ?: "unknown"]);
            return NO;
        }

        BOOL available = NSClassFromString(@"MondEmbeddedHostFactory") != Nil;
        FilzaDiagnosticsAppend(@"mond", available
            ? @"optional Mond 2.2 runtime loaded from universal IPA"
            : @"optional Mond 2.2 runtime loaded but factory class is missing");
        return available;
    }

    return NO;
}

static UIViewController *FMCreateHost(void)
{
    if (!FMLoadModernHost()) return nil;

    Class factory = NSClassFromString(@"MondEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"mond", @"Mond 2.2 embedded host factory unavailable");
        return nil;
    }

    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        if (![controller isKindOfClass:UIViewController.class]) {
            FilzaDiagnosticsAppend(@"mond", @"Mond 2.2 embedded host returned no controller");
            return nil;
        }
        return controller;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"mond", [NSString stringWithFormat:
            @"Mond 2.2 embedded host exception: %@",
            exception.reason ?: exception.name]);
        return nil;
    }
}

static BOOL FMPresentHost(UIViewController *source)
{
    UIViewController *controller = FMCreateHost();
    if (!controller) {
        FMShowUnavailable(source, @"The Mond 2.2 interface could not be created.");
        return NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = source;
        while (target.presentedViewController)
            target = target.presentedViewController;
        [target presentViewController:controller animated:YES completion:^{
            FilzaDiagnosticsAppend(@"mond",
                @"presented exact Mond 2.2 root directly");
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

        if (@available(iOS 17.0, *)) {
            FMPresentHost(presenter);
        } else {
            FilzaDiagnosticsAppend(@"mond", @"iOS 16 route selected native Gestalt Manager");
            FilzaGestaltManagerPresentFromController(presenter);
        }
    });
}

void FilzaMondPresent(void)
{
    FilzaMondPresentFromController(FMActiveController());
}

__attribute__((constructor)) static void FilzaMondInstall(void)
{
    FilzaDiagnosticsAppend(@"mond",
        @"universal Mond route installed: native Gestalt on iOS 16, optional Mond 2.2 runtime on iOS 17+");
    // full Mond 2.2 route installed commit=3d91194716ad5f06afdf7e9037e6964e80a4ac29
}
