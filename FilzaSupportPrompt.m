@import UIKit;
@import SafariServices;
#import <objc/runtime.h>

static NSString * const kFilzaSupportURLString = @"https://buymeacoffee.com/zyn3";
static NSString * const kFilzaSupportButtonImageURLString = @"https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png";

@interface FilzaSupportViewController : UIViewController
@property(nonatomic, strong) UIButton *coffeeButton;
@property(nonatomic, strong) UIActivityIndicatorView *imageSpinner;
@end

@implementation FilzaSupportViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"Support Filza 27";

    UIBarButtonItem *close = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self
        action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem = close;

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = NO;
    [self.view addSubview:scrollView];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stack];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 22.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [stack addArrangedSubview:card];

    UIStackView *cardStack = [UIStackView new];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.alignment = UIStackViewAlignmentCenter;
    cardStack.spacing = 12.0;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardStack];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cup.and.saucer.fill"]];
    icon.tintColor = UIColor.blackColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.backgroundColor = [UIColor colorWithRed:1.0 green:0.867 blue:0.0 alpha:1.0];
    icon.layer.cornerRadius = 28.0;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:56.0],
        [icon.heightAnchor constraintEqualToConstant:56.0]
    ]];

    UILabel *title = [UILabel new];
    title.text = @"Support Zyn";
    title.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *subtitle = [UILabel new];
    subtitle.text = @"If Filza 27 has been useful, you can support its continued development on Buy Me a Coffee.";
    subtitle.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;

    [cardStack addArrangedSubview:icon];
    [cardStack addArrangedSubview:title];
    [cardStack addArrangedSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:22.0],
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22.0]
    ]];

    self.coffeeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.coffeeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.coffeeButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.867 blue:0.0 alpha:1.0];
    self.coffeeButton.layer.cornerRadius = 14.0;
    self.coffeeButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.coffeeButton.clipsToBounds = YES;
    self.coffeeButton.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    [self.coffeeButton setTitle:@"Buy me a coffee" forState:UIControlStateNormal];
    [self.coffeeButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [self.coffeeButton addTarget:self action:@selector(openCoffee) forControlEvents:UIControlEventTouchUpInside];
    [self.coffeeButton.heightAnchor constraintEqualToConstant:66.0].active = YES;
    [stack addArrangedSubview:self.coffeeButton];

    self.imageSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.imageSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageSpinner.color = UIColor.blackColor;
    self.imageSpinner.hidesWhenStopped = YES;
    [self.coffeeButton addSubview:self.imageSpinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.imageSpinner.centerXAnchor constraintEqualToAnchor:self.coffeeButton.centerXAnchor],
        [self.imageSpinner.centerYAnchor constraintEqualToAnchor:self.coffeeButton.centerYAnchor]
    ]];
    [self.imageSpinner startAnimating];

    UIButton *openButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [openButton setTitle:@"Open buymeacoffee.com/zyn3" forState:UIControlStateNormal];
    [openButton setImage:[UIImage systemImageNamed:@"safari"] forState:UIControlStateNormal];
    openButton.configuration = [UIButtonConfiguration plainButtonConfiguration];
    openButton.configuration.imagePadding = 7.0;
    [openButton addTarget:self action:@selector(openCoffee) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:openButton];

    UILabel *disclaimer = [UILabel new];
    disclaimer.text = @"Support is optional. It does not unlock app features or change Filza access permissions.";
    disclaimer.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    disclaimer.textColor = UIColor.tertiaryLabelColor;
    disclaimer.textAlignment = NSTextAlignmentCenter;
    disclaimer.numberOfLines = 0;
    [stack addArrangedSubview:disclaimer];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:18.0],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-20.0],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-20.0]
    ]];

    [self loadOfficialButtonArtwork];
}

- (void)loadOfficialButtonArtwork {
    NSURL *url = [NSURL URLWithString:kFilzaSupportButtonImageURLString];
    if (!url) {
        [self.imageSpinner stopAnimating];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 12.0;

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        UIImage *image = (data.length && (!http || (http.statusCode >= 200 && http.statusCode < 300))) ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            [self.imageSpinner stopAnimating];
            if (!image) {
                NSLog(@"[FilzaSupport] Buy Me a Coffee artwork load failed: %@", error.localizedDescription ?: @"unknown error");
                return;
            }

            UIImage *original = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            [self.coffeeButton setTitle:nil forState:UIControlStateNormal];
            [self.coffeeButton setImage:original forState:UIControlStateNormal];
            self.coffeeButton.backgroundColor = UIColor.clearColor;
            self.coffeeButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
            self.coffeeButton.imageEdgeInsets = UIEdgeInsetsMake(3.0, 8.0, 3.0, 8.0);
            NSLog(@"[FilzaSupport] Buy Me a Coffee artwork loaded in original rendering mode");
        });
    }] resume];
}

- (void)openCoffee {
    NSURL *url = [NSURL URLWithString:kFilzaSupportURLString];
    if (!url) return;

    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url];
    browser.preferredControlTintColor = [UIColor colorWithRed:0.18 green:0.18 blue:0.18 alpha:1.0];
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

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.preferredCornerRadius = 24.0;
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
    }
    return navigation;
}

static char kFilzaSupportHandledKey;
static IMP gOriginalViewDidAppear = NULL;
static IMP gOriginalPresentViewController = NULL;

static void FilzaSupportPresentViewController(id self, SEL _cmd, UIViewController *controller, BOOL animated, void (^completion)(void)) {
    if ([controller isKindOfClass:UIAlertController.class] &&
        FilzaSupportLooksLikeActivationNagAlert((UIAlertController *)controller)) {
        NSLog(@"[FilzaSupport] Suppressed legacy 'Not activated' nag alert");
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
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
            NSLog(@"[FilzaSupport] Dismissing legacy 'Not activated' nag alert fallback");
            [controller dismissViewControllerAnimated:NO completion:nil];
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

        NSLog(@"[FilzaSupport] UI replacement installed -> %@", kFilzaSupportURLString);
    });
}
