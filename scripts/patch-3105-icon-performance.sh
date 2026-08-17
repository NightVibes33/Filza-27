#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105/Sources"
BROWSER="$ROOT/AppDataBrowserView.swift"
ICON="$ROOT/AppIconHelper.m"

for path in "$BROWSER" "$ICON" "$ROOT/FilzaSharedPairingSupport.swift"; do
  test -f "$path" || { echo "Missing 3105 icon integration file: $path" >&2; exit 1; }
done

python3 - "$BROWSER" "$ICON" <<'PY'
from pathlib import Path
import sys

browser_path = Path(sys.argv[1])
icon_path = Path(sys.argv[2])

browser = browser_path.read_text(encoding="utf-8")
old_loader = '''            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.resolvedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
'''
new_loader = '''            // Paint the existing LaunchServices icon immediately so the
            // list never waits on the paired SpringBoard service.
            if resolvedIcon == nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    let fallbackIcon = iconForBundleID(bundleID)
                    guard let fallbackIcon else { return }
                    DispatchQueue.main.async {
                        if resolvedIcon == nil {
                            resolvedIcon = fallbackIcon
                        }
                    }
                }
            }

            // Upgrade the row asynchronously when SpringBoardServices returns
            // the rendered icon. Visible rows naturally request first.
            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.enhancedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
'''
if old_loader not in browser:
    raise SystemExit("3105 enhanced icon loader anchor changed")
browser = browser.replace(old_loader, new_loader, 1)
browser_path.write_text(browser, encoding="utf-8")

icon = icon_path.read_text(encoding="utf-8")
marker = "\n#pragma mark - Filza shared paired SpringBoard icon service\n"
if marker not in icon:
    raise SystemExit("3105 SpringBoard bridge marker missing")
prefix = icon.split(marker, 1)[0].rstrip() + "\n"

bridge = r'''

#pragma mark - Filza shared paired SpringBoard icon service

#include <pthread.h>

#define FILZA_SBS_ICON_WORKERS 3

typedef struct {
    struct SpringBoardServicesClientHandle *client;
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *handshake;
} FilzaRSDIconSlot;

typedef struct {
    struct SpringBoardServicesClientHandle *client;
    struct IdeviceProviderHandle *provider;
} FilzaProviderIconSlot;

static FilzaRSDIconSlot gFilzaRSDIconSlots[FILZA_SBS_ICON_WORKERS];
static FilzaProviderIconSlot gFilzaProviderIconSlots[FILZA_SBS_ICON_WORKERS];
static pthread_mutex_t gFilzaRSDIconLocks[FILZA_SBS_ICON_WORKERS] = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_MUTEX_INITIALIZER,
};
static pthread_mutex_t gFilzaProviderIconLocks[FILZA_SBS_ICON_WORKERS] = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_MUTEX_INITIALIZER,
};

static NSUInteger FilzaSpringBoardWorkerIndex(NSString *bundleID) {
    if (bundleID.length == 0) return 0;
    return bundleID.hash % FILZA_SBS_ICON_WORKERS;
}

static UIImage *FilzaSpringBoardImageFromClient(
    struct SpringBoardServicesClientHandle *client,
    NSString *bundleID,
    BOOL *serviceError
) {
    if (serviceError) *serviceError = NO;
    if (!client || bundleID.length == 0) return nil;

    void *pngData = NULL;
    size_t dataLen = 0;
    struct IdeviceFfiError *error = springboard_services_get_icon(
        client,
        bundleID.UTF8String,
        &pngData,
        &dataLen
    );
    if (error) {
        const char *message = error->message ? error->message : "unknown error";
        NSLog(@"[Filza3105Icons] SpringBoard icon failed for %@: %s", bundleID, message);
        if (serviceError) *serviceError = YES;
        idevice_error_free(error);
        if (pngData) idevice_data_free((uint8_t *)pngData, dataLen);
        return nil;
    }

    if (!pngData || dataLen == 0) {
        if (pngData) idevice_data_free((uint8_t *)pngData, dataLen);
        NSLog(@"[Filza3105Icons] SpringBoard has no rendered icon bytes for %@", bundleID);
        return nil;
    }

    NSData *data = [NSData dataWithBytes:pngData length:dataLen];
    idevice_data_free((uint8_t *)pngData, dataLen);
    UIImage *image = [UIImage imageWithData:data];
    if (!image) {
        NSLog(@"[Filza3105Icons] SpringBoard returned %zu undecodable bytes for %@", dataLen, bundleID);
    }
    return image;
}

static void FilzaInvalidateRSDIconClientLocked(NSUInteger index) {
    FilzaRSDIconSlot *slot = &gFilzaRSDIconSlots[index];
    if (slot->client) {
        springboard_services_free(slot->client);
        slot->client = NULL;
    }
}

static void FilzaInvalidateProviderIconClientLocked(NSUInteger index) {
    FilzaProviderIconSlot *slot = &gFilzaProviderIconSlots[index];
    if (slot->client) {
        springboard_services_free(slot->client);
        slot->client = NULL;
    }
}

static struct SpringBoardServicesClientHandle *FilzaEnsureRSDIconClientLocked(
    NSUInteger index,
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake
) {
    FilzaRSDIconSlot *slot = &gFilzaRSDIconSlots[index];

    if (slot->adapter != adapter || slot->handshake != handshake) {
        FilzaInvalidateRSDIconClientLocked(index);
        slot->adapter = adapter;
        slot->handshake = handshake;
    }

    if (slot->client) return slot->client;

    struct SpringBoardServicesClientHandle *client = NULL;
    struct IdeviceFfiError *error = springboard_services_connect_rsd(
        adapter,
        handshake,
        &client
    );
    if (error) {
        const char *message = error->message ? error->message : "unknown error";
        NSLog(@"[Filza3105Icons] SpringBoardServices RSD connect failed on worker %lu: %s",
              (unsigned long)index,
              message);
        idevice_error_free(error);
        return NULL;
    }

    slot->client = client;
    return slot->client;
}

static struct SpringBoardServicesClientHandle *FilzaEnsureProviderIconClientLocked(
    NSUInteger index,
    struct IdeviceProviderHandle *provider
) {
    FilzaProviderIconSlot *slot = &gFilzaProviderIconSlots[index];

    if (slot->provider != provider) {
        FilzaInvalidateProviderIconClientLocked(index);
        slot->provider = provider;
    }

    if (slot->client) return slot->client;

    struct SpringBoardServicesClientHandle *client = NULL;
    struct IdeviceFfiError *error = springboard_services_connect(provider, &client);
    if (error) {
        const char *message = error->message ? error->message : "unknown error";
        NSLog(@"[Filza3105Icons] SpringBoardServices provider connect failed on worker %lu: %s",
              (unsigned long)index,
              message);
        idevice_error_free(error);
        return NULL;
    }

    slot->client = client;
    return slot->client;
}

UIImage *filzaSpringBoardIconForBundleIDRSD(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    NSString *bundleID
) {
    if (!adapter || !handshake || bundleID.length == 0) return nil;

    NSUInteger index = FilzaSpringBoardWorkerIndex(bundleID);
    pthread_mutex_lock(&gFilzaRSDIconLocks[index]);

    UIImage *image = nil;
    for (NSUInteger attempt = 0; attempt < 2 && !image; attempt++) {
        struct SpringBoardServicesClientHandle *client = FilzaEnsureRSDIconClientLocked(
            index,
            adapter,
            handshake
        );
        if (!client) continue;

        BOOL serviceError = NO;
        image = FilzaSpringBoardImageFromClient(client, bundleID, &serviceError);
        if (!image && serviceError) {
            // A stale RSD service is common after VPN/tunnel churn. Drop only
            // this worker's client and reconnect once; other workers continue.
            FilzaInvalidateRSDIconClientLocked(index);
        } else {
            break;
        }
    }

    pthread_mutex_unlock(&gFilzaRSDIconLocks[index]);
    return image;
}

UIImage *filzaSpringBoardIconForBundleIDProvider(
    struct IdeviceProviderHandle *provider,
    NSString *bundleID
) {
    if (!provider || bundleID.length == 0) return nil;

    NSUInteger index = FilzaSpringBoardWorkerIndex(bundleID);
    pthread_mutex_lock(&gFilzaProviderIconLocks[index]);

    UIImage *image = nil;
    for (NSUInteger attempt = 0; attempt < 2 && !image; attempt++) {
        struct SpringBoardServicesClientHandle *client = FilzaEnsureProviderIconClientLocked(
            index,
            provider
        );
        if (!client) continue;

        BOOL serviceError = NO;
        image = FilzaSpringBoardImageFromClient(client, bundleID, &serviceError);
        if (!image && serviceError) {
            FilzaInvalidateProviderIconClientLocked(index);
        } else {
            break;
        }
    }

    pthread_mutex_unlock(&gFilzaProviderIconLocks[index]);
    return image;
}
'''

icon_path.write_text(prefix + bridge, encoding="utf-8")
PY

grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' "$BROWSER"
grep -Fq 'fallbackIcon = iconForBundleID' "$BROWSER"
grep -Fq 'FILZA_SBS_ICON_WORKERS 3' "$ICON"
grep -Fq 'FilzaEnsureRSDIconClientLocked' "$ICON"
grep -Fq 'FilzaInvalidateRSDIconClientLocked' "$ICON"
grep -Fq 'for (NSUInteger attempt = 0; attempt < 2 && !image; attempt++)' "$ICON"

echo "Optimized 3105 icon path: immediate LS paint + 3 persistent SpringBoard workers + reconnect retry"
