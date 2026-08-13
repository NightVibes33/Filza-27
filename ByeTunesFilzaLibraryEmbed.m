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
    ByeTunesWriteStage(@"before complete ByeTunes host factory");
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeLibraryViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        ByeTunesWriteStage(@"complete ByeTunes host factory unavailable");
        return nil;
    }

    @try {
        UIViewController *controller =
            ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
        ByeTunesWriteStage(controller ? @"complete ByeTunes factory returned controller"
                                      : @"complete ByeTunes factory returned nil");
        return controller;
    } @catch (NSException *exception) {
        ByeTunesWriteStage([NSString stringWithFormat:
            @"Objective-C exception in complete ByeTunes factory: %@",
            exception.reason ?: exception.name]);
        return nil;
    }
}

static void ByeTunesShowFailure(UIViewController *legacy, NSString *message)
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    [legacy.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:legacy.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintEqualToAnchor:legacy.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        [label.centerYAnchor constraintEqualToAnchor:legacy.view.safeAreaLayoutGuide.centerYAnchor],
    ]];
}

static void ByeTunesStartEmbeddedContent(UIViewController *host)
{
    SEL start = NSSelectorFromString(@"startEmbeddedContentIfNeeded");
    if ([host respondsToSelector:start]) {
        ((void (*)(id, SEL))objc_msgSend)(host, start);
        ByeTunesWriteStage(@"requested complete ByeTunes ContentView startup");
    }
}

static void ByeTunesAttachCompleteHost(UIViewController *legacy)
{
    if (!legacy || objc_getAssociatedObject(legacy, kByeTunesFilzaLibraryHostKey)) return;

    UIViewController *host = ByeTunesMakeSwiftController();
    if (!host) {
        ByeTunesShowFailure(legacy,
            @"Music Library could not be created. See Files > FilzaSlop > FilzaSlop Logs.");
        return;
    }

    @try {
        [legacy addChildViewController:host];
        ByeTunesWriteStage(@"before complete ByeTunes host view materialization");
        UIView *hostView = host.view;
        ByeTunesWriteStage(@"complete ByeTunes host view materialized");
        hostView.frame = legacy.view.bounds;
        hostView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [legacy.view addSubview:hostView];
        [host didMoveToParentViewController:legacy];
        objc_setAssociatedObject(legacy,
                                 kByeTunesFilzaLibraryHostKey,
                                 host,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        legacy.navigationItem.title = @"Music Library";
        legacy.navigationItem.titleView = nil;
        legacy.navigationItem.searchController = nil;
        legacy.navigationItem.rightBarButtonItem = nil;
        ByeTunesWriteStage(@"complete ByeTunes host attached directly to Music Library");

        dispatch_async(dispatch_get_main_queue(), ^{
            ByeTunesStartEmbeddedContent(host);
        });
    } @catch (NSException *exception) {
        ByeTunesWriteStage([NSString stringWithFormat:
            @"UIKit exception attaching complete ByeTunes host: %@",
            exception.reason ?: exception.name]);
        [host willMoveToParentViewController:nil];
        [host.view removeFromSuperview];
        [host removeFromParentViewController];
        ByeTunesShowFailure(legacy,
            @"Music Library failed while attaching. See Files > FilzaSlop > FilzaSlop Logs.");
    }
}

static void ByeTunesMusicLibraryViewDidLoad(id self, SEL _cmd)
{
    ByeTunesWriteStage(@"TGMusicLibraryViewController viewDidLoad intercepted");

    // Filza's legacy Music Library assumes state that is unavailable in this
    // jailed build. Run the superclass lifecycle and replace its contents with
    // the complete embedded ByeTunes application.
    if (gByeTunesSuperMusicViewDidLoad)
        ((void (*)(id, SEL))gByeTunesSuperMusicViewDidLoad)(self, _cmd);

    UIViewController *legacy = (UIViewController *)self;
    if (!legacy.view)
        legacy.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    legacy.view.backgroundColor = UIColor.systemBackgroundColor;

    dispatch_async(dispatch_get_main_queue(), ^{
        ByeTunesAttachCompleteHost(legacy);
    });
}

static void ByeTunesMusicLibraryViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    ByeTunesWriteStage(@"TGMusicLibraryViewController viewDidAppear intercepted");
    if (gByeTunesSuperMusicViewDidAppear)
        ((void (*)(id, SEL, BOOL))gByeTunesSuperMusicViewDidAppear)(self, _cmd, animated);

    UIViewController *legacy = (UIViewController *)self;
    ByeTunesAttachCompleteHost(legacy);
    UIViewController *host =
        objc_getAssociatedObject(legacy, kByeTunesFilzaLibraryHostKey);
    ByeTunesStartEmbeddedContent(host);
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

    BOOL loadHook = ByeTunesOverrideLifecycleMethod(
        musicClass, @selector(viewDidLoad),
        (IMP)ByeTunesMusicLibraryViewDidLoad, &gByeTunesSuperMusicViewDidLoad);
    BOOL appearHook = ByeTunesOverrideLifecycleMethod(
        musicClass, @selector(viewDidAppear:),
        (IMP)ByeTunesMusicLibraryViewDidAppear, &gByeTunesSuperMusicViewDidAppear);

    if (!loadHook || !appearHook) {
        NSLog(@"[ByeTunesPort] failed to install complete Music Library lifecycle route load=%d appear=%d",
              loadHook, appearHook);
        return;
    }

    gByeTunesMusicHookInstalled = YES;
    ByeTunesWriteStage(@"complete ByeTunes Music Library lifecycle hooks installed");
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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            ByeTunesInstallFilzaMusicLibraryPort();
        });
    });
}
