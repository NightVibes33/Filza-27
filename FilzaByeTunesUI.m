@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "ByeTunesMusicBridge.h"
#import "FilzaByeTunesUI.h"

typedef NS_ENUM(NSInteger, FBTLibraryMode) {
    FBTLibraryModeSongs = 0,
    FBTLibraryModeAlbums = 1,
    FBTLibraryModeArtists = 2,
};

static NSString *FBTString(NSDictionary *song, NSString *key)
{
    id value = song[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *FBTTitle(NSDictionary *song)
{
    NSString *title = FBTString(song, @"Title");
    return title.length ? title : @"Unknown Title";
}

static NSString *FBTArtist(NSDictionary *song)
{
    NSString *artist = FBTString(song, @"Artist");
    return artist.length ? artist : @"Unknown Artist";
}

static NSString *FBTAlbum(NSDictionary *song)
{
    NSString *album = FBTString(song, @"Album");
    return album.length ? album : @"Unknown Album";
}

static NSString *FBTDurationString(NSDictionary *song)
{
    NSTimeInterval seconds = [song[@"DurationMS"] doubleValue] / 1000.0;
    if (seconds <= 0) return @"";
    NSInteger whole = (NSInteger)llround(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(whole / 60), (long)(whole % 60)];
}

static UIViewController *FBTTopController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window) break;
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

@interface FilzaByeTunesMusicController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithSongs:(NSArray<NSDictionary *> *)songs title:(NSString *)title;
@end

@interface FilzaByeTunesMusicController ()
@property(nonatomic, copy) NSArray<NSDictionary *> *allSongs;
@property(nonatomic, copy) NSArray *displayRows;
@property(nonatomic, strong) UISegmentedControl *modeControl;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic) FBTLibraryMode mode;
@property(nonatomic) BOOL fixedSongList;
@end

@implementation FilzaByeTunesMusicController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _allSongs = @[];
        _displayRows = @[];
        _mode = FBTLibraryModeSongs;
        _fixedSongList = NO;
    }
    return self;
}

- (instancetype)initWithSongs:(NSArray<NSDictionary *> *)songs title:(NSString *)title
{
    if ((self = [self init])) {
        _allSongs = [songs copy] ?: @[];
        _displayRows = _allSongs;
        _fixedSongList = YES;
        self.title = title.length ? title : @"Songs";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 58.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (!self.title.length) self.title = @"Music Library";

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Search Music";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    if (!self.fixedSongList) {
        self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Songs", @"Albums", @"Artists"]];
        self.modeControl.selectedSegmentIndex = self.mode;
        [self.modeControl addTarget:self action:@selector(modeChanged:)
                   forControlEvents:UIControlEventValueChanged];
        self.navigationItem.titleView = self.modeControl;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
            target:self action:@selector(refreshLibrary)];
    }

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    if (self.fixedSongList) {
        [self rebuildRows];
    } else {
        [self refreshLibrary];
    }
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    self.mode = (FBTLibraryMode)sender.selectedSegmentIndex;
    [self rebuildRows];
}

- (void)refreshLibrary
{
    [self.spinner startAnimating];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.statusLabel.text = @"Connecting to the on-device music library…";
    self.tableView.backgroundView = self.statusLabel;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        NSArray<NSDictionary *> *songs = BTMusicLoadLibrary(&detail);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self.spinner stopAnimating];
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (!songs) {
                self.allSongs = @[];
                self.displayRows = @[];
                self.statusLabel.text = detail.length ? detail :
                    @"Unable to read the device music library.";
                self.tableView.backgroundView = self.statusLabel;
                [self.tableView reloadData];
                return;
            }
            self.allSongs = songs;
            self.tableView.backgroundView = nil;
            [self rebuildRows];
            if (songs.count == 0) {
                self.statusLabel.text = @"No AFC-backed songs were found in MediaLibrary.sqlitedb.";
                self.tableView.backgroundView = self.statusLabel;
            }
        });
    });
}

- (NSArray<NSDictionary *> *)filteredSongs
{
    NSString *needle = [self.searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!needle.length) return self.allSongs;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *song, NSDictionary *bindings) {
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
            FBTTitle(song), FBTArtist(song), FBTAlbum(song), FBTString(song, @"Genre")];
        return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
    }];
    return [self.allSongs filteredArrayUsingPredicate:predicate];
}

- (void)rebuildRows
{
    NSArray<NSDictionary *> *songs = [self filteredSongs];
    if (self.fixedSongList || self.mode == FBTLibraryModeSongs) {
        self.displayRows = [songs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [FBTTitle(a) localizedCaseInsensitiveCompare:FBTTitle(b)];
        }];
        [self.tableView reloadData];
        return;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *subtitles = [NSMutableDictionary dictionary];
    for (NSDictionary *song in songs) {
        NSString *key = self.mode == FBTLibraryModeArtists ? FBTArtist(song) : FBTAlbum(song);
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:song];
        if (self.mode == FBTLibraryModeAlbums && !subtitles[key]) subtitles[key] = FBTArtist(song);
    }

    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:groups.count];
    for (NSString *key in groups) {
        NSArray *members = [groups[key] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [FBTTitle(a) localizedCaseInsensitiveCompare:FBTTitle(b)];
        }];
        NSString *detail = self.mode == FBTLibraryModeAlbums
            ? (subtitles[key] ?: @"")
            : [NSString stringWithFormat:@"%lu song%@", (unsigned long)members.count,
               members.count == 1 ? @"" : @"s"];
        [rows addObject:@{@"GroupName": key, @"GroupDetail": detail, @"Songs": members}];
    }
    self.displayRows = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"GroupName"] localizedCaseInsensitiveCompare:b[@"GroupName"]];
    }];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self rebuildRows];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.displayRows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.fixedSongList) return nil;
    if (self.mode == FBTLibraryModeSongs)
        return [NSString stringWithFormat:@"%lu songs · ByeTunes AFC library", (unsigned long)self.allSongs.count];
    return @"On-device library via ByeTunes-compatible AFC transport";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *reuse = @"FBTCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = UIColor.secondaryLabelColor;

    NSDictionary *row = self.displayRows[(NSUInteger)indexPath.row];
    NSArray *members = row[@"Songs"];
    if ([members isKindOfClass:NSArray.class]) {
        cell.textLabel.text = row[@"GroupName"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%lu track%@",
            row[@"GroupDetail"] ?: @"", [row[@"GroupDetail"] length] ? @" · " : @"",
            (unsigned long)members.count, members.count == 1 ? @"" : @"s"];
        cell.imageView.image = [UIImage systemImageNamed:self.mode == FBTLibraryModeArtists
            ? @"person.crop.circle" : @"square.stack"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSDictionary *song = row;
        cell.textLabel.text = FBTTitle(song);
        NSString *duration = FBTDurationString(song);
        NSString *metadata = [NSString stringWithFormat:@"%@ · %@", FBTArtist(song), FBTAlbum(song)];
        if (duration.length) metadata = [metadata stringByAppendingFormat:@" · %@", duration];
        cell.detailTextLabel.text = metadata;
        cell.imageView.image = [UIImage systemImageNamed:@"music.note"];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.displayRows[(NSUInteger)indexPath.row];
    NSArray *members = row[@"Songs"];
    if ([members isKindOfClass:NSArray.class]) {
        FilzaByeTunesMusicController *child = [[FilzaByeTunesMusicController alloc]
            initWithSongs:members title:row[@"GroupName"]];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }

    NSDictionary *song = row;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    cell.accessoryView = indicator;
    cell.userInteractionEnabled = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        NSString *localPath = BTMusicEnsureLocalFile(song, &detail);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            cell.accessoryView = nil;
            cell.userInteractionEnabled = YES;
            if (!localPath.length) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Music Library"
                    message:detail.length ? detail : @"Unable to fetch this track through AFC."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            NSURL *URL = [NSURL fileURLWithPath:localPath];
            UIActivityViewController *activity = [[UIActivityViewController alloc]
                initWithActivityItems:@[URL] applicationActivities:nil];
            if (activity.popoverPresentationController) {
                activity.popoverPresentationController.sourceView = cell;
                activity.popoverPresentationController.sourceRect = cell.bounds;
            }
            [self presentViewController:activity animated:YES completion:nil];
        });
    });
}

@end

static const void *kFBTEmbeddedControllerKey = &kFBTEmbeddedControllerKey;
static IMP gLegacyMusicViewDidLoad = NULL;

static BOOL FBTUseReplacementMusicLibrary(void)
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
}

static void FBTEmbedReplacementController(UIViewController *legacy)
{
    if (!legacy || objc_getAssociatedObject(legacy, kFBTEmbeddedControllerKey)) return;
    FilzaByeTunesMusicController *replacement = [FilzaByeTunesMusicController new];
    [legacy addChildViewController:replacement];
    replacement.view.frame = legacy.view.bounds;
    replacement.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [legacy.view addSubview:replacement.view];
    [replacement didMoveToParentViewController:legacy];
    legacy.navigationItem.title = @"Music Library";
    legacy.navigationItem.titleView = replacement.modeControl;
    legacy.navigationItem.searchController = replacement.searchController;
    legacy.navigationItem.rightBarButtonItem = replacement.navigationItem.rightBarButtonItem;
    objc_setAssociatedObject(legacy, kFBTEmbeddedControllerKey, replacement,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[ByeTunesUI] replaced TGMusicLibraryViewController with Filza-native AFC library");
}

static void FBTLegacyMusicViewDidLoad(id self, SEL _cmd)
{
    if (gLegacyMusicViewDidLoad)
        ((void (*)(id, SEL))gLegacyMusicViewDidLoad)(self, _cmd);
    if (FBTUseReplacementMusicLibrary()) FBTEmbedReplacementController(self);
}

void FilzaPresentByeTunesLibrary(UIViewController *presenter)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = presenter ?: FBTTopController();
        if (!host) return;
        FilzaByeTunesMusicController *library = [FilzaByeTunesMusicController new];
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:library];
        navigation.navigationBar.prefersLargeTitles = NO;
        library.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
            target:navigation action:@selector(dismissViewControllerAnimated:completion:)];
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
        [host presentViewController:navigation animated:YES completion:nil];
    });
}

static void FBTClosePresentedNavigation(id self, SEL _cmd)
{
    [(UIViewController *)self dismissViewControllerAnimated:YES completion:nil];
}

static IMP gOriginalShortcutHandler = NULL;

static BOOL FBTShortcutIsMusic(UIApplicationShortcutItem *item)
{
    if (![item isKindOfClass:UIApplicationShortcutItem.class]) return NO;
    if ([item.localizedTitle caseInsensitiveCompare:@"Music Library"] == NSOrderedSame) return YES;
    return [item.type rangeOfString:@"music" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void FBTShortcutHandler(id self, SEL _cmd, UIApplication *application,
                               UIApplicationShortcutItem *item, void (^completion)(BOOL))
{
    if (FBTShortcutIsMusic(item)) {
        FilzaPresentByeTunesLibrary(nil);
        if (completion) completion(YES);
        return;
    }
    if (gOriginalShortcutHandler)
        ((void (*)(id, SEL, id, id, id))gOriginalShortcutHandler)(self, _cmd,
            application, item, completion);
    else if (completion) completion(NO);
}

static void FBTInstallShortcutHook(void)
{
    id delegate = UIApplication.sharedApplication.delegate;
    Class cls = delegate ? [delegate class] : Nil;
    if (!cls) return;
    SEL selector = @selector(application:performActionForShortcutItem:completionHandler:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method) {
        IMP current = method_getImplementation(method);
        if (current != (IMP)FBTShortcutHandler) {
            gOriginalShortcutHandler = current;
            method_setImplementation(method, (IMP)FBTShortcutHandler);
        }
    } else {
        class_addMethod(cls, selector, (IMP)FBTShortcutHandler, "v@:@@@?");
    }
    NSLog(@"[ByeTunesUI] Home Screen Music Library shortcut routed to replacement UI");
}

void FilzaByeTunesUIStart(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class legacy = NSClassFromString(@"TGMusicLibraryViewController");
        Method viewDidLoad = legacy ? class_getInstanceMethod(legacy, @selector(viewDidLoad)) : NULL;
        if (viewDidLoad) {
            gLegacyMusicViewDidLoad = method_getImplementation(viewDidLoad);
            method_setImplementation(viewDidLoad, (IMP)FBTLegacyMusicViewDidLoad);
        }

        Class navClass = UINavigationController.class;
        SEL closeSelector = NSSelectorFromString(@"fbt_closePresentedMusicLibrary");
        class_addMethod(navClass, closeSelector, (IMP)FBTClosePresentedNavigation, "v@:");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { FBTInstallShortcutHook(); }];
        if (UIApplication.sharedApplication.delegate) FBTInstallShortcutHook();
    });
}

__attribute__((constructor)) static void FilzaByeTunesUIInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ FilzaByeTunesUIStart(); });
}
