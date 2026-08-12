#import "ByeTunesMusicBridge.h"
#import "ByeTunesIdevice.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <sqlite3.h>
#import <unistd.h>

static NSString *const BTRPPairingHost = @"10.7.0.1";
static const uint16_t BTRPPairingPort = 49152;
static NSString *const BTLibraryRemotePath = @"/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

@interface BTMusicSession : NSObject
@property(nonatomic) RpPairingFileHandle *pairing;
@property(nonatomic) AdapterHandle *adapter;
@property(nonatomic) RsdHandshakeHandle *handshake;
@property(nonatomic) AfcClientHandle *afc;
@end

@implementation BTMusicSession
- (void)dealloc
{
    if (_afc) afc_client_free(_afc);
    if (_handshake) rsd_handshake_free(_handshake);
    if (_adapter) adapter_free(_adapter);
    if (_pairing) rp_pairing_file_free(_pairing);
}
@end

static NSString *BTDocumentsDirectory(void)
{
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                NSUserDomainMask, YES).firstObject;
}

NSArray<NSString *> *BTMusicPairingFileCandidates(void)
{
    NSString *documents = BTDocumentsDirectory();
    return @[
        [documents stringByAppendingPathComponent:@"pairing file/rpPairingFile.plist"],
        [documents stringByAppendingPathComponent:@"pairing file/pairingFile.plist"],
        [documents stringByAppendingPathComponent:@"rpPairingFile.plist"],
        [documents stringByAppendingPathComponent:@"pairingFile.plist"],
    ];
}

static NSString *BTExistingPairingFile(void)
{
    for (NSString *candidate in BTMusicPairingFileCandidates())
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    return nil;
}

static NSString *BTFFIError(IdeviceFfiError *error, NSString *operation)
{
    if (!error) return nil;
    NSString *message = error->message
        ? [NSString stringWithUTF8String:error->message] : @"unknown idevice error";
    NSString *result = [NSString stringWithFormat:@"%@ failed: [%d:%d] %@",
        operation, error->code, error->sub_code, message ?: @"unknown"];
    idevice_error_free(error);
    return result;
}

static BTMusicSession *BTConnect(NSString **error)
{
    NSString *pairingPath = BTExistingPairingFile();
    if (!pairingPath) {
        if (error) *error = [NSString stringWithFormat:
            @"ByeTunes pairing file missing. Put rpPairingFile.plist in %@/pairing file and enable LocalDevVPN.",
            BTDocumentsDirectory()];
        return nil;
    }

    BTMusicSession *session = [BTMusicSession new];
    RpPairingFileHandle *pairing = NULL;
    IdeviceFfiError *ffi = rp_pairing_file_read(pairingPath.fileSystemRepresentation,
                                                 &pairing);
    if (ffi) {
        if (error) *error = BTFFIError(ffi, @"rp_pairing_file_read");
        return nil;
    }
    session.pairing = pairing;

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(BTRPPairingPort);
    if (inet_pton(AF_INET, BTRPPairingHost.UTF8String, &address.sin_addr) != 1) {
        if (error) *error = @"invalid ByeTunes RPPairing endpoint";
        return nil;
    }

    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    ffi = tunnel_create_rppairing((const struct sockaddr *)&address,
        (socklen_t)sizeof(address), "FilzaSlop", pairing,
        NULL, NULL, &adapter, &handshake);
    if (ffi) {
        if (error) *error = BTFFIError(ffi,
            @"tunnel_create_rppairing (is LocalDevVPN active?)");
        return nil;
    }
    session.adapter = adapter;
    session.handshake = handshake;

    AfcClientHandle *afc = NULL;
    ffi = afc_client_connect_rsd(adapter, handshake, &afc);
    if (ffi) {
        if (error) *error = BTFFIError(ffi, @"afc_client_connect_rsd");
        return nil;
    }
    session.afc = afc;
    return session;
}

static BOOL BTReadRemoteFile(AfcClientHandle *afc, NSString *remote,
                             NSString *local, BOOL required, NSString **error)
{
    AfcFileHandle *file = NULL;
    IdeviceFfiError *ffi = afc_file_open(afc, remote.fileSystemRepresentation,
                                         AfcRdOnly, &file);
    if (ffi) {
        NSString *detail = BTFFIError(ffi, [@"afc open " stringByAppendingString:remote]);
        if (required && error) *error = detail;
        return NO;
    }

    uint8_t *bytes = NULL;
    size_t length = 0;
    ffi = afc_file_read_entire(file, &bytes, &length);
    IdeviceFfiError *closeError = afc_file_close(file);
    if (closeError) idevice_error_free(closeError);
    if (ffi) {
        NSString *detail = BTFFIError(ffi, [@"afc read " stringByAppendingString:remote]);
        if (required && error) *error = detail;
        return NO;
    }

    NSData *data = [NSData dataWithBytes:bytes length:length];
    afc_file_read_data_free(bytes, length);
    BOOL wrote = [data writeToFile:local atomically:YES];
    if (!wrote && required && error)
        *error = [NSString stringWithFormat:@"could not write library snapshot %@", local];
    return wrote;
}

static BOOL BTRemoteFileExists(AfcClientHandle *afc, NSString *remote)
{
    AfcFileHandle *file = NULL;
    IdeviceFfiError *ffi = afc_file_open(afc, remote.fileSystemRepresentation,
                                         AfcRdOnly, &file);
    if (ffi) { idevice_error_free(ffi); return NO; }
    IdeviceFfiError *closeError = afc_file_close(file);
    if (closeError) idevice_error_free(closeError);
    return YES;
}

static NSString *BTStringColumn(sqlite3_stmt *statement, int column)
{
    const unsigned char *raw = sqlite3_column_text(statement, column);
    return raw ? [NSString stringWithUTF8String:(const char *)raw] : @"";
}

static NSString *BTNormalizeRemoteMusicPath(NSString *location)
{
    if (!location.length) return nil;
    NSString *path = [location stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([path hasPrefix:@"/iTunes_Control/Music/"]) return path;
    while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    if ([path hasPrefix:@"iTunes_Control/Music/"])
        return [@"/" stringByAppendingString:path];
    return [@"/iTunes_Control/Music" stringByAppendingPathComponent:path];
}

static NSString *BTLibrarySnapshotDirectory(void)
{
    NSString *directory = [BTDocumentsDirectory()
        stringByAppendingPathComponent:@".ByeTunesLibrarySnapshot"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil error:nil];
    return directory;
}

NSArray<NSDictionary *> *BTMusicLoadLibrary(NSString **error)
{
    NSString *detail = nil;
    BTMusicSession *session = BTConnect(&detail);
    if (!session) {
        if (error) *error = detail;
        return nil;
    }

    NSString *snapshot = BTLibrarySnapshotDirectory();
    NSString *dbPath = [snapshot stringByAppendingPathComponent:@"MediaLibrary.sqlitedb"];
    NSString *walPath = [dbPath stringByAppendingString:@"-wal"];
    NSString *shmPath = [dbPath stringByAppendingString:@"-shm"];
    [NSFileManager.defaultManager removeItemAtPath:dbPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:walPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:shmPath error:nil];

    if (!BTReadRemoteFile(session.afc, BTLibraryRemotePath, dbPath, YES, &detail)) {
        if (error) *error = detail;
        return nil;
    }
    BTReadRemoteFile(session.afc, [BTLibraryRemotePath stringByAppendingString:@"-wal"],
                     walPath, NO, NULL);
    BTReadRemoteFile(session.afc, [BTLibraryRemotePath stringByAppendingString:@"-shm"],
                     shmPath, NO, NULL);

    sqlite3 *database = NULL;
    int openResult = sqlite3_open_v2(dbPath.fileSystemRepresentation, &database,
                                     SQLITE_OPEN_READONLY, NULL);
    if (openResult != SQLITE_OK) {
        if (error) *error = [NSString stringWithFormat:@"sqlite open failed: %s",
            database ? sqlite3_errmsg(database) : "unknown"];
        if (database) sqlite3_close(database);
        return nil;
    }

    const char *sql =
        "SELECT i.item_pid, ie.location, ie.title, "
        "IFNULL(ia.item_artist,''), IFNULL(al.album,''), IFNULL(ge.genre,''), "
        "IFNULL(ie.year,0), CAST(IFNULL(ie.total_time_ms,0) AS INTEGER), "
        "IFNULL(ie.file_size,0), IFNULL(i.track_number,0), IFNULL(ie.content_rating,0) "
        "FROM item i "
        "JOIN item_extra ie ON ie.item_pid = i.item_pid "
        "LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid "
        "LEFT JOIN album al ON al.album_pid = i.album_pid "
        "LEFT JOIN genre ge ON ge.genre_id = i.genre_id "
        "WHERE ie.location != '' AND i.media_type = 8";

    sqlite3_stmt *statement = NULL;
    int prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, NULL);
    if (prepareResult != SQLITE_OK) {
        if (error) *error = [NSString stringWithFormat:@"music query failed: %s",
            sqlite3_errmsg(database)];
        sqlite3_close(database);
        return nil;
    }

    NSMutableArray<NSDictionary *> *songs = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSString *location = BTStringColumn(statement, 1);
        NSString *remotePath = BTNormalizeRemoteMusicPath(location);
        if (!remotePath.length || !BTRemoteFileExists(session.afc, remotePath)) continue;

        long long persistentID = sqlite3_column_int64(statement, 0);
        NSString *title = BTStringColumn(statement, 2);
        if (!title.length) title = remotePath.lastPathComponent.stringByDeletingPathExtension;
        NSDictionary *song = @{
            @"PersistentID": @(persistentID),
            @"Location": location ?: @"",
            @"RemotePath": remotePath,
            @"Title": title ?: @"",
            @"Artist": BTStringColumn(statement, 3) ?: @"",
            @"Album": BTStringColumn(statement, 4) ?: @"",
            @"Genre": BTStringColumn(statement, 5) ?: @"",
            @"Year": @(sqlite3_column_int(statement, 6)),
            @"DurationMS": @(sqlite3_column_int64(statement, 7)),
            @"FileSize": @(sqlite3_column_int64(statement, 8)),
            @"TrackNumber": @(sqlite3_column_int(statement, 9)),
            @"ContentRating": @(sqlite3_column_int(statement, 10)),
        };
        [songs addObject:song];
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);

    [songs sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult artist = [left[@"Artist"] localizedCaseInsensitiveCompare:right[@"Artist"]];
        if (artist != NSOrderedSame) return artist;
        return [left[@"Title"] localizedCaseInsensitiveCompare:right[@"Title"]];
    }];
    NSLog(@"[ByeTunesBridge] loaded %lu AFC-backed songs", (unsigned long)songs.count);
    return songs;
}

static NSString *BTMusicCacheDirectory(void)
{
    NSString *directory = [BTDocumentsDirectory()
        stringByAppendingPathComponent:@"Device Storage/[ByeTunes] Music Cache"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:@{NSFilePosixPermissions: @0700}
                                                   error:nil];
    return directory;
}

static BOOL BTStreamRemoteFile(AfcClientHandle *afc, NSString *remote,
                               NSString *local, NSString **error)
{
    AfcFileHandle *source = NULL;
    IdeviceFfiError *ffi = afc_file_open(afc, remote.fileSystemRepresentation,
                                         AfcRdOnly, &source);
    if (ffi) {
        if (error) *error = BTFFIError(ffi, [@"afc open " stringByAppendingString:remote]);
        return NO;
    }

    int destination = open(local.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (destination < 0) {
        IdeviceFfiError *closeError = afc_file_close(source);
        if (closeError) idevice_error_free(closeError);
        if (error) *error = [NSString stringWithFormat:@"cache open failed errno=%d", errno];
        return NO;
    }

    BOOL success = YES;
    while (success) {
        uint8_t *chunk = NULL;
        size_t count = 0;
        ffi = afc_file_read(source, &chunk, 256 * 1024, &count);
        if (ffi) {
            if (error) *error = BTFFIError(ffi, @"afc_file_read");
            success = NO;
        } else if (count == 0) {
            break;
        } else {
            size_t offset = 0;
            while (offset < count) {
                ssize_t written = write(destination, chunk + offset, count - offset);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) {
                    if (error) *error = [NSString stringWithFormat:@"cache write failed errno=%d", errno];
                    success = NO;
                    break;
                }
                offset += (size_t)written;
            }
            afc_file_read_data_free(chunk, count);
        }
    }
    if (success) fsync(destination);
    close(destination);
    IdeviceFfiError *closeError = afc_file_close(source);
    if (closeError) idevice_error_free(closeError);
    if (!success) unlink(local.fileSystemRepresentation);
    return success;
}

NSString *BTMusicEnsureLocalFile(NSDictionary *song, NSString **error)
{
    NSString *remote = [song[@"RemotePath"] isKindOfClass:NSString.class]
        ? song[@"RemotePath"] : nil;
    if (!remote.length) {
        if (error) *error = @"song has no AFC remote path";
        return nil;
    }

    NSString *extension = remote.pathExtension.length ? remote.pathExtension : @"m4a";
    NSString *identifier = [song[@"PersistentID"] stringValue] ?: NSUUID.UUID.UUIDString;
    NSString *local = [[BTMusicCacheDirectory()
        stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:extension];
    NSNumber *expectedSize = [song[@"FileSize"] isKindOfClass:NSNumber.class]
        ? song[@"FileSize"] : nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:local error:nil];
    if (attributes && (!expectedSize || expectedSize.longLongValue <= 0 ||
        attributes.fileSize == expectedSize.unsignedLongLongValue)) return local;

    NSString *detail = nil;
    BTMusicSession *session = BTConnect(&detail);
    if (!session) {
        if (error) *error = detail;
        return nil;
    }
    NSString *temporary = [local stringByAppendingString:@".partial"];
    unlink(temporary.fileSystemRepresentation);
    if (!BTStreamRemoteFile(session.afc, remote, temporary, &detail)) {
        if (error) *error = detail;
        return nil;
    }
    unlink(local.fileSystemRepresentation);
    if (rename(temporary.fileSystemRepresentation, local.fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = [NSString stringWithFormat:@"cache rename failed errno=%d", errno];
        return nil;
    }
    return local;
}
