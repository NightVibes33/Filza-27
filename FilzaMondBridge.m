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

@interface FMDeferredGestaltController : UIViewController
@property(nonatomic) BOOL resolutionStarted;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIViewController *embeddedHost;
@end

@implementation FMDeferredGestaltController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Gestalt Editor";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner startAnimating];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Opening the complete Gestalt Editor…";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    self.retryButton.hidden = YES;
    [self.retryButton addTarget:self action:@selector(fm_retry)
               forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.spinner];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.retryButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [self.spinner.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-18.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:18.0],
        [self.retryButton.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
    ]];
    FilzaDiagnosticsAppend(@"Gestalt", @"visible Gestalt loading screen attached");
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self fm_startResolution];
}

- (void)fm_close
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)fm_retry
{
    self.resolutionStarted = NO;
    self.retryButton.hidden = YES;
    self.statusLabel.text = @"Retrying MobileGestalt access…";
    [self.spinner startAnimating];
    [self fm_startResolution];
}

- (void)fm_startResolution
{
    if (self.resolutionStarted || self.embeddedHost) return;
    self.resolutionStarted = YES;
    FilzaDiagnosticsAppend(@"Gestalt", @"visible screen requesting verified MobileGestalt access");

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        NSString *path = FilzaGestaltResolvePath(&detail);
        dispatch_async(dispatch_get_main_queue(), ^{
            FMDeferredGestaltController *strongSelf = weakSelf;
            if (!strongSelf) return;

            if (!path.length) {
                NSString *reason = detail ?: @"The MobileGestalt property list could not be opened.";
                FilzaDiagnosticsAppend(@"Gestalt",
                    [NSString stringWithFormat:@"MobileGestalt access failed on visible screen: %@", reason]);
                [strongSelf.spinner stopAnimating];
                strongSelf.statusLabel.text = [NSString stringWithFormat:
                    @"Gestalt Editor could not access MobileGestalt.\n\n%@", reason];
                strongSelf.retryButton.hidden = NO;
                strongSelf.resolutionStarted = NO;
                return;
            }

            FilzaDiagnosticsAppend(@"Gestalt",
                [NSString stringWithFormat:@"verified MobileGestalt access: %@", detail ?: path]);
            UIViewController *host = FMCreateHost(path);
            if (!host) {
                [strongSelf.spinner stopAnimating];
                strongSelf.statusLabel.text =
                    @"The complete embedded Gestalt Editor was not linked into this build.";
                strongSelf.retryButton.hidden = NO;
                strongSelf.resolutionStarted = NO;
                return;
            }

            [strongSelf addChildViewController:host];
            UIView *hostView = host.view;
            hostView.translatesAutoresizingMaskIntoConstraints = NO;
            [strongSelf.view addSubview:hostView];
            [NSLayoutConstraint activateConstraints:@[
                [hostView.leadingAnchor constraintEqualToAnchor:strongSelf.view.leadingAnchor],
                [hostView.trailingAnchor constraintEqualToAnchor:strongSelf.view.trailingAnchor],
                [hostView.topAnchor constraintEqualToAnchor:strongSelf.view.topAnchor],
                [hostView.bottomAnchor constraintEqualToAnchor:strongSelf.view.bottomAnchor],
            ]];
            [host didMoveToParentViewController:strongSelf];
            strongSelf.embeddedHost = host;
            [strongSelf.spinner removeFromSuperview];
            [strongSelf.statusLabel removeFromSuperview];
            [strongSelf.retryButton removeFromSuperview];
            FilzaDiagnosticsAppend(@"Gestalt",
                [NSString stringWithFormat:@"attached complete Gestalt editor using %@", path]);
        });
    });
}

@end

static void FMPresentDeferredHost(UIViewController *source)
{
    FMDeferredGestaltController *controller = [FMDeferredGestaltController new];

    UINavigationController *navigation = source.navigationController;
    if (navigation && !source.presentedViewController) {
        [navigation pushViewController:controller animated:YES];
    } else {
        controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
            target:controller action:@selector(fm_close)];
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:controller];
        wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
        [source presentViewController:wrapper animated:YES completion:nil];
    }
    FilzaDiagnosticsAppend(@"Gestalt", @"presented visible Gestalt loading screen immediately");
}

void FilzaMondPresentFromController(UIViewController *source)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = source ?: FMActiveController();
        if (!presenter) {
            FilzaDiagnosticsAppend(@"Gestalt", @"no presenter available");
            return;
        }

        FMPresentDeferredHost(presenter);
    });
}

void FilzaMondPresent(void)
{
    FilzaMondPresentFromController(FMActiveController());
}
