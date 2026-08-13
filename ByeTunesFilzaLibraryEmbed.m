@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"

static const void *kByeTunesFilzaLibraryHostKey = &kByeTunesFilzaLibraryHostKey;
static IMP gByeTunesSuperMusicViewDidLoad = NULL;
static IMP gByeTunesSuperMusicViewDidAppear = NULL;
static BOOL gByeTunesMusicHookInstalled = NO;

static void ByeTunesWriteStage(NSString *stage)
{
    FilzaDiagnosticsWriteByeTunesStage(stage ?: @"unknown");
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
            self.statusLabel.text = @"ByeTunes Swift host could not be created. See Files > FilzaSlop > FilzaSlop Logs.";
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
            self.statusLabel.text = @"ByeTunes failed while attaching its UI. See Files > FilzaSlop > FilzaSlop Logs.";
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

    // The original TGMusicLibraryViewController viewDidLoad is intentionally
    // skipped because it owns Filza's old Music Library implementation. Run the
    // superclass lifecycle only, then install the isolated ByeTunes launcher.
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

static void ByeTunesMusicLibraryViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    // This companion override is required whenever the subclass viewDidLoad is
    // bypassed. The original Filza viewDidAppear assumes its browser/model state
    // was created by TGMusicLibraryViewController's own viewDidLoad and can
    // dereference that uninitialized state otherwise.
    ByeTunesWriteStage(@"TGMusicLibraryViewController viewDidAppear intercepted");
    if (gByeTunesSuperMusicViewDidAppear)
        ((void (*)(id, SEL, BOOL))gByeTunesSuperMusicViewDidAppear)(self, _cmd, animated);
    ByeTunesInstallSafeLauncher((UIViewController *)self);
}

static BOOL ByeTunesOverrideLifecycleMethod(Class musicClass,
                                             SEL selector,
                                             IMP replacement,
                                             IMP *superImplementation)
{
    Method resolvedMethod = class_getInstanceMethod(musicClass, selector);
    if (!resolvedMethod) return NO;

    Class superClass = class_getSuperclass(musicClass);
    Method superMethod = superClass ? class_getInstanceMethod(superClass, selector) : NULL;
    if (superImplementation)
        *superImplementation = superMethod ? method_getImplementation(superMethod) : NULL;

    const char *types = method_getTypeEncoding(resolvedMethod);
    if (class_addMethod(musicClass, selector, replacement, types)) return YES;

    Method ownedMethod = class_getInstanceMethod(musicClass, selector);
    if (!ownedMethod) return NO;
    if (method_getImplementation(ownedMethod) != replacement)
        method_setImplementation(ownedMethod, replacement);
    return YES;
}

static void ByeTunesInstallFilzaMusicLibraryPort(void)
{
    if (gByeTunesMusicHookInstalled) return;

    Class musicClass = NSClassFromString(@"TGMusicLibraryViewController");
    if (!musicClass) {
        NSLog(@"[ByeTunesPort] TGMusicLibraryViewController not loaded yet");
        return;
    }

    BOOL loadHook = ByeTunesOverrideLifecycleMethod(musicClass,
        @selector(viewDidLoad),
        (IMP)ByeTunesMusicLibraryViewDidLoad,
        &gByeTunesSuperMusicViewDidLoad);
    BOOL appearHook = ByeTunesOverrideLifecycleMethod(musicClass,
        @selector(viewDidAppear:),
        (IMP)ByeTunesMusicLibraryViewDidAppear,
        &gByeTunesSuperMusicViewDidAppear);

    if (!loadHook || !appearHook) {
        NSLog(@"[ByeTunesPort] failed to install complete Music Library lifecycle isolation load=%d appear=%d",
              loadHook, appearHook);
        return;
    }

    gByeTunesMusicHookInstalled = YES;
    ByeTunesWriteStage(@"safe Music Library lifecycle hooks installed");
    NSLog(@"[ByeTunesPort] installed safe class-local Music Library lifecycle overrides");
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
