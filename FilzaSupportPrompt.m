@import UIKit;
@import SafariServices;
#import <objc/runtime.h>
#import "FilzaSupportProfileData.h"

static NSString * const kFilzaSupportURLString = @"https://buymeacoffee.com/zyn3";

@interface FilzaSupportViewController : UIViewController
@end

@implementation FilzaSupportViewController

static UIImage *FilzaSupportProfileImage(void) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:kFilzaSupportProfileJPEGBase64 options:0];
    if (!data.length) return nil;
    return [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"Support Filza 27";

    UIBarButtonItem *close = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self
        action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem = close;

    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];

    UIImageView *profile = [[UIImageView alloc] initWithImage:FilzaSupportProfileImage()];
    profile.translatesAutoresizingMaskIntoConstraints = NO;
    profile.contentMode = UIViewContentModeScaleAspectFill;
    profile.clipsToBounds = YES;
    profile.layer.cornerRadius = 58.0;
    profile.layer.cornerCurve = kCACornerCurveCircular;
    profile.layer.borderWidth = 2.0;
    profile.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.45].CGColor;
    profile.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Support Zyn";
    title.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *handle = [UILabel new];
    handle.translatesAutoresizingMaskIntoConstraints = NO;
    handle.text = @"buymeacoffee.com/zyn3";
    handle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    handle.textColor = UIColor.secondaryLabelColor;
    handle.textAlignment = NSTextAlignmentCenter;

    UIButton *coffee = [UIButton buttonWithType:UIButtonTypeSystem];
    coffee.translatesAutoresizingMaskIntoConstraints = NO;
    coffee.backgroundColor = [UIColor colorWithRed:1.0 green:0.867 blue:0.0 alpha:1.0];
    coffee.layer.cornerRadius = 14.0;
    coffee.layer.cornerCurve = kCACornerCurveContinuous;
    coffee.clipsToBounds = YES;
    coffee.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    [coffee setTitle:@"Buy me a coffee" forState:UIControlStateNormal];
    [coffee setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    UIImage *cup = [[UIImage systemImageNamed:@"cup.and.saucer.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [coffee setImage:cup forState:UIControlStateNormal];
    coffee.tintColor = UIColor.blackColor;
    coffee.configuration = [UIButtonConfiguration plainButtonConfiguration];
    coffee.configuration.title = @"Buy me a coffee";
    coffee.configuration.image = cup;
    coffee.configuration.imagePadding = 9.0;
    coffee.configuration.baseForegroundColor = UIColor.blackColor;
    coffee.configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 18, 0, 18);
    [coffee addTarget:self action:@selector(openCoffee) forControlEvents:UIControlEventTouchUpInside];

    [content addSubview:profile];
    [content addSubview:title];
    [content addSubview:handle];
    [content addSubview:coffee];

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18.0],
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24.0],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24.0],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16.0],

        [profile.topAnchor constraintEqualToAnchor:content.topAnchor],
        [profile.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [profile.widthAnchor constraintEqualToConstant:116.0],
        [profile.heightAnchor constraintEqualToConstant:116.0],

        [title.topAnchor constraintEqualToAnchor:profile.bottomAnchor constant:16.0],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [handle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],
        [handle.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [handle.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [coffee.topAnchor constraintEqualToAnchor:handle.bottomAnchor constant:22.0],
        [coffee.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [coffee.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [coffee.heightAnchor constraintEqualToConstant:56.0],
        [coffee.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
}

- (void)openCoffee {
    NSURL *url = [NSURL URLWithString:kFilzaSupportURLString];
    if (!url) return;

    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url];
    browser.preferredControlTintColor = UIColor.labelColor;
    [self presentViewController:browser animated:YES completion:nil];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static void FilzaSupportCollectText(UIView *view, NSMutableString *out) {
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) [out appendFormat:@" %@", text];
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateSelected), @(UIControlStateDisabled)]) {
            NSString *text = [button titleForState:state.unsignedIntegerValue];
            if (text.length) [out appendFormat:@" %@", text];
        }
        if (button.configuration.title.length) [out appendFormat:@" %@", button.configuration.title];
    } else if ([view isKindOfClass:UITextView.class]) {
        NSString *text = ((UITextView *)view).text;
        if (text.length) [out appendFormat:@" %@", text];
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        if (field.text.length) [out appendFormat:@" %@", field.text];
        if (field.placeholder.length) [out appendFormat:@" %@", field.placeholder];
    }

    for (UIView *child in view.subviews) FilzaSupportCollectText(child, out);
}

static BOOL FilzaSupportContains(NSString *haystack, NSString *needle) {
    return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *FilzaSupportAlertText(UIAlertController *alert) {
    NSMutableString *text = [NSMutableString string];
    if (alert.title.length) [text appendFormat:@" %@", alert.title];
    if (alert.message.length) [text appendFormat:@" %@", alert.message];
    for (UIAlertAction *action in alert.actions) {
        if (action.title.length) [text appendFormat:@" %@", action.title];
    }
    return text;
}

static BOOL FilzaSupportLooksLikeActivationNagAlert(UIAlertController *alert) {
    if (!alert) return NO;
    NSString *visible = FilzaSupportAlertText(alert);

    BOOL explicitlyFilza = FilzaSupportContains(visible, @"Filza");
    BOOL explicitlyNag = FilzaSupportContains(visible, @"Not activated") ||
        FilzaSupportContains(visible, @"remove this screen") ||
        FilzaSupportContains(visible, @"Will dismiss in") ||
        FilzaSupportContains(visible, @"Could not activate Filza");
    BOOL hasActivateAction = FilzaSupportContains(visible, @"Activate");

    return explicitlyFilza && (explicitlyNag || (hasActivateAction && FilzaSupportContains(visible, @"activated")));
}

static BOOL FilzaSupportLooksLikeActivationController(UIViewController *controller) {
    if (!controller || [controller isKindOfClass:FilzaSupportViewController.class]) return NO;
    if ([controller isKindOfClass:SFSafariViewController.class]) return NO;
    if ([controller isKindOfClass:UIAlertController.class]) return NO;

    [controller loadViewIfNeeded];

    NSMutableString *visible = [NSMutableString string];
    FilzaSupportCollectText(controller.view, visible);
    NSString *className = NSStringFromClass(controller.class) ?: @"";

    NSInteger score = 0;
    if (FilzaSupportContains(className, @"license") ||
        FilzaSupportContains(className, @"purchase") ||
        FilzaSupportContains(className, @"activat")) score += 4;

    if (FilzaSupportContains(visible, @"Activate Filza")) score += 5;
    if (FilzaSupportContains(visible, @"Not activated")) score += 3;
    if (FilzaSupportContains(visible, @"Purchase")) score += 2;
    if (FilzaSupportContains(visible, @"Device SN")) score += 2;
    if (FilzaSupportContains(visible, @"Could not activate Filza")) score += 4;
    if (FilzaSupportContains(visible, @"remove this screen")) score += 3;

    return score >= 4;
}

static UIViewController *FilzaSupportNavigationController(void) {
    FilzaSupportViewController *support = [FilzaSupportViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:support];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 16.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        UISheetPresentationControllerDetent *compact = [UISheetPresentationControllerDetent
            customDetentWithIdentifier:@"FilzaSupportCompact"
            resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                return MIN(430.0, context.maximumDetentValue);
            }];
        sheet.detents = @[compact];
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.preferredCornerRadius = 24.0;
        sheet.selectedDetentIdentifier = compact.identifier;
    } else if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.preferredCornerRadius = 24.0;
    }
    return navigation;
}

static char kFilzaSupportHandledKey;
static IMP gOriginalViewDidAppear = NULL;
static IMP gOriginalPresentViewController = NULL;

static void FilzaSupportPresentViewController(id self, SEL _cmd, UIViewController *controller, BOOL animated, void (^completion)(void)) {
    if ([controller isKindOfClass:UIAlertController.class] &&
        FilzaSupportLooksLikeActivationNagAlert((UIAlertController *)controller)) {
        NSLog(@"[FilzaSupport] Replacing legacy 'Not activated' nag alert with support sheet");
        UIViewController *support = FilzaSupportNavigationController();
        ((void(*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOriginalPresentViewController)(self, _cmd, support, animated, completion);
        return;
    }

    if (FilzaSupportLooksLikeActivationController(controller)) {
        NSLog(@"[FilzaSupport] Replacing legacy activation/payment controller with voluntary support sheet");
        UIViewController *support = FilzaSupportNavigationController();
        ((void(*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOriginalPresentViewController)(self, _cmd, support, animated, completion);
        return;
    }

    ((void(*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOriginalPresentViewController)(self, _cmd, controller, animated, completion);
}

static void FilzaSupportViewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void(*)(id, SEL, BOOL))gOriginalViewDidAppear)(self, _cmd, animated);

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller) return;

    if ([controller isKindOfClass:UIAlertController.class] &&
        FilzaSupportLooksLikeActivationNagAlert((UIAlertController *)controller)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = controller.presentingViewController;
            UIViewController *support = FilzaSupportNavigationController();
            NSLog(@"[FilzaSupport] Replacing already-visible 'Not activated' nag alert with support sheet");
            [controller dismissViewControllerAnimated:NO completion:^{
                if (presenter && !presenter.presentedViewController) {
                    [presenter presentViewController:support animated:YES completion:nil];
                }
            }];
        });
        return;
    }

    if (!FilzaSupportLooksLikeActivationController(controller)) return;
    if ([objc_getAssociatedObject(controller, &kFilzaSupportHandledKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kFilzaSupportHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *support = FilzaSupportNavigationController();
        UIViewController *presenter = controller.presentingViewController;

        if (presenter && !controller.presentedViewController) {
            [controller dismissViewControllerAnimated:NO completion:^{
                [presenter presentViewController:support animated:YES completion:nil];
            }];
            return;
        }

        if (!controller.presentedViewController) {
            [controller presentViewController:support animated:YES completion:nil];
        }
    });
}

__attribute__((constructor))
static void FilzaSupportPromptInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = UIViewController.class;

        Method appearMethod = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (appearMethod) {
            IMP current = method_getImplementation(appearMethod);
            if (current != (IMP)FilzaSupportViewDidAppear) {
                gOriginalViewDidAppear = current;
                method_setImplementation(appearMethod, (IMP)FilzaSupportViewDidAppear);
            }
        }

        Method presentMethod = class_getInstanceMethod(cls, @selector(presentViewController:animated:completion:));
        if (presentMethod) {
            IMP current = method_getImplementation(presentMethod);
            if (current != (IMP)FilzaSupportPresentViewController) {
                gOriginalPresentViewController = current;
                method_setImplementation(presentMethod, (IMP)FilzaSupportPresentViewController);
            }
        }

        NSLog(@"[FilzaSupport] Compact support UI installed -> %@", kFilzaSupportURLString);
    });
}
