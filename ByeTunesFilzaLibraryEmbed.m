@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static const void *kByeTunesFilzaLibraryHostKey = &kByeTunesFilzaLibraryHostKey;
static IMP gByeTunesOriginalMusicViewDidLoad = NULL;

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

    UIViewController *host = ByeTunesMakeFilzaLibraryController();
    if (!host) {
        NSLog(@"[ByeTunesPort] could not construct embedded ByeTunes library controller");
        return;
    }

    [legacy addChildViewController:host];
    host.view.frame = legacy.view.bounds;
    host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [legacy.view addSubview:host.view];
    [host didMoveToParentViewController:legacy];

    // The Filza navigation controller remains the owner of navigation. ByeTunes
    // itself is now the contents of the existing Music Library destination,
    // rather than a second modal application launched on top of it.
    legacy.navigationItem.title = @"Music Library";
    legacy.navigationItem.titleView = nil;
    legacy.navigationItem.searchController = nil;
    legacy.navigationItem.rightBarButtonItem = nil;

    objc_setAssociatedObject(legacy,
                             kByeTunesFilzaLibraryHostKey,
                             host,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[ByeTunesPort] embedded complete ByeTunes ContentView inside TGMusicLibraryViewController");
}

static void ByeTunesMusicLibraryViewDidLoad(id self, SEL _cmd)
{
    if (gByeTunesOriginalMusicViewDidLoad)
        ((void (*)(id, SEL))gByeTunesOriginalMusicViewDidLoad)(self, _cmd);

    ByeTunesEmbedInsideFilzaMusicLibrary((UIViewController *)self);
}

static void ByeTunesInstallFilzaMusicLibraryPort(void)
{
    Class musicClass = NSClassFromString(@"TGMusicLibraryViewController");
    if (!musicClass) {
        NSLog(@"[ByeTunesPort] TGMusicLibraryViewController not loaded yet");
        return;
    }

    SEL selector = @selector(viewDidLoad);
    Method method = class_getInstanceMethod(musicClass, selector);
    if (!method) {
        NSLog(@"[ByeTunesPort] TGMusicLibraryViewController has no viewDidLoad method");
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)ByeTunesMusicLibraryViewDidLoad) return;

    gByeTunesOriginalMusicViewDidLoad = current;
    method_setImplementation(method, (IMP)ByeTunesMusicLibraryViewDidLoad);
    NSLog(@"[ByeTunesPort] Filza Music Library now routes in-place to ByeTunes");
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

        // A delayed retry covers Filza builds that lazily load the library class.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            ByeTunesInstallFilzaMusicLibraryPort();
        });
    });
}
