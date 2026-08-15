# Build against the modern iOS SDK because the complete ByeTunes app uses
# iOS 16+ SwiftUI/AppIntents APIs. The upstream jailed Filza host is arm64-only.
TARGET := iphone:clang:latest:16.0
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

FilzaApplySandboxExt_FILES = Tweak.m AppsMusicFix.m AppsManagerPresentationFix.m AppProxyMetadataFix.m AppMetadataRetryFix.m AppIconResourceProxyFix.m VirtualBackendFix.m SystemPathDiagnostics.m BadQuerySystemProbe.m GestaltManager.m FilzaMondBridge.m FilzaMainToolbarGestalt.m Filza3105Bridge.m ByeTunesMusicBridge.m ByeTunesFilzaLibraryEmbed.m ByeTunesFullAppLauncher.m FilzaDiagnostics.m FilzaQuickActions.m WebDAVRuntimeFix.m WebDAVToggleStateFix.m ArchiveSafety.m ArchiveCreationSafety.m RuntimeStability.m CompatibilityDiagnostics.m CVE43724RieCompatibility.m MCMBridge.m MCMFilzaIntegration.m PosterBoardFeature.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/AppIconHelper.m
FilzaApplySandboxExt_FILES += $(THREEONE_ROOT)/Sources/wallpaper_zip.c
FilzaApplySandboxExt_FILES += $(BAD_QUERY_ROOT)/bad_query/bad_query.c

GCDWEBSERVER_OBJC_FILES := $(shell find $(GCDWEBSERVER_ROOT)/GCDWebServer $(GCDWEBSERVER_ROOT)/GCDWebDAVServer -type f -name '*.m' -print)
FilzaApplySandboxExt_FILES += $(GCDWEBSERVER_OBJC_FILES)

FilzaApplySandboxExt_FILES += sandbox_escape.m apfs_own.m
FilzaApplySandboxExt_FILES += kexploit/kexploit_opa334.m kexploit/krw.m kexploit/kutils.m kexploit/offsets.m kexploit/vnode.m
FilzaApplySandboxExt_FILES += utils/file.c utils/hexdump.c utils/process.c
FilzaApplySandboxExt_FILES += kpf/patchfinder.m
FilzaApplySandboxExt_FILES += XPF/src/xpf.c XPF/src/common.c XPF/src/decompress.c XPF/src/bad_recovery.c XPF/src/non_ppl.c XPF/src/ppl.c
FilzaApplySandboxExt_FILES += XPF/external/ChOma/src/arm64.c XPF/external/ChOma/src/Base64.c XPF/external/ChOma/src/BufferedStream.c XPF/external/ChOma/src/CodeDirectory.c XPF/external/ChOma/src/CSBlob.c XPF/external/ChOma/src/DER.c XPF/external/ChOma/src/DyldSharedCache.c XPF/external/ChOma/src/Entitlements.c XPF/external/ChOma/src/Fat.c XPF/external/ChOma/src/FileStream.c XPF/external/ChOma/src/Host.c XPF/external/ChOma/src/MachO.c XPF/external/ChOma/src/MachOLoadCommand.c XPF/external/ChOma/src/MemoryStream.c XPF/external/ChOma/src/PatchFinder.c XPF/external/ChOma/src/PatchFinder_arm64.c XPF/external/ChOma/src/Util.c

# Full ByeTunes v2.4 source tree, with the old provider state machine restored
# by explicit build-time parity patches. MusicManagerApp.swift is omitted
# because Filza already owns UIApplication lifecycle.
BYETUNES_SWIFT_FILES := $(shell find $(BYETUNES_ROOT) -type f -name '*.swift' ! -name 'MusicManagerApp.swift' ! -name 'SplashView.swift' -print)
# The vendored 3105 tree is a rollback baseline. stage-3105-v1.sh overlays the
# exact immutable 1.0 upstream files before compilation while preserving the
# Filza-only root/settings namespace and host glue.
THREEONE_SWIFT_FILES := $(shell find $(THREEONE_ROOT)/Sources -type f -name '*.swift' -print)
FilzaApplySandboxExt_SWIFT_FILES = ByeTunesEmbeddedHost.swift ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift MondGestaltView.swift Filza3105Host.swift $(THREEONE_SWIFT_FILES) $(BYETUNES_SWIFT_FILES) $(BYETUNES_ACTIVITY_SHARED)

FilzaApplySandboxExt_CFLAGS = -I$(PWD)/compat -I$(PWD) -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include -I$(IDEVICE_VENDOR)/include -I$(PWD)/$(BAD_QUERY_ROOT)/bad_query -I$(PWD)/$(THREEONE_ROOT)/Sources \
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
FilzaApplySandboxExt_SWIFTFLAGS += -swift-version 5 -default-isolation MainActor -Xcc -I$(IDEVICE_VENDOR)/include
FilzaApplySandboxExt_LDFLAGS += $(IDEVICE_STATIC)

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation SwiftUI Combine AVFoundation CoreMedia AudioToolbox CryptoKit Security UniformTypeIdentifiers PhotosUI JavaScriptCore AppIntents ActivityKit SafariServices CFNetwork MobileCoreServices WebKit QuickLook
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z xml2 sandbox sqlite3
FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

# Every transformation is explicit and ordered. No script may invoke another
# unrelated patch as a hidden side effect.
before-FilzaApplySandboxExt-all::
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
	@test -f "MondGestaltView.swift" || (echo "Missing MondGestaltView.swift" >&2; exit 1)
	@test -f "Filza3105Host.swift" || (echo "Missing Filza3105Host.swift" >&2; exit 1)
	@test -f "Filza3105Bridge.m" || (echo "Missing Filza3105Bridge.m" >&2; exit 1)
	@test -f "scripts/stage-3105-v1.sh" || (echo "Missing pinned 3105 1.0 staging script" >&2; exit 1)
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

include $(THEOS_MAKE_PATH)/tweak.mk
