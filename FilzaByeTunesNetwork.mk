# ByeTunes network/provider compatibility fragment.
#
# The v2.4 app remains the primary ByeTunes source tree. All Sources importing,
# the song editor, and v2.4 metadata selection are intentionally untouched.
# Only the YouTube provider regains the exact vendored YouTubeKit implementation
# that shipped in NightVibes33/ByeTunes before the v2.4 migration.

# A fresh checkout does not contain the generated pre-v2.4 YouTubeKit tree.
# Bootstrap it while make is still parsing this fragment, before Theos validates
# the Swift input paths. The later build hook still verifies/restages the exact
# pinned tree before compilation.
include FilzaYouTubeKitBootstrap.mk

BYETUNES_YTK_ROOT := ThirdParty/byetunes-youtubekit/Generated
BYETUNES_YTK_SWIFT_FILES := \
    $(BYETUNES_YTK_ROOT)/Cipher.swift \
    $(BYETUNES_YTK_ROOT)/Errors.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/AsyncCompatibility.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/Concurrency.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/Foundation.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/Lazy.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/Logging.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/RegularExpression.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/Retry.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/URLSessionDelegates.swift \
    $(BYETUNES_YTK_ROOT)/Extensions/WebSocket.swift \
    $(BYETUNES_YTK_ROOT)/Extraction.swift \
    $(BYETUNES_YTK_ROOT)/InnerTube.swift \
    $(BYETUNES_YTK_ROOT)/Models/Codecs.swift \
    $(BYETUNES_YTK_ROOT)/Models/FileExtension.swift \
    $(BYETUNES_YTK_ROOT)/Models/ITag.swift \
    $(BYETUNES_YTK_ROOT)/Models/Livestream.swift \
    $(BYETUNES_YTK_ROOT)/Models/Method.swift \
    $(BYETUNES_YTK_ROOT)/Models/Stream.swift \
    $(BYETUNES_YTK_ROOT)/Models/StreamQuery.swift \
    $(BYETUNES_YTK_ROOT)/Models/YouTubeMetadata.swift \
    $(BYETUNES_YTK_ROOT)/Parser.swift \
    $(BYETUNES_YTK_ROOT)/Remote/AppIdentity.swift \
    $(BYETUNES_YTK_ROOT)/Remote/Chunking.swift \
    $(BYETUNES_YTK_ROOT)/Remote/Models/RemoteStream.swift \
    $(BYETUNES_YTK_ROOT)/Remote/RemoteYouTubeClient.swift \
    $(BYETUNES_YTK_ROOT)/SignatureSolver.swift \
    $(BYETUNES_YTK_ROOT)/YouTube.swift

FilzaApplySandboxExt_SWIFT_FILES += $(BYETUNES_YTK_SWIFT_FILES)

# XPF's common/PatchFinder code calls the arm64-specific ChOma helpers. Keep
# the existing upstream implementation linked as its own translation unit.
FilzaApplySandboxExt_FILES += XPF/external/ChOma/src/PatchFinder_arm64.c

# Upstream Mond resolves these private Sandbox SPI calls from
# libsystem_sandbox.dylib with dlopen/dlsym. The combined Theos Swift target
# emits C ABI link references for the same names, so expose a thin forwarding
# ABI bridge without changing the staged Mond source or behavior.
FilzaApplySandboxExt_FILES += MondSandboxSPICompat.c

# Replace Filza's legacy activation/payment presentation with a voluntary
# Buy Me a Coffee support sheet. The hook is intentionally UI-only: it does not
# alter Filza feature gating, filesystem access, or activation state.
FilzaApplySandboxExt_FILES += FilzaSupportPrompt.m

before-FilzaApplySandboxExt-all::
	# Add an Apps Manager long-press action that repackages the installed .app
	# bundle as a standard Payload/<name>.app IPA and opens the system export UI.
	# The bundle is archived exactly as installed; this does not decrypt FairPlay,
	# strip DRM, alter entitlements, or resign the app.
	@bash scripts/patch-3105-ipa-export.sh
	@test -f scripts/patch-3105-ipa-export.sh || (echo "Missing 3105 IPA export patch" >&2; exit 1)
	@grep -Fq 'Label("Repackage as IPA"' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FilzaAppIPAExporter.repackage' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'static func writeIPA(' ThirdParty/3105/Sources/ZIPArchiveWriter.swift
	@grep -Fq 'archiveRootName: "Payload/' ThirdParty/3105/Sources/ZIPArchiveWriter.swift
	@grep -Fq 'filzaAppBundlePathForBundleID' ThirdParty/3105/Sources/AppIconHelper.h
	@test -f ThirdParty/3105/Sources/FilzaAppIPAExporter.swift
	@test -f Filza3105IPAExportBridge.m

	# Restore the requested View / Sort menu while preserving the original row UI.
	# Default remains the exact existing 3105 list/order. The broader Apple
	# LaunchServices probe starts only when a research view is explicitly selected.
	# No discovery badges or source labels are rendered in the app rows.
	@bash scripts/patch-3105-app-manager-view-sort.sh
	@test -f scripts/patch-3105-app-manager-view-sort.sh || (echo "Missing 3105 app view/sort patch" >&2; exit 1)
	@grep -Fq 'FILZA_3105_APP_VIEW_SORT_V2' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'Picker("View", selection: $$appViewMode)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'Picker("Sort", selection: $$appSortOrder)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'case internalHidden = "internal-hidden"' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'case systemServices = "system-services"' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'case unresolvedInteresting = "unresolved-interesting"' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'if appViewMode == .default && appSortOrder == .name' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'ContainerPresentationPolicy.shouldShow(bundleID: $$0.bundleID)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@! grep -Fq 'discoverySummary(for: app)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'Label("Repackage as IPA"' ThirdParty/3105/Sources/AppDataBrowserView.swift

	# Keep upstream 3105's original Settings sheet presentation. The pairing file
	# chooser itself uses SwiftUI fileImporter with UTType.item so the Files UI is
	# presented by the current Settings view instead of stacking another custom
	# SwiftUI sheet or changing 3105's navigation hierarchy.
	@bash scripts/patch-3105-pairing-importer.sh
	@test -f scripts/patch-3105-pairing-importer.sh || (echo "Missing 3105 pairing importer patch" >&2; exit 1)
	@grep -Fq '.sheet(isPresented: $$showSettings) { ThreeOneOSFiveSettingsView() }' ThirdParty/3105/Sources/ThreeOneOSFiveContentView.swift
	@grep -Fq 'allowedContentTypes: [.item]' ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift
	@grep -Fq 'handlePairingImport(_ result: Result<[URL], Error>)' ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift
	@! grep -Fq '.sheet(isPresented: $$showingPairingImporter)' ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift

	# stage-3105-v1.sh runs in the main Makefile hook before this included
	# fragment. Replace only the generated Filza icon glue with the optimized
	# persistent-client implementation after the immutable 3105 stage completes.
	@bash scripts/patch-3105-icon-performance.sh
	@test -f scripts/patch-3105-icon-performance.sh || (echo "Missing 3105 icon performance patch" >&2; exit 1)
	@grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FILZA_SBS_ICON_WORKERS 3' ThirdParty/3105/Sources/AppIconHelper.m
	@grep -Fq 'FilzaEnsureRSDIconClientLocked' ThirdParty/3105/Sources/AppIconHelper.m

	# The main Makefile stages the pinned Mond source before this included fragment.
	# Prove the 2.2 functional graph is complete, stage app-target resources, then
	# adapt only the generated embedded copy.
	@bash scripts/verify-mond-source-completeness.sh
	@bash scripts/stage-mond-embedded-resources.sh
	@bash scripts/patch-mond-embedded-parity.sh
	@test -f scripts/verify-mond-source-completeness.sh || (echo "Missing Mond completeness verifier" >&2; exit 1)
	@test -f scripts/stage-mond-embedded-resources.sh || (echo "Missing Mond resource staging script" >&2; exit 1)
	@test -f scripts/patch-mond-embedded-parity.sh || (echo "Missing Mond embedded parity adapter" >&2; exit 1)
	@test -s ThirdParty/mond-current/Resources/MondEmbedded.bundle/Info.plist
	@test -s ThirdParty/mond-current/Resources/MondEmbedded.bundle/MondEmbeddedIcon.png
	@grep -Fq 'MondEmbeddedParity.accentColor' ThirdParty/mond-current/Generated/Mond/views_tweaks_GestaltView.swift
	@grep -Fq '@AppStorage("method", store: MondEmbeddedParity.defaults)' ThirdParty/mond-current/Generated/Mond/views_app_SettingsView.swift
	@grep -Fq 'MondEmbeddedParity.bundle.infoDictionary' ThirdParty/mond-current/Generated/Mond/views_app_SettingsView.swift
	@grep -Fq '@EnvironmentObject var state: MondCurrentAppState' ThirdParty/mond-current/Generated/Mond/views_tweaks_GestaltView.swift
	@grep -Fq 'Color("AccentColor")' ThirdParty/mond-current/Upstream/views/tweaks/mobilegestalt/GestaltView.swift
	@grep -Fq 'Bundle.main.infoDictionary' ThirdParty/mond-current/Upstream/views/app/SettingsView.swift

	@test -f FilzaSupportPrompt.m || (echo "Missing Filza Buy Me a Coffee support replacement" >&2; exit 1)
	@grep -Fq 'https://buymeacoffee.com/zyn3' FilzaSupportPrompt.m
	@grep -Fq 'Support Zyn' FilzaSupportPrompt.m
	@grep -Fq 'Buy me a coffee' FilzaSupportPrompt.m
	@grep -Fq 'Activate Filza' FilzaSupportPrompt.m

	@bash scripts/stage-byetunes-youtubekit.sh
	@bash scripts/patch-byetunes-youtubekit-primary.sh
	@bash scripts/patch-byetunes-manage-backups-typecheck.sh
	@test -f "$(BYETUNES_YTK_ROOT)/YouTube.swift" || (echo "Missing pinned pre-v2.4 YouTubeKit" >&2; exit 1)
	@grep -Fq 'let youtube = YouTube(videoID: videoID)' ByeTunesMetadataCompat.swift
	@grep -Fq '[YouTubeProvider] YouTubeKit metadata matched videoID=' ByeTunesMetadataCompat.swift
	@grep -Fq 'FILZA_MANAGE_BACKUPS_TYPECHECK_SPLIT' ByeTunes/MusicManager/ManageBackupsView.swift

	@test -f "ByeTunes/MusicManager/MetadataBackgroundURLSession.swift" || (echo "Missing upstream ByeTunes metadata transport" >&2; exit 1)
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(from: url)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await MetadataBackgroundURLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'FilzaMetadataWebRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'retrying through WebKit network process' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'MetadataWebKitRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift

# Retired DNS/WebKit workaround remains intentionally unused:
# scripts/patch-byetunes-metadata-network-resilience.sh
