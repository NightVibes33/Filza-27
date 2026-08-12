@import Foundation;
@import UIKit;
@import MediaPlayer;

#import <objc/message.h>
#import <objc/runtime.h>

#import "MCMBridge.h"
#import "MCMFilzaIntegration.h"

#pragma mark - Runtime interfaces

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
@end

@interface MediaFileItem : NSObject
- (void)setPersistentID:(long long)persistentID;
- (long long)perID;
- (void)setPerID:(long long)persistentID;
- (id)item;
- (void)setItem:(id)item;
- (id)track;
- (void)set_fileName:(NSString *)name;
- (NSString *)fileName;
- (NSString *)filePath;
- (NSString *)realPath;
- (NSUInteger)mediaType;
- (BOOL)isDownloaded;
- (double)duration;
- (NSString *)album;
- (void)reload;
@end

static BOOL FilzaUseModernMediaFallback(void)
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
}

#pragma mark - Apps Manager

static IMP gPreviousAllApplications = NULL;
static IMP gPreviousAppsDidSelect = NULL;

static NSString *FilzaProxyIdentifier(id proxy)
{
    if ([proxy respondsToSelector:@selector(applicationIdentifier)])
        return ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(applicationIdentifier));
    return nil;
}

static NSString *FilzaProxyDisplayName(id proxy)
{
    if ([proxy respondsToSelector:@selector(localizedName)]) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
        if (name.length) return name;
    }
    return FilzaProxyIdentifier(proxy) ?: @"";
}

static id FilzaAllApplications(id self, SEL _cmd)
{
    NSArray *existing = gPreviousAllApplications
        ? ((id (*)(id, SEL))gPreviousAllApplications)(self, _cmd)
        : @[];

    NSMutableDictionary<NSString *, id> *byIdentifier = [NSMutableDictionary dictionary];
    for (id proxy in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        NSString *identifier = FilzaProxyIdentifier(proxy);
        if (identifier.length) byIdentifier[identifier] = proxy;
    }

    NSString *detail = nil;
    NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 2048, &detail);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        for (NSString *identifier in identifiers ?: @[]) {
            if (identifier.length == 0 || byIdentifier[identifier]) continue;
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                proxySelector, identifier);
            if (proxy) byIdentifier[identifier] = proxy;
        }
    }

    NSArray *result = [byIdentifier.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(id lhs, id rhs) {
            return [FilzaProxyDisplayName(lhs) localizedCaseInsensitiveCompare:
                FilzaProxyDisplayName(rhs)];
        }];
    NSLog(@"[AppsManagerFix] workspace=%lu mcm=%lu merged=%lu detail=%@",
        (unsigned long)existing.count, (unsigned long)identifiers.count,
        (unsigned long)result.count, detail);
    return result;
}

static NSString *FilzaApplicationItemBundleIdentifier(id item)
{
    for (NSString *selectorName in @[@"bundleId", @"applicationIdentifier"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([item respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(item, selector);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }
    SEL proxySelector = NSSelectorFromString(@"appProxy");
    if ([item respondsToSelector:proxySelector]) {
        id proxy = ((id (*)(id, SEL))objc_msgSend)(item, proxySelector);
        return FilzaProxyIdentifier(proxy);
    }
    return nil;
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

static void FilzaAppsDidSelect(id self, SEL _cmd, id browserView, id indexPath)
{
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    id fileList = [self respondsToSelector:fileListSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self, fileListSelector) : nil;
    NSUInteger row = [indexPath respondsToSelector:@selector(row)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row)) : NSNotFound;
    id item = row == NSNotFound ? nil : FilzaObjectAtIndexSafely(fileList, row);
    NSString *identifier = FilzaApplicationItemBundleIdentifier(item);

    if (identifier.length) {
        NSString *detail = nil;
        NSString *container = MCMFilzaDataContainerPath(identifier, &detail);
        SEL setDocumentPath = NSSelectorFromString(@"setDocumentPath:");
        if (container.length && [item respondsToSelector:setDocumentPath]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, setDocumentPath, container);
            NSLog(@"[AppsManagerFix] activated %@ -> %@", identifier, container);
        } else if (!container.length) {
            NSLog(@"[AppsManagerFix] activation denied id=%@ detail=%@", identifier, detail);
        }
    }

    if (gPreviousAppsDidSelect)
        ((void (*)(id, SEL, id, id))gPreviousAppsDidSelect)(self, _cmd,
            browserView, indexPath);
}

#pragma mark - Public MediaPlayer fallback

static IMP gOriginalMusicLoad = NULL;
static IMP gOriginalMediaSetPersistentID = NULL;
static IMP gOriginalMediaType = NULL;
static IMP gOriginalMediaIsDownloaded = NULL;
static IMP gOriginalMediaDuration = NULL;
static IMP gOriginalMediaAlbum = NULL;
static IMP gOriginalMediaReload = NULL;

static MPMediaItem *FilzaPublicMediaItem(MPMediaEntityPersistentID persistentID)
{
    if (persistentID == 0) return nil;
    for (MPMediaItem *item in [MPMediaQuery songsQuery].items ?: @[])
        if (item.persistentID == persistentID) return item;
    return nil;
}

static void FilzaPopulatePublicMediaItem(id object, MPMediaItem *item)
{
    if (!object || !item) return;
    if ([object respondsToSelector:NSSelectorFromString(@"setPerID:")])
        ((void (*)(id, SEL, long long))objc_msgSend)(object,
            NSSelectorFromString(@"setPerID:"), (long long)item.persistentID);
    if ([object respondsToSelector:NSSelectorFromString(@"setItem:")])
        ((void (*)(id, SEL, id))objc_msgSend)(object,
            NSSelectorFromString(@"setItem:"), item);
    NSString *title = item.title.length ? item.title
        : [NSString stringWithFormat:@"%llu", item.persistentID];
    if ([object respondsToSelector:NSSelectorFromString(@"set_fileName:")])
        ((void (*)(id, SEL, id))objc_msgSend)(object,
            NSSelectorFromString(@"set_fileName:"), title);
}

static void FilzaMediaSetPersistentID(id self, SEL _cmd, long long persistentID)
{
    if (!FilzaUseModernMediaFallback()) {
        if (gOriginalMediaSetPersistentID)
            ((void (*)(id, SEL, long long))gOriginalMediaSetPersistentID)(self,
                _cmd, persistentID);
        return;
    }

    if (gOriginalMediaSetPersistentID) {
        @try {
            ((void (*)(id, SEL, long long))gOriginalMediaSetPersistentID)(self,
                _cmd, persistentID);
        } @catch (__unused NSException *exception) {}
    }

    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (track) return;

    MPMediaItem *item = FilzaPublicMediaItem((MPMediaEntityPersistentID)persistentID);
    if (item) FilzaPopulatePublicMediaItem(self, item);
}

static NSUInteger FilzaMediaType(id self, SEL _cmd)
{
    id item = [self respondsToSelector:NSSelectorFromString(@"item")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"item")) : nil;
    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (FilzaUseModernMediaFallback() && item && !track) return 8;
    return gOriginalMediaType
        ? ((NSUInteger (*)(id, SEL))gOriginalMediaType)(self, _cmd) : 0;
}

static BOOL FilzaMediaIsDownloaded(id self, SEL _cmd)
{
    MPMediaItem *item = [self respondsToSelector:NSSelectorFromString(@"item")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"item")) : nil;
    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (FilzaUseModernMediaFallback() && item && !track)
        return item.assetURL.isFileURL;
    return gOriginalMediaIsDownloaded
        ? ((BOOL (*)(id, SEL))gOriginalMediaIsDownloaded)(self, _cmd) : NO;
}

static double FilzaMediaDuration(id self, SEL _cmd)
{
    MPMediaItem *item = [self respondsToSelector:NSSelectorFromString(@"item")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"item")) : nil;
    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (FilzaUseModernMediaFallback() && item && !track)
        return item.playbackDuration;
    return gOriginalMediaDuration
        ? ((double (*)(id, SEL))gOriginalMediaDuration)(self, _cmd) : 0.0;
}

static NSString *FilzaMediaAlbum(id self, SEL _cmd)
{
    MPMediaItem *item = [self respondsToSelector:NSSelectorFromString(@"item")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"item")) : nil;
    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (FilzaUseModernMediaFallback() && item && !track)
        return item.albumTitle ?: @"";
    return gOriginalMediaAlbum
        ? ((id (*)(id, SEL))gOriginalMediaAlbum)(self, _cmd) : @"";
}

static void FilzaMediaReload(id self, SEL _cmd)
{
    id item = [self respondsToSelector:NSSelectorFromString(@"item")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"item")) : nil;
    id track = [self respondsToSelector:NSSelectorFromString(@"track")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"track")) : nil;
    if (FilzaUseModernMediaFallback() && item && !track) {
        FilzaPopulatePublicMediaItem(self, item);
        return;
    }
    if (gOriginalMediaReload)
        ((void (*)(id, SEL))gOriginalMediaReload)(self, _cmd);
}

static void FilzaFinishMusicLoad(id controller, NSArray *files)
{
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    id fileList = [controller respondsToSelector:fileListSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(controller, fileListSelector) : nil;
    if ([fileList respondsToSelector:@selector(removeAllObjects)])
        ((void (*)(id, SEL))objc_msgSend)(fileList, @selector(removeAllObjects));
    if ([fileList respondsToSelector:@selector(addObjectsFromArray:)])
        ((void (*)(id, SEL, id))objc_msgSend)(fileList,
            @selector(addObjectsFromArray:), files ?: @[]);

    SEL updateInfo = NSSelectorFromString(@"updateDirectoryInfo");
    if ([controller respondsToSelector:updateInfo])
        ((void (*)(id, SEL))objc_msgSend)(controller, updateInfo);
    SEL hideLoading = NSSelectorFromString(@"hideLoadingProgress");
    if ([controller respondsToSelector:hideLoading])
        ((void (*)(id, SEL))objc_msgSend)(controller, hideLoading);
    SEL browserSelector = NSSelectorFromString(@"browserView");
    id browser = [controller respondsToSelector:browserSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(controller, browserSelector) : nil;
    if ([browser respondsToSelector:@selector(reloadData)])
        ((void (*)(id, SEL))objc_msgSend)(browser, @selector(reloadData));
    SEL setLoading = NSSelectorFromString(@"setIsLoading:");
    if ([controller respondsToSelector:setLoading])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, setLoading, NO);
}

static void FilzaLoadMusic(id self, SEL _cmd, int sortMode, BOOL preserveSelected)
{
    if (!FilzaUseModernMediaFallback()) {
        if (gOriginalMusicLoad)
            ((void (*)(id, SEL, int, BOOL))gOriginalMusicLoad)(self, _cmd,
                sortMode, preserveSelected);
        return;
    }

    MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
    if (status == MPMediaLibraryAuthorizationStatusNotDetermined) {
        __weak id weakController = self;
        [MPMediaLibrary requestAuthorization:^(__unused MPMediaLibraryAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id controller = weakController;
                SEL reload = NSSelectorFromString(@"doLoadingPage");
                if (controller && [controller respondsToSelector:reload])
                    ((void (*)(id, SEL))objc_msgSend)(controller, reload);
            });
        }];
        return;
    }

    if (status != MPMediaLibraryAuthorizationStatusAuthorized &&
        status != MPMediaLibraryAuthorizationStatusRestricted) {
        NSLog(@"[MusicLibraryFix] media-library access unavailable status=%ld",
            (long)status);
        FilzaFinishMusicLoad(self, @[]);
        return;
    }

    SEL isLoading = NSSelectorFromString(@"isLoading");
    if ([self respondsToSelector:isLoading] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(self, isLoading)) return;
    SEL setLoading = NSSelectorFromString(@"setIsLoading:");
    if ([self respondsToSelector:setLoading])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, setLoading, YES);
    SEL showLoading = NSSelectorFromString(@"showLoadingProgress");
    if ([self respondsToSelector:showLoading])
        ((BOOL (*)(id, SEL))objc_msgSend)(self, showLoading);

    __weak id weakController = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<MPMediaItem *> *items = [MPMediaQuery songsQuery].items ?: @[];
        NSMutableArray *files = [NSMutableArray arrayWithCapacity:items.count];
        Class itemClass = NSClassFromString(@"MediaFileItem");
        for (MPMediaItem *mediaItem in items) {
            if (!itemClass || mediaItem.persistentID == 0) continue;
            id file = [[itemClass alloc] init];
            FilzaPopulatePublicMediaItem(file, mediaItem);
            [files addObject:file];
        }
        [files sortUsingComparator:^NSComparisonResult(id lhs, id rhs) {
            NSString *left = [lhs respondsToSelector:NSSelectorFromString(@"fileName")]
                ? ((id (*)(id, SEL))objc_msgSend)(lhs,
                    NSSelectorFromString(@"fileName")) : @"";
            NSString *right = [rhs respondsToSelector:NSSelectorFromString(@"fileName")]
                ? ((id (*)(id, SEL))objc_msgSend)(rhs,
                    NSSelectorFromString(@"fileName")) : @"";
            return [(left ?: @"") localizedCaseInsensitiveCompare:(right ?: @"")];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            id controller = weakController;
            if (!controller) return;
            NSLog(@"[MusicLibraryFix] loaded %lu MediaPlayer item(s)",
                (unsigned long)files.count);
            FilzaFinishMusicLoad(controller, files);
        });
    });
}

#pragma mark - Hook installation

static void FilzaReplaceInstanceMethod(Class cls, SEL selector, IMP replacement,
                                       IMP *previous)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    if (previous) *previous = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void FilzaInstallAppsAndMusicFixes(void)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    FilzaReplaceInstanceMethod(workspaceClass, NSSelectorFromString(@"allApplications"),
        (IMP)FilzaAllApplications, &gPreviousAllApplications);

    Class appsController = NSClassFromString(@"TGApplicationsViewController");
    FilzaReplaceInstanceMethod(appsController,
        NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"),
        (IMP)FilzaAppsDidSelect, &gPreviousAppsDidSelect);

    Class mediaFileItem = NSClassFromString(@"MediaFileItem");
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"setPersistentID:"),
        (IMP)FilzaMediaSetPersistentID, &gOriginalMediaSetPersistentID);
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"mediaType"),
        (IMP)FilzaMediaType, &gOriginalMediaType);
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"isDownloaded"),
        (IMP)FilzaMediaIsDownloaded, &gOriginalMediaIsDownloaded);
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"duration"),
        (IMP)FilzaMediaDuration, &gOriginalMediaDuration);
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"album"),
        (IMP)FilzaMediaAlbum, &gOriginalMediaAlbum);
    FilzaReplaceInstanceMethod(mediaFileItem, NSSelectorFromString(@"reload"),
        (IMP)FilzaMediaReload, &gOriginalMediaReload);

    Class musicController = NSClassFromString(@"TGMusicLibraryViewController");
    FilzaReplaceInstanceMethod(musicController,
        NSSelectorFromString(@"loadFilesWithSortMode:preserveSeletedItems:"),
        (IMP)FilzaLoadMusic, &gOriginalMusicLoad);

    NSLog(@"[RuntimeFix] Apps Manager + Music Library hooks installed");
}

__attribute__((constructor)) static void FilzaAppsMusicFixInit(void)
{
    // Tweak.m installs its compatibility hooks in another constructor. Queueing
    // this installation onto the main queue guarantees that these replacements
    // wrap the final implementations rather than racing constructor order.
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaInstallAppsAndMusicFixes();
    });
}
