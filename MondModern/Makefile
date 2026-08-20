TARGET := iphone:clang:latest:16.1
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FilzaMondModern
ROOT := $(abspath ..)
MOND_GEN := $(ROOT)/ThirdParty/mond-current/Generated
BAD_QUERY_ROOT := $(ROOT)/ThirdParty/bad_query
MOND_BRIDGING_HEADER := $(ROOT)/MondModern/MondModern-Bridging-Header.h
SHARED_PANEL := $(ROOT)/ThirdParty/3105/Sources/FilzaEmbeddedPanel.swift

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

FilzaMondModern_FILES = $(BAD_QUERY_ROOT)/bad_query/bad_query.c $(MOND_GEN)/mond_bad_query.c
FilzaMondModern_SWIFT_FILES = $(ROOT)/FilzaMondCurrentHost.swift $(SHARED_PANEL) $(MOND_SWIFT_FILES) $(MOND_PARTYUI_SWIFT_FILES) $(MOND_ZIP_SWIFT_FILES)

FilzaMondModern_CFLAGS = -I$(ROOT) -I$(ROOT)/compat -I$(BAD_QUERY_ROOT)/bad_query -I$(MOND_GEN) -fobjc-arc -include errno.h -include math.h -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-deprecated-declarations -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers -Wno-format
FilzaMondModern_SWIFTFLAGS += -swift-version 5 -default-isolation MainActor -Xfrontend -solver-expression-time-threshold=300 -Xcc -I$(MOND_GEN) -import-objc-header $(MOND_BRIDGING_HEADER)
FilzaMondModern_FRAMEWORKS = UIKit Foundation SwiftUI Combine AVFoundation AVKit CoreMedia AudioToolbox CryptoKit Security UniformTypeIdentifiers PhotosUI JavaScriptCore AppIntents ActivityKit SafariServices CFNetwork MobileCoreServices WebKit QuickLook ImageIO
FilzaMondModern_PRIVATE_FRAMEWORKS = IOSurface
FilzaMondModern_LIBRARIES = z xml2 sandbox sqlite3
FilzaMondModern_INSTALL_PATH = /usr/lib

before-FilzaMondModern-all::
	@cd "$(ROOT)" && bash scripts/stage-mond-current.sh
	@cd "$(ROOT)" && bash scripts/stage-mond-22-overlay.sh
	@cd "$(ROOT)" && bash scripts/patch-mond-ios16-backport.sh
	@cd "$(ROOT)" && bash scripts/verify-mond-source-completeness.sh
	@cd "$(ROOT)" && bash scripts/stage-mond-embedded-resources.sh
	@test -f "$(MOND_GEN)/Mond/views_app_ContentView.swift" || (echo "Missing staged Mond 2.2 ContentView" >&2; exit 1)
	@test -f "$(MOND_GEN)/Mond/views_tweaks_GestaltView.swift" || (echo "Missing staged Mond 2.2 GestaltView" >&2; exit 1)
	@test -f "$(MOND_GEN)/mond_bad_query.c" || (echo "Missing staged Mond bad_query C source" >&2; exit 1)
	@test -f "$(MOND_GEN)/mond_bad_query.h" || (echo "Missing staged Mond bad_query header" >&2; exit 1)
	@test -f "$(MOND_BRIDGING_HEADER)" || (echo "Missing Mond Swift bridging header" >&2; exit 1)
	@test -f "$(SHARED_PANEL)" || (echo "Missing shared 3105-style embedded panel" >&2; exit 1)

include $(THEOS_MAKE_PATH)/library.mk
