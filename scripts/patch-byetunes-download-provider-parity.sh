#!/usr/bin/env bash
set -euo pipefail

# Keep upstream ByeTunes 2.5 as the baseline, but make the embedded AirCard
# branch resilient when the configured provider returns a server-side 500.
# The official v2.5 path already maps non-Spotify sources to Spotify; the hole is
# that a Spotify-resolved source has no alternate-provider retry and terminates.
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"
test -f "$DOWNLOAD"

python3 - "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = r'''        if resolvedSource.platform != .spotify {
            log("Attempting last-resort Spotify mapping for \(track.name)...")
            do {
                let seed = mappingSeedURL(for: track.sourceURL)
                let spotifyURL = try await fetchMappedURL(for: seed, platform: .spotify)
                log("Mapped to Spotify for last-resort retry: \(spotifyURL)")

                let spotifySource = DownloadSourceChoice(
                    platform: .spotify,
                    url: spotifyURL,
                    backendGenreSource: DownloadPlatform.spotify.backendGenreSource
                )
                let spotifyCandidates = try await primaryCandidates(for: spotifySource, track: track)
                if !spotifyCandidates.isEmpty {
                    if let outcome = try await executeCandidatesUntilSuccess(
                        spotifyCandidates,
                        trackID: track.id,
                        suggestedName: "\(track.artistLine) - \(track.name)",
                        fallbackExtension: "flac"
                    ) {
                        return outcome
                    }
                }
            } catch {
                log("Last-resort Spotify mapping failed: \(error.localizedDescription)")
            }
        }

        throw DownloadError.mappingFailed("All configured download backends failed.")
'''

new = r'''        let alternatePlatforms: [DownloadPlatform]
        switch resolvedSource.platform {
        case .spotify:
            alternatePlatforms = [.deezer, .appleMusic]
        case .deezer:
            alternatePlatforms = [.spotify, .appleMusic]
        case .appleMusic:
            // primaryCandidates already adds an Apple Music -> Spotify pair,
            // so try Deezer next before giving up.
            alternatePlatforms = [.deezer]
        default:
            alternatePlatforms = [.spotify, .deezer, .appleMusic]
        }

        for alternatePlatform in alternatePlatforms {
            guard alternatePlatform != resolvedSource.platform else { continue }
            log("Attempting alternate-provider fallback via \(alternatePlatform.displayName) for \(track.name)...")
            do {
                let seed = mappingSeedURL(for: track.sourceURL)
                let mappedURL = try await fetchMappedURL(for: seed, platform: alternatePlatform)
                log("Mapped to \(alternatePlatform.displayName) for fallback retry: \(mappedURL)")

                let alternateSource = DownloadSourceChoice(
                    platform: alternatePlatform,
                    url: mappedURL,
                    backendGenreSource: alternatePlatform.backendGenreSource
                )
                let alternateCandidates = try await primaryCandidates(for: alternateSource, track: track)
                if !alternateCandidates.isEmpty,
                   let outcome = try await executeCandidatesUntilSuccess(
                       alternateCandidates,
                       trackID: track.id,
                       suggestedName: "\(track.artistLine) - \(track.name)",
                       fallbackExtension: "flac"
                   ) {
                    return outcome
                }
            } catch {
                if Task.isCancelled {
                    throw error
                }
                log("Alternate-provider fallback via \(alternatePlatform.displayName) failed: \(error.localizedDescription)")
            }
        }

        throw DownloadError.mappingFailed("All configured download backends failed.")
'''

if new in text:
    print("ByeTunes embedded alternate-provider fallback already installed")
elif old in text:
    path.write_text(text.replace(old, new, 1))
    print("Installed ByeTunes embedded alternate-provider fallback")
else:
    raise SystemExit("ByeTunes 2.5 fallback anchor changed; refusing an unverified patch")
PY

grep -Fq 'Attempting alternate-provider fallback via' "$DOWNLOAD"
grep -Fq 'alternatePlatforms = [.deezer, .appleMusic]' "$DOWNLOAD"
echo "Verified ByeTunes embedded alternate-provider fallback"
