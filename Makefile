# Build against the modern iOS SDK because Mond 2.1 and the complete ByeTunes app use
# modern SwiftUI APIs. Mond 2.1's upstream deployment target is iOS 17.
TARGET := iphone:clang:latest:17.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt
IDEVICE_VENDOR ?= $(PWD)/Vendor/idevice
IDEVICE_STATIC := $(IDEVICE_VENDOR)/lib/libidevice_ffi.a
BYETUNES_ROOT := ByeTunes/MusicManager
BYETUNES_ACTIVITY_SHARED := ByeTunes/MusicManagerActivityShared/DownloadLiveActivityAttributes.swift
BAD_QUERY_ROOT := ThirdParty/bad_query
GCDWEBSERVER_ROOT := ThirdParty/GCDWebServer
THREEONE_ROOT := ThirdParty/3105
MOND_CURRENT_ROOT := ThirdParty/mond-current
MOND_GEN := $(MOND_CURRENT_ROOT)/Generated

FilzaApplySandboxExt_FILES = Tweak.m AppsMusicFix.m AppsManagerPresentationFix.m AppProxyMetadataFix.m AppMetadataRetryFix.m AppIconResourceProxyFix.m VirtualBackendFix.m SystemPathDiagnostics.m BadQuerySystemProbe.m GestaltManager.m FilzaMondBridge.m FilzaMainToolbarGestalt.m Filza3105Bridge.m ByeTunesMusicBridge.m ByeTunesFilzaLibraryEmbed.m ByeTunesFullAppLauncher.m FilzaDiagnostics.m FilzaQuickActions.m WebDAVRuntimeFix.m WebDAVToggleStateFix.m ArchiveSafety.m ArchiveCreationSafety.m RuntimeStability.m CompatibilityDiagnostics.m CVE43724RieCompatibility.m MCMBridge.m MCMFilzaIntegration.m PosterBoardFeature.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/AppIconHelper.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/wallpaper_zip.c
FilzaApplySandboxExt_FILES += $(BAD_QUERY_ROOT)/bad_query/bad_query.c
FilzaApplySandboxExt_FILES += $(MOND_GEN)/mond_bad_query.c

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

# The vendored 3105 tree is a rollback baseline. stage-3105-v1.sh overlays the
# exact immutable 1.0 upstream files before compilation while preserving the
# Filza-only root/settings namespace and host glue.
THREEONE_SWIFT_FILES := $(shell find $(THREEONE_ROOT)/Sources -type f -name '*.swift' -print)

# Mond 2.1 is fetched from its immutable upstream commit and mechanically
# namespaced so it can coexist in Filza's Swift module. No Mond behavior/UI
# patch is applied.
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

FilzaApplySandboxExt_SWIFT_FILES = ByeTunesEmbeddedHost.swift ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift FilzaMondCurrentHost.swift Filza3105Host.swift $(MOND_SWIFT_FILES) $(MOND_PARTYUI_SWIFT_FILES) $(MOND_ZIP_SWIFT_FILES) $(THREEONE_SWIFT_FILES) $(BYETUNES_SWIFT_FILES) $(BYETUNES_ACTIVITY_SHARED)

FilzaApplySandboxExt_CFLAGS = -I$(PWD)/compat -I$(PWD) -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include -I$(IDEVICE_VENDOR)/include -I$(PWD)/$(BAD_QUERY_ROOT)/bad_query -I$(PWD)/$(THREEONE_ROOT)/Sources -I$(PWD)/$(MOND_GEN) \
    -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Core -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Requests -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebServer/Responses -I$(PWD)/$(GCDWEBSERVER_ROOT)/GCDWebDAVServer \
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
FilzaApplySandboxExt_SWIFTFLAGS += -swift-version 5 -default-isolation MainActor -Xfrontend -solver-expression-time-threshold=300 -Xcc -I$(IDEVICE_VENDOR)/include -Xcc -I$(PWD)/$(MOND_GEN)
FilzaApplySandboxExt_LDFLAGS += $(IDEVICE_STATIC)

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation SwiftUI Combine AVFoundation AVKit CoreMedia AudioToolbox CryptoKit Security UniformTypeIdentifiers PhotosUI JavaScriptCore AppIntents ActivityKit SafariServices CFNetwork MobileCoreServices WebKit QuickLook ImageIO
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z xml2 sandbox sqlite3
FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

# Every transformation is explicit and ordered. No script may invoke another
# unrelated patch as a hidden side effect.
before-FilzaApplySandboxExt-all::
	@bash scripts/stage-mond-current.sh
	@bash scripts/stage-3105-v1.sh
	@bash scripts/patch-access-map-provenance.sh
	@bash scripts/patch-byetunes-upstream-parity-v2.sh
	@bash scripts/restore-byetunes-v24-metadata-compat.sh
	@bash scripts/patch-byetunes-metadata-parity-post.sh
	@bash scripts/patch-byetunes-background-provider-parity.sh
	@bash scripts/patch-byetunes-download-provider-parity.sh
	@bash scripts/patch-byetunes-device-library-save.sh
	@test -s "$(IDEVICE_STATIC)" || (echo "Missing $(IDEVICE_STATIC). Run: bash scripts/build-idevice.sh" >&2; exit 1)
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
	@test -f "FilzaMondCurrentHost.swift" || (echo "Missing Mond 2.1 source host" >&2; exit 1)
	@test -f "scripts/stage-mond-current.sh" || (echo "Missing pinned Mond 2.1 staging script" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_app_ContentView.swift" || (echo "Missing Mond 2.1 ContentView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_app_SettingsView.swift" || (echo "Missing Mond 2.1 SettingsView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_GestaltView.swift" || (echo "Missing Mond 2.1 GestaltView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_SantanderView.swift" || (echo "Missing Mond 2.1 SantanderView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_posterboard_PosterView.swift" || (echo "Missing Mond 2.1 PosterView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_posterboard_TendiesView.swift" || (echo "Missing Mond 2.1 TendiesView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/helpers_posterboard_tendies.swift" || (echo "Missing Mond 2.1 Tendies model" >&2; exit 1)
	@test -f "$(MOND_GEN)/mond_bad_query.c" || (echo "Missing Mond 2.1 bad_query implementation" >&2; exit 1)
	@test -f "$(MOND_GEN)/PartyUI/Containers_TerminalPlatter.swift" || (echo "Missing Mond 2.1 PartyUI" >&2; exit 1)
	@test -f "$(MOND_GEN)/ZIPFoundation/Archive.swift" || (echo "Missing Mond 2.1 ZIPFoundation" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/AppDataBrowserView.swift" || (echo "Missing 3105 Apps Manager" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/PatchProjectsView.swift" || (echo "Missing 3105 Patches" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/ThreeOneOSFiveContentView.swift" || (echo "Missing complete 3105 root navigation" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/CleanerView.swift" || (echo "Missing 3105 Cleaner" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/WallpaperLabView.swift" || (echo "Missing 3105 Wallpaper Lab" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/ThreeOneOSFiveSettingsView.swift" || (echo "Missing 3105 Settings" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/LogView.swift" || (echo "Missing 3105 Logs" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/FileOperationCoordinator.swift" || (echo "Missing 3105 1.0 file-operation coordinator" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/ZIPArchiveWriter.swift" || (echo "Missing 3105 1.0 ZIP writer" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Sources/wallpaper_zip.c" || (echo "Missing 3105 secure wallpaper ZIP extractor" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Resources/Filza3105.bundle/en.lproj/Localizable.strings" || (echo "Missing 3105 resources" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Resources/Filza3105.bundle/UpstreamAppInfo.plist" || (echo "Missing staged 3105 1.0 app metadata" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/Resources/Filza3105.bundle/AppIcon3105.png" || (echo "Missing 3105 app icon resource" >&2; exit 1)
	@test -f "$(THREEONE_ROOT)/LICENSE" || (echo "Missing 3105 license" >&2; exit 1)
	@test -f "ByeTunesFullAppLauncher.m" || (echo "Missing ByeTunesFullAppLauncher.m" >&2; exit 1)
	@test -f "FilzaDiagnostics.m" || (echo "Missing FilzaDiagnostics.m" >&2; exit 1)
	@test -f "FilzaQuickActions.m" || (echo "Missing FilzaQuickActions.m" >&2; exit 1)
	@test -f "WebDAVRuntimeFix.m" || (echo "Missing WebDAVRuntimeFix.m" >&2; exit 1)
	@test -f "WebDAVToggleStateFix.m" || (echo "Missing WebDAVToggleStateFix.m" >&2; exit 1)
	@test -f "$(GCDWEBSERVER_ROOT)/GCDWebDAVServer/GCDWebDAVServer.m" || (echo "Missing pinned GCDWebDAVServer" >&2; exit 1)
	@test -f "$(GCDWEBSERVER_ROOT)/LICENSE" || (echo "Missing GCDWebServer license" >&2; exit 1)

include FilzaSSHMetadata.mk
include FilzaByeTunesNetwork.mk
include $(THEOS_MAKE_PATH)/tweak.mk