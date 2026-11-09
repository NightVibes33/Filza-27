# ByeTunes 2.5 integration fragment.
# Keep upstream ByeTunes provider/download behavior intact; Filza-specific
# embedding, pairing, 3105, Mond, and support integration remain below.

# 3105 1.1.1 stages its updated sandbox_escape.m at the repository root, while
# that upstream translation unit keeps the original quoted kexploit header names.
FilzaApplySandboxExt_CFLAGS += -I$(PWD)/kexploit

# XPF's common/PatchFinder code calls the arm64-specific ChOma helpers.
FilzaApplySandboxExt_FILES += XPF/external/ChOma/src/PatchFinder_arm64.c

# Upstream Mond resolves these private Sandbox SPI calls dynamically. Keep the
# existing forwarding ABI bridge used by the combined target.
FilzaApplySandboxExt_FILES += MondSandboxSPICompat.c

# Replace Filza's legacy activation/payment presentation with voluntary support UI.
FilzaApplySandboxExt_FILES += FilzaSupportPrompt.m

before-FilzaApplySandboxExt-all::
	# Add Apps Manager IPA repackaging/export integration.
	@bash scripts/patch-3105-ipa-export.sh
	@test -f scripts/patch-3105-ipa-export.sh || (echo "Missing 3105 IPA export patch" >&2; exit 1)
	@grep -Fq 'Label("Prepare", systemImage:' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'Label("Decrypt", systemImage:' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FilzaAirliftIPAExporter.prepare(remote)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FilzaAirliftIPAExporter.prepare(remote)' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FilzaAirliftIPAExporter.makeIPA(' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'static func writeIPA(' ThirdParty/3105/Sources/ZIPArchiveWriter.swift
	@grep -Fq 'archiveRootName: "Payload/' ThirdParty/3105/Sources/ZIPArchiveWriter.swift
	@grep -Fq 'filzaAppBundlePathForBundleID' ThirdParty/3105/Sources/AppIconHelper.h
	@test -f ThirdParty/3105/Sources/FilzaAppIPAExporter.swift
	@test -f Filza3105IPAExportBridge.m

	# Preserve the existing View / Sort menu and default 3105 row behavior.
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
	@grep -Fq 'Label("Prepare", systemImage:' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'Label("Decrypt", systemImage:' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FilzaAirliftIPAExporter.prepare(remote)' ThirdParty/3105/Sources/AppDataBrowserView.swift

	# Bridge Erosion/Airlift into the actual 3105 Cleaner and Wallpaper UI.
	@python3 scripts/patch-3105-erosion-features.py
	# Preserve main Cleaner exactly; WQ is a backend-only, verified cache-root fallback.
	# Airlift/NFCARD remain available in the original native Filza file browser.
	@python3 scripts/patch-3105-cleaner-all-apps.py
	@python3 scripts/patch-3105-worse-query.py
	@python3 scripts/patch-3105-wq-discovery.py
	@python3 scripts/patch-3105-paired-cache-catalog.py
	@grep -Fq 'scanNewApps(pairedApps)' ThirdParty/3105/Sources/CleanerView.swift
	@grep -Fq 'FILZA_WQFILES_DYNAMIC_DISCOVERY' ThirdParty/3105/Sources/ContainerStore.swift
	@grep -Fq 'FILZA_MAIN_CLEANER_PARITY' ThirdParty/3105/Sources/CleanerView.swift
	@grep -Fq 'FZWorseQueryGrantDirectory(candidate)' ThirdParty/3105/Sources/CleanerView.swift
	@! grep -Fq 'allCleanerRecords' ThirdParty/3105/Sources/CleanerView.swift
	@! grep -Fq 'remoteMessages' ThirdParty/3105/Sources/CleanerView.swift
	@! grep -Fq 'airliftCatalog' ThirdParty/3105/Sources/CleanerView.swift
	@test -f FilzaAirliftCleaner.swift
	@grep -Fq 'FILZA_EROSION_WALLPAPER_BRIDGE' ThirdParty/3105/Sources/WallpaperLabView.swift
	@grep -Fq 'FilzaErosionPosterBoardWriter.apply' ThirdParty/3105/Sources/WallpaperLabView.swift
	@test -f FilzaErosionPosterBoardWriter.swift
	@grep -Fq 'al_exploit_inject_folder' "$(NFCARD_FFI)/include/AirliftFFI/airlift.h" || (echo "Erosion PosterBoard folder-injection API missing from compiled AirliftFFI" >&2; exit 1)
	@grep -Fq 'al_find_app_container' "$(NFCARD_FFI)/include/AirliftFFI/airlift.h" || (echo "Erosion app-container lookup API missing from compiled AirliftFFI" >&2; exit 1)

	# 3105 is a pairing consumer. Filza main Settings owns both setup methods.
	@grep -Fq 'ThreeOneOSFiveSettingsView()' ThirdParty/3105/Sources/ThreeOneOSFiveContentView.swift
	@! grep -Fq 'struct Filza3105PairingSettingsSection' ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift
	@grep -Fq 'FilzaUnifiedPairingHostFactory' FilzaUnifiedPairing.swift

	# Preserve optimized persistent-client 3105 icon glue.
	@bash scripts/patch-3105-icon-performance.sh
	@test -f scripts/patch-3105-icon-performance.sh || (echo "Missing 3105 icon performance patch" >&2; exit 1)
	@grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' ThirdParty/3105/Sources/AppDataBrowserView.swift
	@grep -Fq 'FILZA_SBS_ICON_WORKERS 3' ThirdParty/3105/Sources/AppIconHelper.m
	@grep -Fq 'FilzaEnsureRSDIconClientLocked' ThirdParty/3105/Sources/AppIconHelper.m

	# Preserve current embedded Mond integration.
	@bash scripts/verify-mond-source-completeness.sh
	@bash scripts/stage-mond-embedded-resources.sh
	@bash scripts/patch-mond-embedded-parity.sh
	@python3 scripts/patch-mond-worse-query-routing.py
	@grep -Fq 'FILZA_MOND_WQ_CONTAINER_FALLBACK' ThirdParty/mond-current/Generated/Mond/exploit_unsbx.swift
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

	# ByeTunes 2.5 owns its current provider/download stack. Do not stage or patch
	# the retired pre-v2.4 YouTubeKit implementation. Keep only the independent
	# compiler adaptation if this combined target still requires it.
	@bash scripts/patch-byetunes-manage-backups-typecheck.sh
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
