@import UIKit;

#import <objc/runtime.h>

#import "Filza3105Bridge.h"
#import "FilzaDiagnostics.h"

static IMP gF3105OriginalOpenApps = NULL;
static BOOL gF3105AppsRouteInstalled = NO;

static void F3105OpenApps(id self, SEL _cmd)
{
    FilzaDiagnosticsAppend(@"3105", @"TGMainView openApps intercepted by 3105 route");
    UIViewController *source = [self isKindOfClass:UIViewController.class]
        ? (UIViewController *)self : nil;
    if (Filza3105PresentAppsFromController(source)) return;

    FilzaDiagnosticsAppend(@"3105", @"3105 Apps route unavailable; using Filza fallback");
    if (gF3105OriginalOpenApps)
        ((void (*)(id, SEL))gF3105OriginalOpenApps)(self, _cmd);
}

static void F3105InstallAppsRoute(void)
{
    if (gF3105AppsRouteInstalled) return;
    Class cls = NSClassFromString(@"TGMainView");
    SEL selector = NSSelectorFromString(@"openApps");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;

    IMP current = method_getImplementation(method);
    if (current != (IMP)F3105OpenApps) {
        gF3105OriginalOpenApps = current;
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(cls, selector, (IMP)F3105OpenApps, types))
            method_setImplementation(class_getInstanceMethod(cls, selector),
                                     (IMP)F3105OpenApps);
    }
    gF3105AppsRouteInstalled = YES;
    FilzaDiagnosticsAppend(@"3105", @"TGMainView complete 3105 Apps route installed");
}

__attribute__((constructor)) static void Filza3105AppLauncherInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        F3105InstallAppsRoute();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                F3105InstallAppsRoute();
            }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ F3105InstallAppsRoute(); });
    });
}
