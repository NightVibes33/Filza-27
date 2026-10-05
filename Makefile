# Filza 27 ships one modern runtime. Mond 2.2, 3105, ByeTunes, WebDAV and SSH
# are compiled together for iOS 17.0+; no iOS 16 compatibility transform is applied.
TARGET := iphone:clang:latest:17.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt
IDEVICE_VENDOR ?= $(PWD)/Vendor/idevice
IDEVICE_STATIC := $(IDEVICE_VENDOR)/lib/libidevice_ffi.a
NFCARD_ROOT := ThirdParty/NFCARD
NFCARD_IOS := $(NFCARD_ROOT)/ios-app
NFCARD_FFI := $(NFCARD_ROOT)/AirliftFFI
BYETUNES_ROOT := ByeTunes/MusicManager
BYETUNES_ACTIVITY_SHARED := ByeTunes/MusicManagerActivityShared/DownloadLiveActivityAttributes.swift
BAD_QUERY_ROOT := ThirdParty/bad_query
GCDWEBSERVER_ROOT := ThirdParty/GCDWebServer
THREEONE_ROOT := ThirdParty/3105
MOND_CURRENT_ROOT := ThirdParty/mond-current
MOND_GEN := $(MOND_CURRENT_ROOT)/Generated

FilzaApplySandboxExt_FILES = Tweak.m FilzaNFCARDBridge.m AppsMusicFix.m AppsManagerPresentationFix.m AppProxyMetadataFix.m AppMetadataRetryFix.m AppIconResourceProxyFix.m VirtualBackendFix.m SystemPathDiagnostics.m BadQuerySystemProbe.m GestaltManager.m FilzaMondBridge.m FilzaMainToolbarGestalt.m Filza3105Bridge.m Filza3105IPAExportBridge.m ByeTunesMusicBridge.m ByeTunesFilzaLibraryEmbed.m ByeTunesFullAppLauncher.m FilzaDiagnostics.m FilzaQuickActions.m WebDAVRuntimeFix.m WebDAVToggleStateFix.m ArchiveSafety.m ArchiveCreationSafety.m RuntimeStability.m CompatibilityDiagnostics.m CVE43724RieCompatibility.m MCMBridge.m MCMFilzaIntegration.m PosterBoardFeature.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/AppIconHelper.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/wallpaper_zip.c
FilzaApplySandboxExt_FILES += $(BAD_QUERY_ROOT)/bad_query/bad_query.c
FilzaApplySandboxExt_FILES += $(MOND_GEN)/mond_bad_query.c
FilzaApplySandboxExt_FILES += $(NFCARD_IOS)/GrappaHelper.m

GCDWEBSERVER_OBJC_FILES := $(shell find $(GCDWEBSERVER_ROOT)/GCDWebServer $(GCDWEBSERVER_ROOT)/GCDWebDAVServer -type f -name '*.m' -print)
FilzaApplySandboxExt_FILES += $(GCDWEBSERVER_OBJC_FILES)

FilzaApplySandboxExt_FILES += sandbox_escape.m apfs_own.m
FilzaApplySandboxExt_FILES += kexploit/kexploit_opa334.m kexploit/krw.m kexploit/kutils.m kexploit/offsets.m kexploit/vnode.m
FilzaApplySandboxExt_FILES += utils/file.c utils/hexdump.c utils/process.c
FilzaApplySandboxExt_FILES += kpf/patchfinder.m
FilzaApplySandboxExt_FILES += XPF/src/xpf.c XPF/src/common.c XPF/src/decompress.c XPF/src/bad_recovery.c XPF/src/non_ppl.c XPF/src/ppl.c
FilzaApplySandboxExt_FILES += XPF/external/ChOma/src/arm64.c XPF/external/ChOma/src/Base64.c XPF/external/ChOma/src/BufferedStream.c XPF/external/ChOma/src/CodeDirectory.c XPF/external/ChOma/src/CSBlob.c XPF/external/ChOma/src/DER.c XPF/external/ChOma/src/DyldSharedCache.c XPF/external/ChOma/src/Entitlements.c XPF/external/ChOma/src/Fat.c XPF/external/ChOma/src/FileStream.c XPF/external/ChOma/src/Host.c XPF/external/ChOma/src/MachO.c XPF/external/ChOma/src/MachOLoadCommand.c XPF/external/ChOma/src/MemoryStream.c XPF/external/ChOma/src/PatchFinder.c XPF/external/ChOma/src/Util.c

# Full ByeTunes v2.4 source tree, with the old provider state machine restored
# by explicit build-time parity patches. MusicManagerApp.swift is omitted
# because Filza already owns UIApplication lifecycle.
BYETUNES_SWIFT_FILES := $(shell find $(BYETUNES_ROOT) -type f -name '*.swift' ! -name 'MusicManagerApp.swift' ! -name 'SplashView.swift' -print)

NFCARD_SWIFT_FILES := \
    $(NFCARD_IOS)/AppViewModel.swift \
    $(NFCARD_IOS)/NFCARDContentView.swift \
    $(NFCARD_IOS)/Models.swift \
    $(NFCARD_IOS)/NetworkStatus.swift \
    $(NFCARD_IOS)/PairingController.swift \
    $(NFCARD_IOS)/Utilities.swift \
    $(NFCARD_IOS)/RespringHelper.swift \
    $(NFCARD_IOS)/TendiesEngine.swift \
    $(NFCARD_IOS)/TendiesModel.swift \
    $(NFCARD_IOS)/TendiesView.swift \
    $(NFCARD_IOS)/AirCardLibrary.swift \
    $(NFCARD_IOS)/RemotePairingPortDiscovery.swift \
    $(NFCARD_IOS)/NFCARDNativeShell.swift

# stage-3105-v1.sh now stages immutable upstream 3105 1.1.1 directly while
# preserving only Filza lifecycle/pairing/presentation adapters.
THREEONE_SWIFT_FILES := $(shell find $(THREEONE_ROOT)/Sources -type f -name '*.swift' -print)

# Mond 2.2 is staged as the exact current upstream tree, then mechanically
# namespaced so it can coexist in Filza's Swift module. The legacy generated
# filenames remain stable so the existing source graph does not regress when
# upstream moves files.
MOND_SWIFT_FILES := \
    $(MOND_GEN)/Mond/exploit_cmg.swift \
    $(MOND_GEN)/Mond/exploit_unsbx.swift \
    $(MOND_GEN)/Mond/helpers_keepalive.swift \
    $(MOND_GEN)/Mond/helpers_mg.swift \
    $(MOND_GEN)/Mond/helpers_posterboard_poster.swift \
    $(MOND_GEN)/Mond/helpers_posterboard_tendies.swift \
    $(MOND_GEN)/Mond/helpers_sbx.swift \
    $(MOND_GEN)/Mond/helpers_utils.swift \
    $(MOND_GEN)/Mond/views_app_ContentView.swift \
    $(MOND_GEN)/Mond/views_app_LogView.swift \
    $(MOND_GEN)/Mond/views_app_SettingsView.swift \
    $(MOND_GEN)/Mond/views_tweaks_GestaltView.swift \
    $(MOND_GEN)/Mond/views_tweaks_SantanderView.swift \
    $(MOND_GEN)/Mond/views_tweaks_posterboard_PosterView.swift \
    $(MOND_GEN)/Mond/views_tweaks_posterboard_TendiesView.swift

MOND_PARTYUI_SWIFT_FILES := \
    $(MOND_GEN)/PartyUI/Containers_TerminalPlatter.swift \
    $(MOND_GEN)/PartyUI/Alerts_PlainAlert.swift \
    $(MOND_GEN)/PartyUI/Toggles_PlainToggle.swift \
    $(MOND_GEN)/PartyUI/Toggles_PlatterToggle.swift \
    $(MOND_GEN)/PartyUI/Utilities_Alertinator.swift \
    $(MOND_GEN)/PartyUI/Utilities_Helpers.swift \
    $(MOND_GEN)/PartyUI/Buttons_TranslucentButtonStyle.swift

MOND_ZIP_SWIFT_FILES := \
    $(MOND_GEN)/ZIPFoundation/Archive+BackingConfiguration.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+Deprecated.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+Helpers.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+MemoryFile.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+Progress.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+Reading.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+ReadingDeprecated.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+Writing.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+WritingDeprecated.swift \
    $(MOND_GEN)/ZIPFoundation/Archive+ZIP64.swift \
    $(MOND_GEN)/ZIPFoundation/Archive.swift \
    $(MOND_GEN)/ZIPFoundation/Data+Compression.swift \
    $(MOND_GEN)/ZIPFoundation/Data+CompressionDeprecated.swift \
    $(MOND_GEN)/ZIPFoundation/Data+Serialization.swift \
    $(MOND_GEN)/ZIPFoundation/Date+ZIP.swift \
    $(MOND_GEN)/ZIPFoundation/Entry+Serialization.swift \
    $(MOND_GEN)/ZIPFoundation/Entry+ZIP64.swift \
    $(MOND_GEN)/ZIPFoundation/Entry.swift \
    $(MOND_GEN)/ZIPFoundation/FileManager+ZIP.swift \
    $(MOND_GEN)/ZIPFoundation/FileManager+ZIPDeprecated.swift \
    $(MOND_GEN)/ZIPFoundation/URL+ZIP.swift

FilzaApplySandboxExt_SWIFT_FILES = FilzaNFCARDHost.swift $(NFCARD_SWIFT_FILES) ByeTunesEmbeddedHost.swift AppleMusicSyncedLyrics.swift ByeTunesRemotePairingPortDiscovery.swift ByeTunesOnDevicePairing.swift ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift FilzaMondCurrentHost.swift Filza3105Host.swift $(MOND_SWIFT_FILES) $(MOND_PARTYUI_SWIFT_FILES) $(MOND_ZIP_SWIFT_FILES) $(THREEONE_SWIFT_FILES) $(BYETUNES_SWIFT_FILES) $(BYETUNES_ACTIVITY_SHARED)

FilzaApplySandboxExt_CFLAGS = -I$(PWD)/compat -I$(PWD) -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include -I$(IDEVICE_VENDOR)/include -I$(PWD)/$(BAD_QUERY_ROOT)/bad_query -I$(PWD)/$(THREEONE_ROOT)/Sources -I$(PWD)/$(MOND_GEN) \
    -I$(PWD)/$(NFCARD_IOS) -I$(PWD)/$(NFCARD_FFI)/include -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Core -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Requests -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Responses -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebDAVServer \
    -I$(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)/usr/include/libxml2 \
    -fobjc-arc -include errno.h -include math.h \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
    -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-deprecated-declarations -Wno-nonportable-include-path -Wno-format
FilzaApplySandboxExt_CFLAGS += -Wno-arc-performSelector-leaks
FilzaApplySandboxExt_CCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
# Build-only compiler allowance for ByeTunes' existing large SwiftUI expressions.
# This does not patch or alter Mond/ByeTunes runtime source or behavior.
FilzaApplySandboxExt_SWIFTFLAGS += -swift-version 5 -default-isolation MainActor -Xfrontend -solver-expression-time-threshold=300 -Xcc -I$(IDEVICE_VENDOR)/include -Xcc -I$(PWD)/$(MOND_GEN) -Xcc -I$(PWD)/$(NFCARD_FFI)/include
# NFCARD's Airlift static runtime already contains its pinned idevice-ffi
# implementation. Keep Filza's separate idevice build for headers/ABI checks,
# but link only the NFCARD runtime to avoid duplicate no_mangle symbols.
FilzaApplySandboxExt_LDFLAGS += $(NFCARD_FFI)/lib/libairlift_ffi.a -lc++

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation SwiftUI Combine AVFoundation AVKit CoreMedia AudioToolbox CryptoKit Security UniformTypeIdentifiers PhotosUI JavaScriptCore AppIntents ActivityKit SafariServices CFNetwork MobileCoreServices WebKit QuickLook ImageIO
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z xml2 sandbox sqlite3
FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

# Every transformation is explicit and ordered. No script may invoke another
# unrelated patch as a hidden side effect.
before-FilzaApplySandboxExt-all::
	@bash scripts/stage-mond-current.sh
	@bash scripts/stage-mond-22-overlay.sh
	@bash scripts/stage-3105-v1.sh
	@bash scripts/stage-nfcard.sh
	@bash scripts/build-nfcard-ffi.sh "$(NFCARD_ROOT)" "$(NFCARD_FFI)"
	@bash scripts/patch-3105-embedded-compat.sh
	@bash scripts/patch-access-map-provenance.sh
	@bash scripts/patch-byetunes-upstream-parity-v2.sh
	@bash scripts/restore-byetunes-v24-metadata-compat.sh
	@bash scripts/patch-byetunes-metadata-parity-post.sh
	@bash scripts/patch-byetunes-background-provider-parity.sh
	@bash scripts/patch-byetunes-download-provider-parity.sh
	@bash scripts/patch-byetunes-device-library-save.sh
	@bash scripts/patch-byetunes-public-metadata-stack.sh
	@bash scripts/patch-byetunes-apple-synced-lyrics.sh
	@bash scripts/patch-byetunes-rppairing-localdevvpn.sh
	@bash scripts/patch-byetunes-pairing-and-tabs.sh
	@test -s "$(IDEVICE_STATIC)" || (echo "Missing $(IDEVICE_STATIC). Run: bash scripts/build-idevice.sh" >&2; exit 1)
	@test -s "$(NFCARD_FFI)/lib/libairlift_ffi.a" || (echo "Missing NFCARD AirliftFFI runtime" >&2; exit 1)
	@grep -Fq 'al_pairing_run_host' "$(NFCARD_FFI)/include/AirliftFFI/airlift.h" || (echo "NFCARD pairing-host API missing" >&2; exit 1)
	@grep -Fq 'al_connection_endpoint_set' "$(NFCARD_FFI)/include/AirliftFFI/airlift.h" || (echo "NFCARD endpoint API missing" >&2; exit 1)
	@test -f "$(NFCARD_IOS)/NFCARDContentView.swift" || (echo "Missing staged NFCARD root" >&2; exit 1)
	@grep -Fq 'NFCARDPairingTab()' "$(NFCARD_IOS)/NFCARDContentView.swift" || (echo "NFCARD Pairing tab missing" >&2; exit 1)
	@grep -Fq 'NFCARDWalletCardsTab()' "$(NFCARD_IOS)/NFCARDContentView.swift" || (echo "NFCARD Wallet tab missing" >&2; exit 1)
	@grep -Fq 'case cardLibrary = "Library"' "$(NFCARD_IOS)/Models.swift" || (echo "NFCARD Library tab missing" >&2; exit 1)
	@! grep -Fq 'case passcodeThemes = "Passcode"' "$(NFCARD_IOS)/Models.swift" || (echo "obsolete NFCARD Passcode tab returned" >&2; exit 1)
	@! grep -Fq 'case wallpapers = "Wallpapers"' "$(NFCARD_IOS)/Models.swift" || (echo "obsolete NFCARD Wallpapers tab returned" >&2; exit 1)
	@test -f "FilzaNFCARDHost.swift" || (echo "Missing NFCARD embedded host" >&2; exit 1)
	@test -f "FilzaNFCARDBridge.m" || (echo "Missing NFCARD presentation bridge" >&2; exit 1)
	@test -d "$(BYETUNES_ROOT)" || (echo "Missing ByeTunes submodule. Run: git submodule update --init --recursive" >&2; exit 1)
	@test -f "$(BYETUNES_ROOT)/ContentView.swift" || (echo "Incomplete ByeTunes submodule" >&2; exit 1)
	@test -f "$(BYETUNES_ROOT)/BackgroundAudioDownloadManager.swift" || (echo "Incomplete ByeTunes 2.4 sources" >&2; exit 1)
	@test -f "$(BYETUNES_ACTIVITY_SHARED)" || (echo "Missing ByeTunes 2.4 shared Live Activity model" >&2; exit 1)
	@test -f "ByeTunesMetadataCompat.swift" || (echo "Missing ByeTunes metadata compatibility layer" >&2; exit 1)
	@test -f "ByeTunesDownloadParityCompat.swift" || (echo "Missing ByeTunes download-provider compatibility layer" >&2; exit 1)
	@test -f "scripts/patch-byetunes-upstream-parity-v2.sh" || (echo "Missing structural ByeTunes upstream-parity patch" >&2; exit 1)
	@test -f "scripts/patch-byetunes-metadata-parity-post.sh" || (echo "Missing ByeTunes metadata-parity post-patch" >&2; exit 1)
	@test -f "scripts/patch-byetunes-background-provider-parity.sh" || (echo "Missing ByeTunes background-provider parity patch" >&2; exit 1)
	@test -f "scripts/patch-byetunes-download-provider-parity.sh" || (echo "Missing ByeTunes download-provider parity patch" >&2; exit 1)
	@test -f "scripts/patch-byetunes-device-library-save.sh" || (echo "Missing ByeTunes device-library save verifier" >&2; exit 1)
	@test -f "scripts/patch-byetunes-public-metadata-stack.sh" || (echo "Missing ByeTunes public metadata policy patch" >&2; exit 1)
	@test -f "scripts/patch-byetunes-apple-synced-lyrics.sh" || (echo "Missing Apple Music synced-lyrics patch" >&2; exit 1)
	@test -f "AppleMusicSyncedLyrics.swift" || (echo "Missing Apple Music synced-lyrics runtime" >&2; exit 1)
	@grep -Fq 'Apple Music user token captured and persisted' "AppleMusicSyncedLyrics.swift" || (echo "Apple Music login persistence path missing" >&2; exit 1)
	@grep -Fq 'storefrontGrace: TimeInterval = 8' "AppleMusicSyncedLyrics.swift" || (echo "Apple Music storefront grace path missing" >&2; exit 1)
	@test -f "ByeTunesOnDevicePairing.swift" || (echo "Missing ByeTunes on-device pairing runtime" >&2; exit 1)
	@test -f "ByeTunesRemotePairingPortDiscovery.swift" || (echo "Missing AirCard-parity Remote Pairing discovery" >&2; exit 1)
	@grep -Fq '_remotepairing._tcp.' "ByeTunesRemotePairingPortDiscovery.swift" || (echo "Remote Pairing Bonjour discovery missing" >&2; exit 1)
	@grep -Fq 'al_pairing_run_host' "ByeTunesOnDevicePairing.swift" || (echo "ByeTunes is not using NFCARD/Airlift pairing host" >&2; exit 1)
	@test -f "scripts/patch-byetunes-rppairing-localdevvpn.sh" || (echo "Missing LocalDevVPN Remote Pairing repair" >&2; exit 1)
	@test -f "scripts/patch-byetunes-pairing-and-tabs.sh" || (echo "Missing ByeTunes pairing/tab UI patch" >&2; exit 1)
	@! grep -Fq '/api/metadata' "$(BYETUNES_ROOT)/DownloadView.swift" || (echo "Private ByeTunes metadata backend remains" >&2; exit 1)
	@! grep -Fq '/api/download' "$(BYETUNES_ROOT)/DownloadView.swift" || (echo "Private ByeTunes download backend remains" >&2; exit 1)
	@! grep -Fq 'ByeTunesApiUrl' "$(BYETUNES_ROOT)/Config.swift" || (echo "ByeTunes Config.plist key remains" >&2; exit 1)
	@grep -Fq 'static func cleanSyncedLyrics' "$(BYETUNES_ROOT)/SongMetadata.swift" || (echo "LRCLIB synced lyric preservation missing" >&2; exit 1)
	@grep -Fq 'AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics' "$(BYETUNES_ROOT)/SongMetadata.swift" || (echo "Apple Music synced lyric provider missing" >&2; exit 1)
	@grep -Fq 'appleSyncedLyricsConfirmed' "$(BYETUNES_ROOT)/MediaLibraryBuilder.swift" || (echo "truthful Apple synced lyric DB flags missing" >&2; exit 1)
	@grep -Fq 'appleSyncedLyricsStoreID' "$(BYETUNES_ROOT)/SongMetadata.swift" || (echo "per-song Apple synced lyric identity missing" >&2; exit 1)
	@grep -Fq 'onAppleMusicSelection' "$(BYETUNES_ROOT)/LyricsSearchSheet.swift" || (echo "lyrics picker Apple catalog callback missing" >&2; exit 1)
	@grep -Fq 'LocalDevVPN Remote Pairing connected via' "$(BYETUNES_ROOT)/iDeviceManager.swift" || (echo "LocalDevVPN endpoint repair missing" >&2; exit 1)
	@grep -Fq '"10.7.0.2"' "$(BYETUNES_ROOT)/iDeviceManager.swift" || (echo "LocalDevVPN peer .2 fallback missing" >&2; exit 1)
	@grep -Fq '"10.7.0.3"' "$(BYETUNES_ROOT)/iDeviceManager.swift" || (echo "LocalDevVPN peer .3 fallback missing" >&2; exit 1)
	@grep -Fq 'ByeTunesRemotePairingPortDiscovery.resolveSynchronously' "$(BYETUNES_ROOT)/iDeviceManager.swift" || (echo "AirCard live Remote Pairing discovery not wired" >&2; exit 1)
	@! grep -Fq 'AppleMusicSyncedLyricsBootstrapView {' "ByeTunesEmbeddedHost.swift" || (echo "Apple Music login bootstrap still wraps ByeTunes" >&2; exit 1)
	@grep -Fq 'Pair with ByeTunes' "$(BYETUNES_ROOT)/OnboardingView.swift" || (echo "on-device pairing UI missing" >&2; exit 1)
	@! grep -Fq 'Label("Download", systemImage: "arrow.down.circle")' "$(BYETUNES_ROOT)/TabViews.swift" || (echo "Download tab still visible" >&2; exit 1)
	@grep -Fq 'appleSyncedLyricsStoreID' "$(BYETUNES_ROOT)/QueuePersistence.swift" || (echo "Apple synced lyric identity persistence missing" >&2; exit 1)
	@test -f "scripts/patch-3105-embedded-compat.sh" || (echo "Missing 3105 embedded compatibility transform" >&2; exit 1)
	@test -f "$(BAD_QUERY_ROOT)/bad_query/bad_query.c" || (echo "Missing pinned bad_query submodule" >&2; exit 1)
	@test -f "$(BAD_QUERY_ROOT)/bad_query/bad_query.h" || (echo "Incomplete bad_query submodule" >&2; exit 1)
	@test -f "AppProxyMetadataFix.m" || (echo "Missing AppProxyMetadataFix.m" >&2; exit 1)
	@test -f "AppMetadataRetryFix.m" || (echo "Missing AppMetadataRetryFix.m" >&2; exit 1)
	@test -f "AppIconResourceProxyFix.m" || (echo "Missing AppIconResourceProxyFix.m" >&2; exit 1)
	@test -f "VirtualBackendFix.m" || (echo "Missing VirtualBackendFix.m" >&2; exit 1)
	@test -f "SystemPathDiagnostics.m" || (echo "Missing SystemPathDiagnostics.m" >&2; exit 1)
	@test -f "BadQuerySystemProbe.m" || (echo "Missing BadQuerySystemProbe.m" >&2; exit 1)
	@test -f "CVE43724RieCompatibility.m" || (echo "Missing CVE43724RieCompatibility.m" >&2; exit 1)
	@test -f "GestaltManager.m" || (echo "Missing GestaltManager.m" >&2; exit 1)
	@test -f "FilzaMondBridge.m" || (echo "Missing FilzaMondBridge.m" >&2; exit 1)
	@test -f "FilzaMainToolbarGestalt.m" || (echo "Missing FilzaMainToolbarGestalt.m" >&2; exit 1)
	@test -f "FilzaMondCurrentHost.swift" || (echo "Missing Mond 2.2 source host" >&2; exit 1)
	@test -f "scripts/stage-mond-current.sh" || (echo "Missing base Mond staging script" >&2; exit 1)
	@test -f "scripts/stage-mond-22-overlay.sh" || (echo "Missing Mond 2.2 overlay staging script" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_app_ContentView.swift" || (echo "Missing Mond 2.2 ContentView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_app_SettingsView.swift" || (echo "Missing Mond 2.2 SettingsView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_GestaltView.swift" || (echo "Missing Mond 2.2 Gestalt/CacheExtra compilation unit" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_SantanderView.swift" || (echo "Missing Mond 2.2 SantanderView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_posterboard_PosterView.swift" || (echo "Missing Mond 2.2 PosterView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_posterboard_TendiesView.swift" || (echo "Missing Mond 2.2 TendiesView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/helpers_posterboard_tendies.swift" || (echo "Missing Mond 2.2 Tendies model" >&2; exit 1)
	@test -f "$(MOND_GEN)/mond_bad_query.c" || (echo "Missing Mond 2.2 bad_query implementation" >&2; exit 1)
	@test -f "$(MOND_GEN)/PartyUI/Containers_TerminalPlatter.swift" || (echo "Missing Mond PartyUI" >&2; exit 1)
	@test -f "$(MOND_GEN)/ZIPFoundation/Archive.swift" || (echo "Missing Mond ZIPFoundation" >&2; exit 1)
	@test -f "$(MOND_GEN)/ZIPFoundation/FileManager+ZIP.swift" || (echo "Missing Mond ZIPFoundation FileManager support" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/AppDataBrowserView.swift" || (echo "Missing complete 3105 Apps Manager source" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/PatchProjectsView.swift" || (echo "Missing complete 3105 Patches source" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/KernelExploit.swift" || (echo "Missing embedded 3105 1.1.1 kernel coordinator" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/FilzaEmbeddedPanel.swift" || (echo "Missing shared 3105-style embedded panel" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/FilzaAppIPAExporter.swift" || (echo "Missing 3105 IPA exporter source" >&2; exit 1)
	@test -f "Filza3105IPAExportBridge.m" || (echo "Missing 3105 IPA export bridge" >&2; exit 1)
	@test -f "$(GCDWEBSERVER_ROOT)/GCDWebServer/Core/GCDWebServer.h" || (echo "Missing GCDWebServer source" >&2; exit 1)
	@test -f "$(GCDWEBSERVER_ROOT)/GCDWebDAVServer/GCDWebDAVServer.h" || (echo "Missing GCDWebDAVServer source" >&2; exit 1)

# These fragments must be included before Theos creates the target rules so
# their additional FILES/SWIFT_FILES/LDFLAGS are part of the actual target.
# Their before-* hooks remain after the main staging hook above, preserving the
# required stage -> patch -> compile order.
include FilzaSSHMetadata.mk
include FilzaByeTunesNetwork.mk
include $(THEOS_MAKE_PATH)/tweak.mk