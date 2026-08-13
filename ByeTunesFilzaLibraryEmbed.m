@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static const void *kByeTunesFilzaLibraryHostKey = &kByeTunesFilzaLibraryHostKey;
static const void *kByeTunesFilzaLibraryEmbeddingKey = &kByeTunesFilzaLibraryEmbeddingKey;
static IMP gByeTunesSuperMusicViewDidLoad = NULL;
static BOOL gByeTunesMusicHookInstalled = NO;

static UIViewController *ByeTunesMakeFilzaLibraryController(void)
{
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeLibraryViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        NSLog(@"[ByeTunesPort] embedded Swift host factory unavailable");
        return nil;
    }

    @try {
        return ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
    } @catch (NSException *exception) {
        NSLog(@"[ByeTunesPort] host factory raised %@: %@",
              exception.name, exception.reason ?: @"no reason");
        return nil;
    }
}

static void ByeTunesInstallFailureView(UIViewController *legacy, NSString *message)
{
    if (!legacy) return;

    legacy.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.text = message.length ? message : @"ByeTunes could not be loaded.";
    [legacy.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:legacy.view.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:legacy.view.trailingAnchor constant:-24.0],
        [label.centerXAnchor constraintEqualToAnchor:legacy.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:legacy.view.centerYAnchor],
    ]];
}

static void ByeTunesEmbedInsideFilzaMusicLibrary(UIViewController *legacy)
{
    if (!legacy || objc_getAssociatedObject(legacy, kByeTunesFilzaLibraryHostKey)) return;

    if ([objc_getAssociatedObject(legacy, kByeTunesFilzaLibraryEmbeddingKey) boolValue]) {
        NSLog(@"[ByeTunesPort] blocked recursive Music Library embedding");
        return;
    }
    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryEmbeddingKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *host = ByeTunesMakeFilzaLibraryController();
    if (!host) {
        objc_setAssociatedObject(legacy,
                                 kByeTunesFilzaLibraryEmbeddingKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ByeTunesInstallFailureView(legacy,
            @"ByeTunes host creation failed. The legacy Filza music controller was intentionally not started.");
        NSLog(@"[ByeTunesPort] could not construct embedded ByeTunes library controller");
        return;
    }

    @try {
        [legacy addChildViewController:host];
        host.view.frame = legacy.view.bounds;
        host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [legacy.view addSubview:host.view];
        [host didMoveToParentViewController:legacy];

        legacy.navigationItem.title = @"ByeTunes";
        legacy.navigationItem.titleView = nil;
        legacy.navigationItem.searchController = nil;
        legacy.navigationItem.rightBarButtonItem = nil;

        objc_setAssociatedObject(legacy,
                                 kByeTunesFilzaLibraryHostKey,
                                 host,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[ByeTunesPort] embedded complete ByeTunes ContentView inside TGMusicLibraryViewController");
    } @catch (NSException *exception) {
        NSLog(@"[ByeTunesPort] UIKit embed raised %@: %@",
              exception.name, exception.reason ?: @"no reason");
        [host willMoveToParentViewController:nil];
        [host.view removeFromSuperview];
        [host removeFromParentViewController];
        ByeTunesInstallFailureView(legacy,
            [NSString stringWithFormat:@"ByeTunes embed failed: %@", exception.reason ?: exception.name]);
    }

    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryEmbeddingKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ByeTunesMusicLibraryViewDidLoad(id self, SEL _cmd)
{
    // Do NOT invoke TGMusicLibraryViewController's original implementation.
    // On the jailed iOS 27 build that legacy Filza music path can terminate the
    // process before our SwiftUI host is ever constructed. We replace the
    // screen, so only the superclass lifecycle is required.
    if (gByeTunesSuperMusicViewDidLoad)
        ((void (*)(id, SEL))gByeTunesSuperMusicViewDidLoad)(self, _cmd);

    UIViewController *legacy = (UIViewController *)self;
    if (!legacy.view) {
        legacy.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    legacy.view.backgroundColor = UIColor.systemBackgroundColor;

    __weak UIViewController *weakLegacy = legacy;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongLegacy = weakLegacy;
        if (strongLegacy) ByeTunesEmbedInsideFilzaMusicLibrary(strongLegacy);
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

    // class_getInstanceMethod() can return inherited methods. Add a local
    // override first so this replacement never mutates a superclass method.
    if (class_addMethod(musicClass,
                        selector,
                        (IMP)ByeTunesMusicLibraryViewDidLoad,
                        types)) {
        gByeTunesMusicHookInstalled = YES;
        NSLog(@"[ByeTunesPort] installed isolated Music Library replacement; legacy implementation bypassed");
        return;
    }

    Method ownedMethod = class_getInstanceMethod(musicClass, selector);
    if (!ownedMethod) return;
    IMP current = method_getImplementation(ownedMethod);
    if (current == (IMP)ByeTunesMusicLibraryViewDidLoad) {
        gByeTunesMusicHookInstalled = YES;
        return;
    }

    method_setImplementation(ownedMethod, (IMP)ByeTunesMusicLibraryViewDidLoad);
    gByeTunesMusicHookInstalled = YES;
    NSLog(@"[ByeTunesPort] replaced TGMusicLibraryViewController viewDidLoad without invoking legacy implementation");
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
