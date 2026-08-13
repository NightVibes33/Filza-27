# Build against the modern iOS SDK because the complete ByeTunes app uses
# iOS 16+ SwiftUI/AppIntents APIs. The upstream jailed Filza host is arm64-only.
TARGET := iphone:clang:latest:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt
IDEVICE_VENDOR ?= $(PWD)/Vendor/idevice
IDEVICE_STATIC := $(IDEVICE_VENDOR)/lib/libidevice_ffi.a
BYETUNES_ROOT := ByeTunes/MusicManager
BAD_QUERY_ROOT := ThirdParty/bad_query

# Runtime/file-operation correctness layers that must actually ship with the
# real tweak target. ByeTunesFilzaLibraryEmbed.m replaces Filza's existing
# TGMusicLibraryViewController contents in-place with the real ByeTunes SwiftUI
# root; the older custom table and modal full-app launcher are intentionally not
# linked anymore.
FilzaApplySandboxExt_FILES = Tweak.m AppsMusicFix.m AppsManagerPresentationFix.m AppProxyMetadataFix.m VirtualBackendFix.m SystemPathDiagnostics.m ByeTunesMusicBridge.m ByeTunesFilzaLibraryEmbed.m ArchiveSafety.m ArchiveCreationSafety.m RuntimeStability.m CompatibilityDiagnostics.m MCMBridge.m MCMFilzaIntegration.m PosterBoardFeature.m

# Pinned upstream bad_query is used only as a per-container fallback when the
# MobileHouseArrest class-2 lease resolves a foreign app root but cannot issue
# a usable sandbox extension. Keep the upstream implementation unmodified.
FilzaApplySandboxExt_FILES += $(BAD_QUERY_ROOT)/bad_query/bad_query.c

# The original jailed Filza kernel path is used only by the exact iOS 18.5
# target gate in Tweak.m. Newer systems continue to use the MCM path.
FilzaApplySandboxExt_FILES += sandbox_escape.m apfs_own.m
FilzaApplySandboxExt_FILES += kexploit/kexploit_opa334.m kexploit/krw.m kexploit/kutils.m kexploit/offsets.m kexploit/vnode.m
FilzaApplySandboxExt_FILES += utils/file.c utils/hexdump.c utils/process.c
FilzaApplySandboxExt_FILES += kpf/patchfinder.m
FilzaApplySandboxExt_FILES += XPF/src/xpf.c XPF/src/common.c XPF/src/decompress.c XPF/src/bad_recovery.c XPF/src/non_ppl.c XPF/src/ppl.c
FilzaApplySandboxExt_FILES += XPF/external/ChOma/src/arm64.c XPF/external/ChOma/src/Base64.c XPF/external/ChOma/src/BufferedStream.c XPF/external/ChOma/src/CodeDirectory.c XPF/external/ChOma/src/CSBlob.c XPF/external/ChOma/src/DER.c XPF/external/ChOma/src/DyldSharedCache.c XPF/external/ChOma/src/Entitlements.c XPF/external/ChOma/src/Fat.c XPF/external/ChOma/src/FileStream.c XPF/external/ChOma/src/Host.c XPF/external/ChOma/src/MachO.c XPF/external/ChOma/src/MachOLoadCommand.c XPF/external/ChOma/src/MemoryStream.c XPF/external/ChOma/src/PatchFinder.c XPF/external/ChOma/src/PatchFinder_arm64.c XPF/external/ChOma/src/Util.c

# Full ByeTunes embedding. Compile every Swift source from the pinned ByeTunes
# app, including all screens, downloader, ringtones, settings, metadata tools,
# DeviceManager, intents and YouTubeKit. Only MusicManagerApp.swift is omitted
# because its @main owns a standalone UIApplication lifecycle; Filza already
# owns that lifecycle. ByeTunesEmbeddedHost.swift exposes ContentView() as a
# child controller that is mounted directly inside Filza's Music Library.
BYETUNES_SWIFT_FILES := $(shell find $(BYETUNES_ROOT) -type f -name '*.swift' ! -name 'MusicManagerApp.swift' -print)
FilzaApplySandboxExt_SWIFT_FILES = ByeTunesEmbeddedHost.swift $(BYETUNES_SWIFT_FILES)

# --- Flags ---
FilzaApplySandboxExt_CFLAGS = -I$(PWD)/compat -I$(PWD) -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include -I$(IDEVICE_VENDOR)/include -I$(PWD)/$(BAD_QUERY_ROOT)/bad_query \
    -fobjc-arc -include errno.h -include math.h \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
    -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-deprecated-declarations -Wno-nonportable-include-path -Wno-format
FilzaApplySandboxExt_CFLAGS += -Wno-arc-performSelector-leaks

FilzaApplySandboxExt_CCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
# AppIntents metadata extraction consumes Swift's supplementary constant-value
# output. Xcode emits this automatically for app targets; Theos does not, so
# preserve the equivalent module-level file for the post-link processor.
FilzaApplySandboxExt_SWIFTFLAGS += -swift-version 5 -default-isolation MainActor -Xcc -I$(IDEVICE_VENDOR)/include
FilzaApplySandboxExt_SWIFTFLAGS += -emit-const-values-path $(THEOS_OBJ_DIR)/FilzaApplySandboxExt.swiftconstvalues
FilzaApplySandboxExt_LDFLAGS += $(IDEVICE_STATIC)

# Framework coverage matches the complete ByeTunes source tree rather than the
# old reduced music-library bridge.
FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation SwiftUI Combine AVFoundation CoreMedia AudioToolbox CryptoKit UniformTypeIdentifiers PhotosUI JavaScriptCore AppIntents
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z sandbox sqlite3

FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

before-FilzaApplySandboxExt-all::
	@bash scripts/patch-byetunes-embedded.sh
	@test -s "$(IDEVICE_STATIC)" || (echo "Missing $(IDEVICE_STATIC). Run: bash scripts/build-idevice.sh" >&2; exit 1)
	@test -d "$(BYETUNES_ROOT)" || (echo "Missing ByeTunes submodule. Run: git submodule update --init --recursive" >&2; exit 1)
	@test -f "$(BYETUNES_ROOT)/ContentView.swift" || (echo "Incomplete ByeTunes submodule" >&2; exit 1)
	@test -f "$(BYETUNES_ROOT)/YouTubeKit/Resources/meriyah.umd.js" || (echo "Incomplete ByeTunes resources" >&2; exit 1)
	@test -f "$(BAD_QUERY_ROOT)/bad_query/bad_query.c" || (echo "Missing pinned bad_query submodule. Run: git submodule update --init --recursive" >&2; exit 1)
	@test -f "$(BAD_QUERY_ROOT)/bad_query/bad_query.h" || (echo "Incomplete bad_query submodule" >&2; exit 1)
	@test -f "AppProxyMetadataFix.m" || (echo "Missing AppProxyMetadataFix.m" >&2; exit 1)
	@test -f "VirtualBackendFix.m" || (echo "Missing VirtualBackendFix.m" >&2; exit 1)
	@test -f "SystemPathDiagnostics.m" || (echo "Missing SystemPathDiagnostics.m" >&2; exit 1)

include $(THEOS_MAKE_PATH)/tweak.mk
