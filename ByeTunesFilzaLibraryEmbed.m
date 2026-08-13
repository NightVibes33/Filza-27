@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static const void *kByeTunesFilzaLibraryHostKey = &kByeTunesFilzaLibraryHostKey;
static const void *kByeTunesFilzaLibraryEmbeddingKey = &kByeTunesFilzaLibraryEmbeddingKey;
static IMP gByeTunesOriginalMusicViewDidLoad = NULL;
static BOOL gByeTunesMusicHookInstalled = NO;

static UIViewController *ByeTunesMakeFilzaLibraryController(void)
{
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeLibraryViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        NSLog(@"[ByeTunesPort] embedded Swift host factory unavailable");
        return nil;
    }

    return ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
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
        NSLog(@"[ByeTunesPort] could not construct embedded ByeTunes library controller");
        return;
    }

    [legacy addChildViewController:host];
    host.view.frame = legacy.view.bounds;
    host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [legacy.view addSubview:host.view];
    [host didMoveToParentViewController:legacy];

    legacy.navigationItem.title = @"Music Library";
    legacy.navigationItem.titleView = nil;
    legacy.navigationItem.searchController = nil;
    legacy.navigationItem.rightBarButtonItem = nil;

    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryHostKey,
                             host,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryEmbeddingKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[ByeTunesPort] embedded complete ByeTunes ContentView inside TGMusicLibraryViewController");
}

static void ByeTunesMusicLibraryViewDidLoad(id self, SEL _cmd)
{
    if (gByeTunesOriginalMusicViewDidLoad)
        ((void (*)(id, SEL))gByeTunesOriginalMusicViewDidLoad)(self, _cmd);

    // Let Filza finish its own viewDidLoad before constructing the SwiftUI
    // hierarchy. This avoids re-entrant UIKit loading while the legacy music
    // controller is still being initialized.
    __weak UIViewController *weakLegacy = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *legacy = weakLegacy;
        if (legacy) ByeTunesEmbedInsideFilzaMusicLibrary(legacy);
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

    IMP inheritedOrOwned = method_getImplementation(resolvedMethod);
    const char *types = method_getTypeEncoding(resolvedMethod);

    // class_getInstanceMethod() also returns inherited methods. Mutating that
    // Method directly can replace UIViewController/Filza superclass behavior
    // process-wide. First try to add a class-local override. If the class
    // already owns viewDidLoad, class_addMethod returns NO and we safely replace
    // that class-owned implementation instead.
    if (class_addMethod(musicClass,
                        selector,
                        (IMP)ByeTunesMusicLibraryViewDidLoad,
                        types)) {
        gByeTunesOriginalMusicViewDidLoad = inheritedOrOwned;
        gByeTunesMusicHookInstalled = YES;
        NSLog(@"[ByeTunesPort] installed class-local Music Library viewDidLoad override");
        return;
    }

    Method ownedMethod = class_getInstanceMethod(musicClass, selector);
    if (!ownedMethod) return;
    IMP current = method_getImplementation(ownedMethod);
    if (current == (IMP)ByeTunesMusicLibraryViewDidLoad) {
        gByeTunesMusicHookInstalled = YES;
        return;
    }

    gByeTunesOriginalMusicViewDidLoad = current;
    method_setImplementation(ownedMethod, (IMP)ByeTunesMusicLibraryViewDidLoad);
    gByeTunesMusicHookInstalled = YES;
    NSLog(@"[ByeTunesPort] replaced TGMusicLibraryViewController-owned viewDidLoad");
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
