# ByeTunes network/provider compatibility fragment.
#
# The v2.4 app remains the primary ByeTunes source tree. All Sources importing,
# the song editor, and v2.4 metadata selection are intentionally untouched.
# Only the YouTube provider regains the exact vendored YouTubeKit implementation
# that shipped in NightVibes33/ByeTunes before the v2.4 migration.

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

before-FilzaApplySandboxExt-all::
	@bash scripts/stage-byetunes-youtubekit.sh
	@bash scripts/patch-byetunes-youtubekit-primary.sh
	@bash scripts/patch-byetunes-manage-backups-typecheck.sh
	@test -f "$(BYETUNES_YTK_ROOT)/YouTube.swift" || (echo "Missing pinned pre-v2.4 YouTubeKit" >&2; exit 1)
	@test -f "$(BYETUNES_YTK_ROOT)/InnerTube.swift" || (echo "Incomplete pinned pre-v2.4 YouTubeKit" >&2; exit 1)
	@test -f "$(BYETUNES_YTK_ROOT)/Resources/meriyah.umd.js" || (echo "Incomplete pinned YouTubeKit resources" >&2; exit 1)
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
