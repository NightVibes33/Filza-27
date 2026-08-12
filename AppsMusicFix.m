@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "ByeTunesMusicBridge.h"
#import "MCMBridge.h"
#import "MCMFilzaIntegration.h"

#pragma mark - Runtime interfaces

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
@end

@interface MediaFileItem : NSObject
- (instancetype)initWithLibraryPath:(NSString *)libraryPath
                          trackData:(NSDictionary *)trackData
                       playlistData:(NSDictionary *)playlistData;
@end

#pragma mark - Apps Manager: ContainerManager-backed discovery

static IMP gPreviousAllApplications = NULL;
static IMP gPreviousAppsDidSelect = NULL;

static NSString *FilzaProxyIdentifier(id proxy)
{
    SEL selector = NSSelectorFromString(@"applicationIdentifier");
    if ([proxy respondsToSelector:selector])
        return ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
    return nil;
}

static NSString *FilzaProxyDisplayName(id proxy)
{
    SEL selector = NSSelectorFromString(@"localizedName");
    if ([proxy respondsToSelector:selector]) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if (name.length) return name;
    }
    return FilzaProxyIdentifier(proxy) ?: @"";
}

static id FilzaAllApplications(id self, SEL _cmd)
{
    NSArray *existing = gPreviousAllApplications
        ? ((id (*)(id, SEL))gPreviousAllApplications)(self, _cmd) : @[];
    if (![existing isKindOfClass:NSArray.class]) existing = @[];

    NSMutableDictionary<NSString *, id> *byIdentifier = [NSMutableDictionary dictionary];
    for (id proxy in existing) {
        NSString *identifier = FilzaProxyIdentifier(proxy);
        if (identifier.length) byIdentifier[identifier] = proxy;
    }

    NSString *detail = nil;
    NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 2048, &detail);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        for (NSString *identifier in identifiers ?: @[]) {
            if (!identifier.length || byIdentifier[identifier]) continue;
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                proxySelector, identifier);
            if (proxy) byIdentifier[identifier] = proxy;
        }
    }

    NSArray *result = [byIdentifier.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(id left, id right) {
            return [FilzaProxyDisplayName(left) localizedCaseInsensitiveCompare:
                FilzaProxyDisplayName(right)];
        }];
    NSLog(@"[AppsManagerFix] workspace=%lu mcm=%lu merged=%lu detail=%@",
        (unsigned long)existing.count, (unsigned long)identifiers.count,
        (unsigned long)result.count, detail);
    return result;
}

static id FilzaObjectAtIndexSafely(id collection, NSUInteger index)
{
    if (![collection respondsToSelector:@selector(count)] ||
        ![collection respondsToSelector:@selector(objectAtIndex:)]) return nil;
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(collection, @selector(count));
    if (index >= count) return nil;
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection,
        @selector(objectAtIndex:), index);
}

static NSString *FilzaApplicationItemIdentifier(id item)
{
    for (NSString *name in @[@"bundleId", @"applicationIdentifier"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            NSString *value = ((id (*)(id, SEL))objc_msgSend)(item, selector);
            if ([value isKindOfClass:NSString.class] && value.length) return value;
        }
    }
    SEL proxySelector = NSSelectorFromString(@"appProxy");
    if ([item respondsToSelector:proxySelector])
        return FilzaProxyIdentifier(((id (*)(id, SEL))objc_msgSend)(item, proxySelector));
    return nil;
}

static void FilzaAppsDidSelect(id self, SEL _cmd, id browserView, id indexPath)
{
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    id fileList = [self respondsToSelector:fileListSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self, fileListSelector) : nil;
    NSUInteger row = [indexPath respondsToSelector:@selector(row)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row)) : NSNotFound;
    id item = row == NSNotFound ? nil : FilzaObjectAtIndexSafely(fileList, row);
    NSString *identifier = FilzaApplicationItemIdentifier(item);
    if (identifier.length) {
        NSString *detail = nil;
        NSString *container = MCMFilzaDataContainerPath(identifier, &detail);
        SEL setter = NSSelectorFromString(@"setDocumentPath:");
        if (container.length && [item respondsToSelector:setter])
            ((void (*)(id, SEL, id))objc_msgSend)(item, setter, container);
        NSLog(@"[AppsManagerFix] id=%@ container=%@ detail=%@",
              identifier, container, detail);
    }
    if (gPreviousAppsDidSelect)
        ((void (*)(id, SEL, id, id))gPreviousAppsDidSelect)(self, _cmd,
            browserView, indexPath);
}

#pragma mark - Music Library: ByeTunes AFC + MediaLibrary.sqlitedb

static const void *kByeTunesSongKey = &kByeTunesSongKey;
static IMP gPreviousMusicLoad = NULL;
static IMP gPreviousMusicDidSelect = NULL;
static IMP gPreviousFilePath = NULL;
static IMP gPreviousRealPath = NULL;
static IMP gPreviousFileName = NULL;
static IMP gPreviousMediaType = NULL;
static IMP gPreviousIsDownloaded = NULL;
static IMP gPreviousDuration = NULL;
static IMP gPreviousAlbum = NULL;
static IMP gPreviousArtist = NULL;

static NSDictionary *FilzaByeTunesSong(id item)
{
    return objc_getAssociatedObject(item, kByeTunesSongKey);
}

static NSDictionary *FilzaTrackData(NSDictionary *song)
{
    NSString *title = [song[@"Title"] isKindOfClass:NSString.class] ? song[@"Title"] : @"";
    NSString *artist = [song[@"Artist"] isKindOfClass:NSString.class] ? song[@"Artist"] : @"";
    NSString *album = [song[@"Album"] isKindOfClass:NSString.class] ? song[@"Album"] : @"";
    NSString *location = [song[@"Location"] isKindOfClass:NSString.class] ? song[@"Location"] : @"";
    return @{
        @"item_pid": song[@"PersistentID"] ?: @0,
        @"track_number": song[@"TrackNumber"] ?: @0,
        @"media_type": @8,
        @"item_extra.title": title,
        @"item_artist.item_artist": artist,
        @"album.album": album,
        @"item_extra.year": song[@"Year"] ?: @0,
        @"item_extra.location": location,
        @"item_extra.file_size": song[@"FileSize"] ?: @0,
        @"item_extra.total_time_ms": song[@"DurationMS"] ?: @0,
        @"base_location_id": @3840,
    };
}

static id FilzaMediaItemForSong(NSDictionary *song)
{
    Class cls = NSClassFromString(@"MediaFileItem");
    if (!cls) return nil;
    id item = nil;
    SEL initializer = NSSelectorFromString(@"initWithLibraryPath:trackData:playlistData:");
    @try {
        id allocated = [cls alloc];
        if ([allocated respondsToSelector:initializer])
            item = ((id (*)(id, SEL, id, id, id))objc_msgSend)(allocated,
                initializer, @"/var/mobile/Media", FilzaTrackData(song), @{});
        else
            item = [allocated init];
    } @catch (NSException *exception) {
        NSLog(@"[ByeTunesBridge] MediaFileItem init exception=%@", exception);
        item = [[cls alloc] init];
    }
    if (!item) return nil;
    objc_setAssociatedObject(item, kByeTunesSongKey, song,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL setPerID = NSSelectorFromString(@"setPerID:");
    if ([item respondsToSelector:setPerID])
        ((void (*)(id, SEL, long long))objc_msgSend)(item, setPerID,
            [song[@"PersistentID"] longLongValue]);
    SEL setName = NSSelectorFromString(@"set_fileName:");
    if ([item respondsToSelector:setName])
        ((void (*)(id, SEL, id))objc_msgSend)(item, setName, song[@"Title"] ?: @"Track");
    return item;
}

static void FilzaFinishMusicLoad(id controller, NSArray *items)
{
    SEL listSelector = NSSelectorFromString(@"fileList");
    id list = [controller respondsToSelector:listSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(controller, listSelector) : nil;
    if ([list respondsToSelector:@selector(removeAllObjects)])
        ((void (*)(id, SEL))objc_msgSend)(list, @selector(removeAllObjects));
    if ([list respondsToSelector:@selector(addObjectsFromArray:)])
        ((void (*)(id, SEL, id))objc_msgSend)(list, @selector(addObjectsFromArray:), items ?: @[]);

    for (NSString *name in @[@"updateDirectoryInfo", @"hideLoadingProgress"]) {
        SEL selector = NSSelectorFromString(name);
        if ([controller respondsToSelector:selector])
            ((void (*)(id, SEL))objc_msgSend)(controller, selector);
    }
    SEL setLoading = NSSelectorFromString(@"setIsLoading:");
    if ([controller respondsToSelector:setLoading])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, setLoading, NO);
    SEL browserSelector = NSSelectorFromString(@"browserView");
    id browser = [controller respondsToSelector:browserSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(controller, browserSelector) : nil;
    if ([browser respondsToSelector:@selector(reloadData)])
        ((void (*)(id, SEL))objc_msgSend)(browser, @selector(reloadData));
}

static void FilzaShowMusicError(id controller, NSString *detail)
{
    if (![controller isKindOfClass:UIViewController.class] || !detail.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Music Library"
        message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

static void FilzaLoadMusic(id self, SEL _cmd, int sortMode, BOOL preserveSelected)
{
    SEL setLoading = NSSelectorFromString(@"setIsLoading:");
    if ([self respondsToSelector:setLoading])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, setLoading, YES);
    SEL show = NSSelectorFromString(@"showLoadingProgress");
    if ([self respondsToSelector:show])
        ((void (*)(id, SEL))objc_msgSend)(self, show);

    __weak id weakController = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        NSArray<NSDictionary *> *songs = BTMusicLoadLibrary(&detail);
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:songs.count];
        for (NSDictionary *song in songs ?: @[]) {
            id item = FilzaMediaItemForSong(song);
            if (item) [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            id controller = weakController;
            if (!controller) return;
            FilzaFinishMusicLoad(controller, items);
            if (!songs) {
                NSLog(@"[ByeTunesBridge] library load failed detail=%@", detail);
                FilzaShowMusicError(controller, detail);
            } else {
                NSLog(@"[ByeTunesBridge] rendered %lu songs", (unsigned long)items.count);
            }
        });
    });
}

static NSString *FilzaMusicLocalPath(id self, BOOL materialize)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (!song) return nil;
    if (materialize) {
        NSString *detail = nil;
        NSString *path = BTMusicEnsureLocalFile(song, &detail);
        if (!path.length) NSLog(@"[ByeTunesBridge] materialize failed: %@", detail);
        return path;
    }
    NSString *remote = song[@"RemotePath"];
    NSString *extension = [remote pathExtension].length ? [remote pathExtension] : @"m4a";
    NSString *identifier = [song[@"PersistentID"] stringValue] ?: @"track";
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
        NSUserDomainMask, YES).firstObject;
    NSString *base = [documents stringByAppendingPathComponent:
        @"Device Storage/[ByeTunes] Music Cache"];
    return [[base stringByAppendingPathComponent:identifier]
        stringByAppendingPathExtension:extension];
}

static NSString *FilzaMusicFilePath(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return FilzaMusicLocalPath(self, NO);
    return gPreviousFilePath ? ((id (*)(id, SEL))gPreviousFilePath)(self, _cmd) : nil;
}

static NSString *FilzaMusicRealPath(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return FilzaMusicLocalPath(self, YES);
    return gPreviousRealPath ? ((id (*)(id, SEL))gPreviousRealPath)(self, _cmd) : nil;
}

static NSString *FilzaMusicFileName(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return song[@"Title"] ?: @"Track";
    return gPreviousFileName ? ((id (*)(id, SEL))gPreviousFileName)(self, _cmd) : @"";
}

static NSUInteger FilzaMusicMediaType(id self, SEL _cmd)
{
    if (FilzaByeTunesSong(self)) return 8;
    return gPreviousMediaType ? ((NSUInteger (*)(id, SEL))gPreviousMediaType)(self, _cmd) : 0;
}

static BOOL FilzaMusicIsDownloaded(id self, SEL _cmd)
{
    if (FilzaByeTunesSong(self)) return YES;
    return gPreviousIsDownloaded ? ((BOOL (*)(id, SEL))gPreviousIsDownloaded)(self, _cmd) : NO;
}

static double FilzaMusicDuration(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return [song[@"DurationMS"] doubleValue] / 1000.0;
    return gPreviousDuration ? ((double (*)(id, SEL))gPreviousDuration)(self, _cmd) : 0;
}

static NSString *FilzaMusicAlbum(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return song[@"Album"] ?: @"";
    return gPreviousAlbum ? ((id (*)(id, SEL))gPreviousAlbum)(self, _cmd) : @"";
}

static NSString *FilzaMusicArtist(id self, SEL _cmd)
{
    NSDictionary *song = FilzaByeTunesSong(self);
    if (song) return song[@"Artist"] ?: @"";
    return gPreviousArtist ? ((id (*)(id, SEL))gPreviousArtist)(self, _cmd) : @"";
}

static void FilzaMusicDidSelect(id self, SEL _cmd, id browserView, id indexPath)
{
    SEL listSelector = NSSelectorFromString(@"fileList");
    id list = [self respondsToSelector:listSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self, listSelector) : nil;
    NSUInteger row = [indexPath respondsToSelector:@selector(row)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row)) : NSNotFound;
    id item = row == NSNotFound ? nil : FilzaObjectAtIndexSafely(list, row);
    if (FilzaByeTunesSong(item)) {
        NSString *detail = nil;
        NSString *path = BTMusicEnsureLocalFile(FilzaByeTunesSong(item), &detail);
        if (!path.length) {
            FilzaShowMusicError(self, detail ?: @"Unable to fetch track through AFC.");
            return;
        }
    }
    if (gPreviousMusicDidSelect)
        ((void (*)(id, SEL, id, id))gPreviousMusicDidSelect)(self, _cmd,
            browserView, indexPath);
}

#pragma mark - Hook installation

static IMP FilzaReplaceInstanceMethod(Class cls, SEL selector, IMP replacement)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    IMP old = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return old;
}

static void FilzaInstallAppsMusicFixes(void)
{
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    gPreviousAllApplications = FilzaReplaceInstanceMethod(workspace,
        NSSelectorFromString(@"allApplications"), (IMP)FilzaAllApplications);

    Class apps = NSClassFromString(@"TGApplicationsViewController");
    gPreviousAppsDidSelect = FilzaReplaceInstanceMethod(apps,
        NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"),
        (IMP)FilzaAppsDidSelect);

    Class music = NSClassFromString(@"TGMusicLibraryViewController");
    gPreviousMusicLoad = FilzaReplaceInstanceMethod(music,
        NSSelectorFromString(@"loadFilesWithSortMode:preserveSeletedItems:"),
        (IMP)FilzaLoadMusic);
    gPreviousMusicDidSelect = FilzaReplaceInstanceMethod(music,
        NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"),
        (IMP)FilzaMusicDidSelect);

    Class media = NSClassFromString(@"MediaFileItem");
    gPreviousFilePath = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"filePath"),
        (IMP)FilzaMusicFilePath);
    gPreviousRealPath = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"realPath"),
        (IMP)FilzaMusicRealPath);
    gPreviousFileName = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"fileName"),
        (IMP)FilzaMusicFileName);
    gPreviousMediaType = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"mediaType"),
        (IMP)FilzaMusicMediaType);
    gPreviousIsDownloaded = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"isDownloaded"),
        (IMP)FilzaMusicIsDownloaded);
    gPreviousDuration = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"duration"),
        (IMP)FilzaMusicDuration);
    gPreviousAlbum = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"album"),
        (IMP)FilzaMusicAlbum);
    gPreviousArtist = FilzaReplaceInstanceMethod(media, NSSelectorFromString(@"artist"),
        (IMP)FilzaMusicArtist);

    NSLog(@"[AppsMusicFix] Apps Manager + ByeTunes Music hooks installed");
}

__attribute__((constructor)) static void FilzaAppsMusicFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ FilzaInstallAppsMusicFixes(); });
}
