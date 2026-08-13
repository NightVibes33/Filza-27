@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static const void *kByeTunesFilzaLibraryHostKey = &kByeTunesFilzaLibraryHostKey;
static IMP gByeTunesSuperMusicViewDidLoad = NULL;
static BOOL gByeTunesMusicHookInstalled = NO;

static NSString *ByeTunesCrashStagePath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask,
                                                               YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"ByeTunesEmbedStage.txt"];
}

static void ByeTunesWriteStage(NSString *stage)
{
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n",
                      NSDate.date.description,
                      stage ?: @"unknown"];
    [line writeToFile:ByeTunesCrashStagePath()
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    NSLog(@"[ByeTunesPort][stage] %@", stage);
}

static UIViewController *ByeTunesMakeSwiftController(void)
{
    ByeTunesWriteStage(@"before Swift host factory");
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeLibraryViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        ByeTunesWriteStage(@"Swift host factory unavailable");
        return nil;
    }

    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        ByeTunesWriteStage(controller ? @"Swift factory returned controller"
                                        : @"Swift factory returned nil");
        return controller;
    } @catch (NSException *exception) {
        ByeTunesWriteStage([NSString stringWithFormat:@"Objective-C exception in Swift factory: %@",
                            exception.reason ?: exception.name]);
        return nil;
    }
}

@interface ByeTunesSafeLaunchController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *loadButton;
@property(nonatomic, assign) BOOL loading;
@end

@implementation ByeTunesSafeLaunchController

- (void)viewDidLoad
{
    [super viewDidLoad];
    ByeTunesWriteStage(@"inert UIKit launcher visible");

    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"ByeTunes";

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"ByeTunes";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"Startup isolation active. Tap Load ByeTunes to enter the Swift UI.";
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    status.textColor = UIColor.secondaryLabelColor;
    status.numberOfLines = 0;
    status.textAlignment = NSTextAlignmentCenter;
    self.statusLabel = status;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Load ByeTunes" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [button addTarget:self action:@selector(loadByeTunes:) forControlEvents:UIControlEventTouchUpInside];
    self.loadButton = button;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, status, button]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 18.0;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:48.0],
    ]];
}

- (void)loadByeTunes:(__unused id)sender
{
    if (self.loading || objc_getAssociatedObject(self, kByeTunesFilzaLibraryHostKey)) return;
    self.loading = YES;
    self.loadButton.enabled = NO;
    self.statusLabel.text = @"Loading ByeTunes…";
    ByeTunesWriteStage(@"user requested Swift UI");

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = ByeTunesMakeSwiftController();
        if (!host) {
            self.statusLabel.text = @"ByeTunes Swift host could not be created. See ByeTunesEmbedStage.txt.";
            self.loadButton.enabled = YES;
            self.loading = NO;
            return;
        }

        @try {
            [self addChildViewController:host];
            ByeTunesWriteStage(@"before Swift host view materialization");
            UIView *hostView = host.view;
            ByeTunesWriteStage(@"Swift host view materialized");
            hostView.frame = self.view.bounds;
            hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.view addSubview:hostView];
            [host didMoveToParentViewController:self];
            objc_setAssociatedObject(self,
                                     kByeTunesFilzaLibraryHostKey,
                                     host,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ByeTunesWriteStage(@"Swift host attached successfully");
            self.loading = NO;
        } @catch (NSException *exception) {
            ByeTunesWriteStage([NSString stringWithFormat:@"UIKit attach exception: %@",
                                exception.reason ?: exception.name]);
            [host willMoveToParentViewController:nil];
            [host.view removeFromSuperview];
            [host removeFromParentViewController];
            self.statusLabel.text = @"ByeTunes failed while attaching its UI. See ByeTunesEmbedStage.txt.";
            self.loadButton.enabled = YES;
            self.loading = NO;
        }
    });
}

@end

static void ByeTunesInstallSafeLauncher(UIViewController *legacy)
{
    if (!legacy || objc_getAssociatedObject(legacy, kByeTunesFilzaLibraryHostKey)) return;

    ByeTunesSafeLaunchController *launcher = [ByeTunesSafeLaunchController new];
    [legacy addChildViewController:launcher];
    launcher.view.frame = legacy.view.bounds;
    launcher.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [legacy.view addSubview:launcher.view];
    [launcher didMoveToParentViewController:legacy];
    legacy.navigationItem.title = @"ByeTunes";
    legacy.navigationItem.titleView = nil;
    legacy.navigationItem.searchController = nil;
    legacy.navigationItem.rightBarButtonItem = nil;
    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryHostKey,
                             launcher,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ByeTunesWriteStage(@"safe launcher attached to Filza Music Library");
}

static void ByeTunesMusicLibraryViewDidLoad(id self, SEL _cmd)
{
    ByeTunesWriteStage(@"TGMusicLibraryViewController viewDidLoad intercepted");

    // Do not invoke Filza's TGMusicLibraryViewController implementation. Only
    // run the superclass implementation, then install a plain UIKit launcher.
    // Crucially, ContentView() and DeviceManager.shared are not constructed
    // merely by opening Filza's Music Library anymore.
    if (gByeTunesSuperMusicViewDidLoad)
        ((void (*)(id, SEL))gByeTunesSuperMusicViewDidLoad)(self, _cmd);

    UIViewController *legacy = (UIViewController *)self;
    if (!legacy.view)
        legacy.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    legacy.view.backgroundColor = UIColor.systemBackgroundColor;

    dispatch_async(dispatch_get_main_queue(), ^{
        ByeTunesInstallSafeLauncher(legacy);
    });
}

static void ByeTunesInstallFilzaMusicLibraryPort(void)
{
    if (gByeTunesMusicHookInstalled) return;

    Class musicClass = NSClassFromString(@"TGMusicLibraryViewController");
    if (!musicClass) {
        NSLog(@"[ByeTunesPort] TGMusicLibraryViewController not loaded yet");
        return;
    }

    SEL selector = @selector(viewDidLoad);
    Method resolvedMethod = class_getInstanceMethod(musicClass, selector);
    if (!resolvedMethod) {
        NSLog(@"[ByeTunesPort] TGMusicLibraryViewController has no viewDidLoad method");
        return;
    }

    Class superClass = class_getSuperclass(musicClass);
    Method superMethod = superClass ? class_getInstanceMethod(superClass, selector) : NULL;
    gByeTunesSuperMusicViewDidLoad = superMethod ? method_getImplementation(superMethod) : NULL;
    const char *types = method_getTypeEncoding(resolvedMethod);

    // Install only on TGMusicLibraryViewController. The previous global
    // UINavigationController pushViewController swizzle is intentionally gone:
    // it affected every navigation transition in Filza and created a second
    // independent crash surface before ByeTunes even existed.
    if (class_addMethod(musicClass,
                        selector,
                        (IMP)ByeTunesMusicLibraryViewDidLoad,
                        types)) {
        gByeTunesMusicHookInstalled = YES;
        NSLog(@"[ByeTunesPort] installed safe class-local Music Library override");
        return;
    }

    Method ownedMethod = class_getInstanceMethod(musicClass, selector);
    if (!ownedMethod) return;
    IMP current = method_getImplementation(ownedMethod);
    if (current != (IMP)ByeTunesMusicLibraryViewDidLoad)
        method_setImplementation(ownedMethod, (IMP)ByeTunesMusicLibraryViewDidLoad);
    gByeTunesMusicHookInstalled = YES;
    NSLog(@"[ByeTunesPort] installed safe class-local Music Library override");
}

__attribute__((constructor)) static void ByeTunesFilzaLibraryPortInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ByeTunesInstallFilzaMusicLibraryPort();

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                ByeTunesInstallFilzaMusicLibraryPort();
            }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            ByeTunesInstallFilzaMusicLibraryPort();
        });
    });
}
