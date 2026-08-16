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
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 18.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stack];

    UIView *heroCard = [UIView new];
    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    heroCard.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    heroCard.layer.cornerRadius = 22.0;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;

    UIStackView *heroStack = [[UIStackView alloc] init];
    heroStack.axis = UILayoutConstraintAxisVertical;
    heroStack.alignment = UIStackViewAlignmentCenter;
    heroStack.spacing = 12.0;
    heroStack.translatesAutoresizingMaskIntoConstraints = NO;
    [heroCard addSubview:heroStack];

    UIImageView *cup = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cup.and.saucer.fill"]];
    cup.tintColor = UIColor.blackColor;
    cup.contentMode = UIViewContentModeScaleAspectFit;
    cup.backgroundColor = [UIColor colorWithRed:1.0 green:0.867 blue:0.0 alpha:1.0];
    cup.layer.cornerRadius = 34.0;
    cup.layer.cornerCurve = kCACornerCurveContinuous;
    cup.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [cup.widthAnchor constraintEqualToConstant:68.0],
        [cup.heightAnchor constraintEqualToConstant:68.0]
    ]];

    UILabel *title = [UILabel new];
    title.text = @"Support Zyn";
    title.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *subtitle = [UILabel new];
    subtitle.text = @"If Filza 27 has been useful to you, you can support its continued development on Buy Me a Coffee.";
    subtitle.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;

    [heroStack addArrangedSubview:cup];
    [heroStack addArrangedSubview:title];
    [heroStack addArrangedSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [heroStack.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:26.0],
        [heroStack.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:22.0],
        [heroStack.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-22.0],
        [heroStack.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-26.0]
    ]];

    [stack addArrangedSubview:heroCard];

    UILabel *supportLabel = [UILabel new];
    supportLabel.text = @"BUY ME A COFFEE";
    supportLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    supportLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:supportLabel];

    self.coffeeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.coffeeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.coffeeButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.867 blue:0.0 alpha:1.0];
    self.coffeeButton.layer.cornerRadius = 16.0;
    self.coffeeButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.coffeeButton.clipsToBounds = YES;
    self.coffeeButton.tintColor = UIColor.blackColor;
    self.coffeeButton.titleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    [self.coffeeButton setTitle:@"☕  Buy me a coffee" forState:UIControlStateNormal];
    [self.coffeeButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [self.coffeeButton addTarget:self action:@selector(openCoffee) forControlEvents:UIControlEventTouchUpInside];
    [self.coffeeButton.heightAnchor constraintEqualToConstant:84.0].active = YES;
    [stack addArrangedSubview:self.coffeeButton];

    self.imageSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.imageSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageSpinner.color = UIColor.blackColor;
    [self.coffeeButton addSubview:self.imageSpinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.imageSpinner.centerXAnchor constraintEqualToAnchor:self.coffeeButton.centerXAnchor],
        [self.imageSpinner.centerYAnchor constraintEqualToAnchor:self.coffeeButton.centerYAnchor]
    ]];
    [self.imageSpinner startAnimating];

    UILabel *urlLabel = [UILabel new];
    urlLabel.text = @"buymeacoffee.com/zyn3";
    urlLabel.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    urlLabel.textColor = UIColor.secondaryLabelColor;
    urlLabel.textAlignment = NSTextAlignmentCenter;
    urlLabel.numberOfLines = 1;
    [stack addArrangedSubview:urlLabel];

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:@"Copy support link" forState:UIControlStateNormal];
    [copyButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    copyButton.configuration = [UIButtonConfiguration tintedButtonConfiguration];
    copyButton.configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    copyButton.configuration.imagePadding = 8.0;
    [copyButton addTarget:self action:@selector(copyLink) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:copyButton];

    UILabel *disclaimer = [UILabel new];
    disclaimer.text = @"Support is optional. It does not unlock app features or change Filza access permissions.";
    disclaimer.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    disclaimer.textColor = UIColor.tertiaryLabelColor;
    disclaimer.textAlignment = NSTextAlignmentCenter;
    disclaimer.numberOfLines = 0;
    [stack addArrangedSubview:disclaimer];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:24.0],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:22.0],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-22.0],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-28.0]
    ]];

    [self loadOfficialButtonArtwork];
}

- (void)loadOfficialButtonArtwork {
    NSURL *url = [NSURL URLWithString:kFilzaSupportButtonImageURLString];
    if (!url) {
        [self.imageSpinner stopAnimating];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.imageSpinner stopAnimating];
            if (!image) return;

            [self.coffeeButton setTitle:nil forState:UIControlStateNormal];
            [self.coffeeButton setImage:image forState:UIControlStateNormal];
            self.coffeeButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
            self.coffeeButton.imageEdgeInsets = UIEdgeInsetsMake(12.0, 18.0, 12.0, 18.0);
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

- (void)copyLink {
    UIPasteboard.generalPasteboard.string = kFilzaSupportURLString;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Copied"
        message:@"Buy Me a Coffee link copied to the clipboard."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
            NSString *title = [button titleForState:state.unsignedIntegerValue];
            if (title.length) [out appendFormat:@" %@", title];
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

static BOOL FilzaSupportLooksLikeActivationController(UIViewController *controller) {
    if (!controller || [controller isKindOfClass:FilzaSupportViewController.class]) return NO;
    if ([controller isKindOfClass:SFSafariViewController.class]) return NO;

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

static char kFilzaSupportHandledKey;
static IMP gOriginalViewDidAppear = NULL;

static UIViewController *FilzaSupportNavigationController(void) {
    FilzaSupportViewController *support = [FilzaSupportViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:support];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 24.0;
    }
    return navigation;
}

static void FilzaSupportViewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void(*)(id, SEL, BOOL))gOriginalViewDidAppear)(self, _cmd, animated);

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller || !FilzaSupportLooksLikeActivationController(controller)) return;
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
        Method method = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (!method) return;

        IMP current = method_getImplementation(method);
        if (current == (IMP)FilzaSupportViewDidAppear) return;

        gOriginalViewDidAppear = current;
        method_setImplementation(method, (IMP)FilzaSupportViewDidAppear);
        NSLog(@"[FilzaSupport] Buy Me a Coffee replacement installed -> %@", kFilzaSupportURLString);
    });
}
