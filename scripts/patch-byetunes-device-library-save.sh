#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
test -f "$DEVICE"

python3 - "$DEVICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# Upstream v2.4's normal sync helper only starts notification_proxy and never
# posts anything. Use the same concrete notification sequence that upstream's
# ringtone refresh path already uses so Music/media-library clients get an
# actual sync lifecycle signal after a database replacement.
old_sync = '''    func sendSyncFinishedNotification() {
        var lockdownd: LockdowndClientHandle?
        let err = connectLockdownClient(&lockdownd)
        
        if err == IdeviceSuccess {
            var port: UInt16 = 0
            var ssl: Bool = false
            _ = lockdownd_start_service(lockdownd, "com.apple.mobile.notification_proxy", &port, &ssl)
            lockdownd_client_free(lockdownd)
        }
    }
'''
new_sync = '''    func sendSyncFinishedNotification() {
        var npClient: NotificationProxyClientHandle?
        let npErr = connectNotificationProxyClient(&npClient)
        guard npErr == IdeviceSuccess, let npClient else {
            Logger.shared.log("[SyncNotify] Failed to connect notification_proxy")
            return
        }
        defer { notification_proxy_client_free(npClient) }

        let notifications = [
            "com.apple.itunes-mobdev.syncWillStart",
            "com.apple.itunes-mobdev.syncLockRequest",
            "com.apple.itunes-mobdev.syncDidStart",
            "com.apple.itunes-mobdev.syncDidFinish"
        ]

        for name in notifications {
            let result = name.withCString { cName in
                notification_proxy_post(npClient, cName)
            }
            if result == IdeviceSuccess {
                Logger.shared.log("[SyncNotify] Posted \\(name)")
            } else {
                Logger.shared.log("[SyncNotify] Failed posting \\(name)")
            }
        }
    }
'''
text = replace_once(text, old_sync, new_sync, "real sync notification implementation")


# Make database activation observable in logs. The previous code returned a
# boolean from the rename path without ever logging a successful temp->live
# promotion, which made a successful upload indistinguishable from persistence.
old_commit_tail = '''        return replaceRemoteMediaLibrary(tempDBPath: tempDBPath, afc: afc, logContext: "[DeviceManager]")
    }

    private func replaceRemoteMediaLibrary(
'''
new_commit_tail = '''        let activated = replaceRemoteMediaLibrary(tempDBPath: tempDBPath, afc: afc, logContext: "[DeviceManager]")
        Logger.shared.log("[DeviceLibrarySave] staged database activation=\\(activated)")
        return activated
    }

    private func verifyExportableSongMetadataReadback(
        original: ExportableSongInfo,
        title expectedTitle: String,
        artist expectedArtist: String,
        album expectedAlbum: String,
        genre expectedGenre: String,
        year expectedYear: Int,
        trackNumber expectedTrackNumber: Int,
        explicitRating expectedExplicitRating: Int
    ) -> Bool {
        let semDb = DispatchSemaphore(value: 0)
        var dbData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            dbData = data
            semDb.signal()
        }
        semDb.wait()

        let semWal = DispatchSemaphore(value: 0)
        var walData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            walData = data
            semWal.signal()
        }
        semWal.wait()

        let semShm = DispatchSemaphore(value: 0)
        var shmData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            shmData = data
            semShm.signal()
        }
        semShm.wait()

        let verified: Bool? = self.withStagedMediaLibrary(
            dbData: dbData,
            walData: walData,
            shmData: shmData,
            label: "metadata_save_verify"
        ) { dbURL in
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                return false
            }
            defer { sqlite3_close(db) }

            let itemPid = original.itemPid > 0
                ? original.itemPid
                : (self.itemPid(forRemoteFilename: original.remoteFilename, db: db) ?? 0)
            guard itemPid > 0 else { return false }

            let sql = """
            SELECT ie.title,
                   ia.item_artist,
                   a.album,
                   g.genre,
                   ie.year,
                   i.track_number,
                   ie.content_rating
            FROM item i
            JOIN item_extra ie ON ie.item_pid = i.item_pid
            LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid
            LEFT JOIN album a ON a.album_pid = i.album_pid
            LEFT JOIN genre g ON g.genre_id = i.genre_id
            WHERE i.item_pid = \\(itemPid)
            LIMIT 1
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if stmt != nil { sqlite3_finalize(stmt) }
                return false
            }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }

            func stringColumn(_ index: Int32) -> String {
                guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
                return String(cString: ptr)
            }

            let actualTitle = stringColumn(0)
            let actualArtist = stringColumn(1)
            let actualAlbum = stringColumn(2)
            let actualGenre = stringColumn(3)
            let actualYear = Int(sqlite3_column_int(stmt, 4))
            let actualTrackNumber = Int(sqlite3_column_int(stmt, 5))
            let actualExplicitRating = Int(sqlite3_column_int(stmt, 6))

            let matches =
                actualTitle == expectedTitle &&
                actualArtist == expectedArtist &&
                actualAlbum == expectedAlbum &&
                actualGenre == expectedGenre &&
                actualYear == expectedYear &&
                actualTrackNumber == expectedTrackNumber &&
                actualExplicitRating == expectedExplicitRating

            if !matches {
                Logger.shared.log(
                    "[DeviceLibrarySave] readback mismatch " +
                    "expected={title=\\(expectedTitle),artist=\\(expectedArtist),album=\\(expectedAlbum),genre=\\(expectedGenre),year=\\(expectedYear),track=\\(expectedTrackNumber),rating=\\(expectedExplicitRating)} " +
                    "actual={title=\\(actualTitle),artist=\\(actualArtist),album=\\(actualAlbum),genre=\\(actualGenre),year=\\(actualYear),track=\\(actualTrackNumber),rating=\\(actualExplicitRating)}"
                )
            }

            return matches
        }

        return verified ?? false
    }

    private func replaceRemoteMediaLibrary(
'''
text = replace_once(text, old_commit_tail, new_commit_tail, "database activation logging and metadata verifier")


# Upstream v2.4 reports success immediately after upload/swap. That is unsafe
# when Music is still alive (your device logs show AppService termination can
# fail) because a live WAL/cache can race the replacement. Notify, read back the
# exact effective row, and retry the same staged DB once after another kill
# attempt if the first activation did not persist.
old_update_tail = '''            guard self.commitStagedMediaLibrary(localDbURL: context.dbURL) else {
                completion(false, "Failed to upload the updated device library.")
                return
            }

            completion(true, "Updated metadata for \\(safeTitle).")
'''
new_update_tail = '''            guard self.commitStagedMediaLibrary(localDbURL: context.dbURL) else {
                completion(false, "Failed to upload the updated device library.")
                return
            }

            self.sendSyncFinishedNotification()
            Thread.sleep(forTimeInterval: 0.45)

            var persisted = self.verifyExportableSongMetadataReadback(
                original: original,
                title: safeTitle,
                artist: safeArtist,
                album: safeAlbum,
                genre: safeGenre,
                year: year,
                trackNumber: trackNumber,
                explicitRating: explicitRating
            )

            if !persisted {
                Logger.shared.log("[DeviceLibrarySave] first post-swap verification failed; retrying after Music termination attempt")
                let retryKilled = self.terminateMusicAppIfRunning()
                Logger.shared.log("[SyncLifecycle] Music retry kill \\(retryKilled ? "completed" : "skipped/failed")")

                guard self.commitStagedMediaLibrary(localDbURL: context.dbURL) else {
                    completion(false, "Metadata database retry upload failed.")
                    return
                }

                self.sendSyncFinishedNotification()
                Thread.sleep(forTimeInterval: 0.60)
                persisted = self.verifyExportableSongMetadataReadback(
                    original: original,
                    title: safeTitle,
                    artist: safeArtist,
                    album: safeAlbum,
                    genre: safeGenre,
                    year: year,
                    trackNumber: trackNumber,
                    explicitRating: explicitRating
                )
            }

            guard persisted else {
                Logger.shared.log("[DeviceLibrarySave] ERROR: edited metadata did not survive device readback")
                completion(false, "The edit was written but did not persist in Apple Music. Close Music and retry.")
                return
            }

            Logger.shared.log("[DeviceLibrarySave] VERIFIED persisted metadata for itemPid=\\(itemPid) title=\\(safeTitle)")
            completion(true, "Saved and verified metadata for \\(safeTitle).")
'''
text = replace_once(text, old_update_tail, new_update_tail, "metadata save readback/retry")


required = [
    '[SyncNotify] Posted',
    '[DeviceLibrarySave] staged database activation=',
    'verifyExportableSongMetadataReadback',
    '[DeviceLibrarySave] VERIFIED persisted metadata',
    'Saved and verified metadata for',
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"missing patched marker: {marker}")

path.write_text(text)
PY

grep -Fq '[DeviceLibrarySave] VERIFIED persisted metadata' "$DEVICE"
grep -Fq '[SyncNotify] Posted' "$DEVICE"
echo "Applied ByeTunes on-device metadata persistence fix"
