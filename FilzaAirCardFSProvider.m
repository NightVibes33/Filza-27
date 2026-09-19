@import Foundation;
@import UIKit;

#include <AirliftFFI/airlift.h>

#import "FilzaDiagnostics.h"
#import "MCMFilzaIntegration.h"

static NSString *const FZAirCardMirrorName = @"[AirCard] Paired AFC";
static const NSUInteger FZAirCardMaxDepth = 3;
static const NSUInteger FZAirCardMaxFiles = 128;
static const NSUInteger FZAirCardMaxFileBytes = 4 * 1024 * 1024;
static const NSUInteger FZAirCardMaxTotalBytes = 32 * 1024 * 1024;

static NSString *FZAirCardPairingPath(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) return nil;
    NSArray<NSString *> *names = @[@"aircard_pairing.plist", @"airlift_pairing.plist"];
    for (NSString *name in names) {
        NSString *path = [docs stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attrs[NSFileSize] unsignedLongLongValue] > 0) return path;
    }
    return nil;
}

static NSArray<NSDictionary *> *FZAirCardList(NSString *pairing, NSString *remote, NSString **errorOut)
{
    char *json = NULL;
    char *error = NULL;
    int32_t rc = al_filza_fs_list(pairing.UTF8String, remote.UTF8String, &json, &error);
    NSString *err = error ? [NSString stringWithUTF8String:error] : nil;
    if (error) al_string_free(error);
    if (rc != 0 || !json) {
        if (errorOut) *errorOut = err ?: [NSString stringWithFormat:@"list failed rc=%d", rc];
        if (json) al_string_free(json);
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBytes:json length:strlen(json)];
    al_string_free(json);
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSArray.class] ? object : nil;
}

static NSData *FZAirCardRead(NSString *pairing, NSString *remote, NSString **errorOut)
{
    uint8_t *bytes = NULL;
    size_t length = 0;
    char *error = NULL;
    int32_t rc = al_filza_fs_read(pairing.UTF8String, remote.UTF8String, &bytes, &length, &error);
    NSString *err = error ? [NSString stringWithUTF8String:error] : nil;
    if (error) al_string_free(error);
    if (rc != 0 || !bytes) {
        if (errorOut) *errorOut = err ?: [NSString stringWithFormat:@"read failed rc=%d", rc];
        if (bytes) al_filza_fs_bytes_free(bytes, length);
        return nil;
    }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    al_filza_fs_bytes_free(bytes, length);
    return data;
}

static NSString *FZAirCardSafeName(NSString *name)
{
    if (!name.length) return @"unnamed";
    NSString *safe = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safe = [safe stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return safe;
}

static BOOL FZAirCardLooksDirectory(NSDictionary *row)
{
    NSString *kind = [row[@"kind"] lowercaseString];
    return [kind containsString:@"dir"] || [kind containsString:@"s_ifdir"];
}

static void FZAirCardMirrorDirectory(NSString *pairing,
                                     NSString *remote,
                                     NSString *local,
                                     NSUInteger depth,
                                     NSMutableArray<NSDictionary *> *manifest,
                                     NSUInteger *fileCount,
                                     NSUInteger *totalBytes)
{
    if (depth > FZAirCardMaxDepth || *fileCount >= FZAirCardMaxFiles) return;

    NSString *listError = nil;
    NSArray<NSDictionary *> *rows = FZAirCardList(pairing, remote, &listError);
    if (!rows) {
        [manifest addObject:@{@"path": remote ?: @"", @"status": @"list-failed", @"error": listError ?: @"unknown"}];
        return;
    }

    [NSFileManager.defaultManager createDirectoryAtPath:local
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

    for (NSDictionary *row in rows) {
        if (*fileCount >= FZAirCardMaxFiles) break;

        NSString *name = [row[@"name"] isKindOfClass:NSString.class] ? row[@"name"] : nil;
        NSString *remotePath = [row[@"path"] isKindOfClass:NSString.class] ? row[@"path"] : name;
        if (!name.length || !remotePath.length) continue;

        NSString *localPath = [local stringByAppendingPathComponent:FZAirCardSafeName(name)];
        if (FZAirCardLooksDirectory(row)) {
            [manifest addObject:@{@"path": remotePath, @"status": @"directory"}];
            FZAirCardMirrorDirectory(pairing, remotePath, localPath, depth + 1, manifest, fileCount, totalBytes);
            continue;
        }

        NSUInteger declaredSize = [row[@"size"] unsignedIntegerValue];
        NSMutableDictionary *entry = [row mutableCopy];
        entry[@"localPath"] = localPath;

        if (declaredSize > FZAirCardMaxFileBytes || *totalBytes + declaredSize > FZAirCardMaxTotalBytes) {
            entry[@"status"] = @"not-mirrored-size-limit";
            NSString *marker = [NSString stringWithFormat:
                @"AirCard remote file\nRemote path: %@\nSize: %lu bytes\n"
                 "This file exists on the paired AFC service but was not copied into Filza's mirror because the bounded mirror size limit was reached.\n",
                remotePath, (unsigned long)declaredSize];
            [marker writeToFile:[localPath stringByAppendingString:@".aircardremote.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [manifest addObject:entry];
            continue;
        }

        NSString *readError = nil;
        NSData *data = FZAirCardRead(pairing, remotePath, &readError);
        if (!data) {
            entry[@"status"] = @"read-failed";
            if (readError.length) entry[@"error"] = readError;
            [manifest addObject:entry];
            continue;
        }

        NSError *writeError = nil;
        if ([data writeToFile:localPath options:NSDataWritingAtomic error:&writeError]) {
            (*fileCount)++;
            *totalBytes += data.length;
            entry[@"status"] = @"mirrored";
            entry[@"mirroredBytes"] = @(data.length);
        } else {
            entry[@"status"] = @"local-write-failed";
            entry[@"error"] = writeError.localizedDescription ?: @"unknown";
        }
        [manifest addObject:entry];
    }
}

static void FZAirCardRefreshMirror(void)
{
    NSString *pairing = FZAirCardPairingPath();
    if (!pairing.length) {
        FilzaDiagnosticsAppend(@"AirCardFS", @"no pairing file; mirror refresh skipped");
        return;
    }

    NSString *root = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:FZAirCardMirrorName];
    NSString *staging = [root stringByAppendingString:@".staging"];
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:staging
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSDictionary *> *manifest = [NSMutableArray array];
    NSUInteger files = 0, bytes = 0;
    FZAirCardMirrorDirectory(pairing, @"", staging, 0, manifest, &files, &bytes);

    NSDictionary *summary = @{
        @"backend": @"AirCard/Airlift paired AFC",
        @"pairingFile": pairing.lastPathComponent ?: @"unknown",
        @"filesMirrored": @(files),
        @"bytesMirrored": @(bytes),
        @"maxDepth": @(FZAirCardMaxDepth),
        @"maxFiles": @(FZAirCardMaxFiles),
        @"maxFileBytes": @(FZAirCardMaxFileBytes),
        @"maxTotalBytes": @(FZAirCardMaxTotalBytes),
        @"entries": manifest
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[staging stringByAppendingPathComponent:@"AirCard Reach Manifest.json"]
              atomically:YES];

    NSString *readme =
        @"AirCard/Airlift paired AFC mirror\n\n"
         "Every visible directory/file in this folder was returned by the live paired AFC service. "
         "Files marked .aircardremote.txt are real remote entries that were not mirrored because of the bounded cache limits. "
         "This mirror does not imply kernel access or unrestricted root filesystem access. "
         "Airlift's separate AirTraffic write primitive is not represented here as readable content unless AFC can enumerate/read it.\n";
    [readme writeToFile:[staging stringByAppendingPathComponent:@"README.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:staging toPath:root error:&moveError]) {
        FilzaDiagnosticsAppend(@"AirCardFS", [NSString stringWithFormat:@"mirror activation failed: %@", moveError]);
        return;
    }

    FilzaDiagnosticsAppend(@"AirCardFS",
        [NSString stringWithFormat:@"verified AFC mirror refreshed files=%lu bytes=%lu",
         (unsigned long)files, (unsigned long)bytes]);
}

__attribute__((constructor)) static void FZAirCardFSInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    FZAirCardRefreshMirror();
                });
            }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FZAirCardRefreshMirror();
        });
    });
}
