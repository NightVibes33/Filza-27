@import UIKit;

#import <objc/message.h>

#import "Filza3105Bridge.h"
#import "FilzaDiagnostics.h"

static NSString *const F3105OriginalAppsCloseIdentifier =
    @"com.nightvibes33.filzaslop.3105.original-apps.close";

@interface F3105OriginalAppsNavigationController : UINavigationController
@end

@implementation F3105OriginalAppsNavigationController

- (void)f3105_closeOriginalApps
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)f3105_ensureCloseControl
{
    UIViewController *root = self.viewControllers.firstObject;
    if (!root) return;

    NSMutableArray<UIBarButtonItem *> *items =
        [NSMutableArray arrayWithArray:root.navigationItem.leftBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items)
        if ([item.accessibilityIdentifier isEqualToString:
                F3105OriginalAppsCloseIdentifier]) return;

    UIBarButtonItem *close = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(f3105_closeOriginalApps)];
    close.accessibilityIdentifier = F3105OriginalAppsCloseIdentifier;
    close.accessibilityLabel = @"Close Filza Apps Manager";
    [items insertObject:close atIndex:0];
    root.navigationItem.leftBarButtonItems = items;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self f3105_ensureCloseControl];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self f3105_ensureCloseControl];
}

@end

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

static UIViewController *F3105MakeFilzaController(NSString *className,
                                                  NSString *label)
{
    Class controllerClass = NSClassFromString(className);
    if (!controllerClass ||
        ![controllerClass isSubclassOfClass:UIViewController.class]) {
        FilzaDiagnosticsAppend(@"3105", [NSString stringWithFormat:
            @"%@ unavailable class=%@", label, className]);
        return nil;
    }

    @try {
        id controller = [controllerClass alloc];
        SEL nibInitializer = @selector(initWithNibName:bundle:);
        if ([controller respondsToSelector:nibInitializer])
            controller = ((id (*)(id, SEL, id, id))objc_msgSend)(
                controller, nibInitializer, nil, nil);
        else
            controller = ((id (*)(id, SEL))objc_msgSend)(
                controller, @selector(init));
        return [controller isKindOfClass:UIViewController.class]
            ? controller : nil;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"3105", [NSString stringWithFormat:
            @"%@ construction exception: %@", label,
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

BOOL Filza3105PresentOriginalAppsFromController(UIViewController *source)
{
    UIViewController *presenter = source ?: F3105ActiveController();
    UIViewController *controller = F3105MakeFilzaController(
        @"TGApplicationsViewController", @"original Filza Apps Manager");
    if (!presenter || !controller) {
        FilzaDiagnosticsAppend(@"3105",
            @"original Filza Apps Manager could not be presented");
        return NO;
    }

    F3105OriginalAppsNavigationController *navigation =
        [[F3105OriginalAppsNavigationController alloc]
            initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents =
            @[ UISheetPresentationControllerDetent.largeDetent ];
        navigation.sheetPresentationController.selectedDetentIdentifier =
            UISheetPresentationControllerDetentIdentifierLarge;
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = presenter;
        while (target.presentedViewController)
            target = target.presentedViewController;
        [target presentViewController:navigation animated:YES completion:^{
            FilzaDiagnosticsAppend(@"3105",
                @"presented original Filza Apps Manager with retained controls");
        }];
    });
    return YES;
}
