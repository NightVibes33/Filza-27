@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "ByeTunesFullAppLauncher.h"
#import "FilzaDiagnostics.h"

static IMP gByeTunesOriginalOpenMusicLibrary = NULL;
static IMP gByeTunesOriginalBackgroundSessionHandler = NULL;
static BOOL gByeTunesDirectRouteInstalled = NO;
static BOOL gByeTunesBackgroundSessionRouteInstalled = NO;

static void ByeTunesHandleBackgroundSession(id self, SEL _cmd,
                                             UIApplication *application,
                                             NSString *identifier,
                                             void (^completionHandler)(void))
{
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL bridge = NSSelectorFromString(
        @"handleBackgroundEventsForSessionIdentifier:completionHandler:");
    BOOL handled = NO;
    if (factory && [factory respondsToSelector:bridge]) {
        handled = ((BOOL (*)(id, SEL, NSString *, void (^)(void)))objc_msgSend)(
            factory, bridge, identifier, completionHandler);
    }
    if (handled) {
        FilzaDiagnosticsWriteByeTunesStage(
            @"forwarded ByeTunes 2.4 background URL session event");
        return;
    }

    if (gByeTunesOriginalBackgroundSessionHandler) {
        ((void (*)(id, SEL, UIApplication *, NSString *, void (^)(void)))
            gByeTunesOriginalBackgroundSessionHandler)(
                self, _cmd, application, identifier, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }
}

static void ByeTunesInstallBackgroundSessionRoute(void)
{
    if (gByeTunesBackgroundSessionRouteInstalled) return;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    Class delegateClass = delegate ? [delegate class] : Nil;
    if (!delegateClass) return;

    SEL selector = @selector(application:handleEventsForBackgroundURLSession:completionHandler:);
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (method) {
        IMP current = method_getImplementation(method);
        if (current != (IMP)ByeTunesHandleBackgroundSession) {
            gByeTunesOriginalBackgroundSessionHandler = current;
            method_setImplementation(method, (IMP)ByeTunesHandleBackgroundSession);
        }
    } else {
        class_addMethod(delegateClass, selector,
                        (IMP)ByeTunesHandleBackgroundSession, "v@:@@@?");
    }
    gByeTunesBackgroundSessionRouteInstalled = YES;
    FilzaDiagnosticsWriteByeTunesStage(
        @"ByeTunes 2.4 background URL session route installed on Filza AppDelegate");
}

static UIViewController *ByeTunesTopController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window) break;
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

static UIViewController *ByeTunesMakeFullController(void)
{
    FilzaDiagnosticsWriteByeTunesStage(@"direct route entered full ByeTunes factory");
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsWriteByeTunesStage(@"direct route Swift host factory unavailable");
        return nil;
    }
    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        FilzaDiagnosticsWriteByeTunesStage(controller
            ? @"direct route factory returned complete ByeTunes controller"
            : @"direct route factory returned nil");
        return controller;
    } @catch (NSException *exception) {
        FilzaDiagnosticsWriteByeTunesStage([NSString stringWithFormat:
            @"direct route factory exception: %@", exception.reason ?: exception.name]);
        return nil;
    }
}

BOOL FilzaByeTunesPresentFromController(UIViewController *presenter)
{
    UIViewController *host = presenter ?: ByeTunesTopController();
    if (!host) {
        FilzaDiagnosticsWriteByeTunesStage(@"direct route has no active presenter yet");
        return NO;
    }

    UIViewController *full = ByeTunesMakeFullController();
    if (!full) return NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = host;
        while (target.presentedViewController) target = target.presentedViewController;
        FilzaDiagnosticsWriteByeTunesStage([NSString stringWithFormat:
            @"direct route presenting from %@", NSStringFromClass(target.class)]);
        @try {
            [target presentViewController:full animated:YES completion:^{
                FilzaDiagnosticsWriteByeTunesStage(
                    @"direct route presented complete ByeTunes screen");
            }];
        } @catch (NSException *exception) {
            FilzaDiagnosticsWriteByeTunesStage([NSString stringWithFormat:
                @"direct route presentation exception: %@",
                exception.reason ?: exception.name]);
        }
    });
    return YES;
}

static void ByeTunesOpenMusicLibrary(id self, SEL _cmd)
{
    FilzaDiagnosticsWriteByeTunesStage(@"TGMainView openMusicLib intercepted by direct route");
    UIViewController *presenter = [self isKindOfClass:UIViewController.class]
        ? (UIViewController *)self : ByeTunesTopController();
    if (FilzaByeTunesPresentFromController(presenter))
        return;

    // Preserve Filza's legacy route only if the full embedded host could not be
    // constructed. This keeps the button useful in a partially linked build.
    FilzaDiagnosticsWriteByeTunesStage(@"direct route unavailable; invoking legacy openMusicLib fallback");
    if (gByeTunesOriginalOpenMusicLibrary)
        ((void (*)(id, SEL))gByeTunesOriginalOpenMusicLibrary)(self, _cmd);
}

void FilzaByeTunesInstallDirectRoutes(void)
{
    ByeTunesInstallBackgroundSessionRoute();
    if (gByeTunesDirectRouteInstalled) return;
    Class mainClass = NSClassFromString(@"TGMainView");
    SEL selector = NSSelectorFromString(@"openMusicLib");
    Method resolved = mainClass ? class_getInstanceMethod(mainClass, selector) : NULL;
    if (!resolved) {
        FilzaDiagnosticsWriteByeTunesStage(@"TGMainView openMusicLib not available yet");
        return;
    }

    IMP current = method_getImplementation(resolved);
    if (current != (IMP)ByeTunesOpenMusicLibrary) {
        gByeTunesOriginalOpenMusicLibrary = current;
        const char *types = method_getTypeEncoding(resolved);
        if (!class_addMethod(mainClass, selector, (IMP)ByeTunesOpenMusicLibrary, types))
            method_setImplementation(class_getInstanceMethod(mainClass, selector),
                                     (IMP)ByeTunesOpenMusicLibrary);
    }
    gByeTunesDirectRouteInstalled = YES;
    FilzaDiagnosticsWriteByeTunesStage(@"TGMainView direct full ByeTunes route installed");
}

__attribute__((constructor)) static void ByeTunesFullAppInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                FilzaByeTunesInstallDirectRoutes();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{ FilzaByeTunesInstallDirectRoutes(); });
            }];

        FilzaByeTunesInstallDirectRoutes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FilzaByeTunesInstallDirectRoutes(); });
    });
}
