@import UIKit;
#import <objc/runtime.h>
#import "GestaltManager.h"

static IMP gOriginalTableDidMoveToWindow = NULL;
static BOOL gTableLifecycleHookInstalled = NO;

static void ManagerTableDidMoveToWindow(UITableView *tableView, SEL selector)
{
    if (gOriginalTableDidMoveToWindow)
        ((void (*)(id, SEL))gOriginalTableDidMoveToWindow)(tableView, selector);
    if (!tableView.window) return;

    // The managers table can be created well after application launch. Re-run
    // discovery at the moment a table becomes visible, then once again after
    // Filza has had time to populate its rows.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FilzaGestaltManagerInstall();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FilzaGestaltManagerInstall();
    });
}

static void InstallManagerTableLifecycleHook(void)
{
    if (gTableLifecycleHookInstalled) return;
    Method method = class_getInstanceMethod(UITableView.class, @selector(didMoveToWindow));
    if (!method) return;
    gOriginalTableDidMoveToWindow = method_getImplementation(method);
    method_setImplementation(method, (IMP)ManagerTableDidMoveToWindow);
    gTableLifecycleHookInstalled = YES;
}

__attribute__((constructor)) static void ManagerMenuRuntimeFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallManagerTableLifecycleHook();
        FilzaGestaltManagerInstall();
    });
}
