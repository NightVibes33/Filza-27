# ByeTunes Local Yoink Plan

Branch: `experiment/aircard-main-sync`

## Non-negotiable architecture

Yoink remains the canonical backend source. We do not invent a second downloader implementation.

Pinned upstream:

- Repository: `yoinkify/yoink`
- Commit: `061e33ffc8d5050f828196bb78f7034f817e1e2e`
- License: AGPL-3.0

The existing Filza/ByeTunes runtime remains untouched until the local implementation passes parity tests.

## What is actually different from upstream Yoink

Observed `api.byetunes.xyz` behavior is Yoink-compatible but adds direct Deezer URL handling.

Required compatibility delta:

1. `detectPlatform()` recognizes:
   - Spotify
   - Apple Music
   - Deezer
2. `resolveTrack()` accepts a direct Deezer track URL and builds the same normalized `TrackInfo`.
3. `/api/download` and `/api/metadata` return the observed ByeTunes-compatible validation/error behavior for direct Deezer URLs.
4. Everything else stays sourced from the pinned Yoink code unless parity testing proves another difference.

## Why the Next.js server cannot simply be launched inside iOS

The Yoink HTTP route uses Node/Next.js plus Node-only facilities such as `child_process`, `fs/promises`, temporary directories, environment variables, Buffers, ffmpeg invocation, and yt-dlp fallbacks.

iOS cannot reliably run that Linux/Node process model inside Filza.

The correct solution is to embed the portable Yoink core, not recreate it.

## Target architecture

```
ByeTunes UI
    |
    v
ByeTunesBackendTransport
    |
    +-- LocalYoinkTransport (default during experiment)
    |       |
    |       v
    |   YoinkRuntime (JavaScriptCore)
    |       |
    |       +-- bundled Yoink resolver/metadata/source logic
    |       +-- direct-Deezer compatibility patch
    |       |
    |       +-- Swift host bridges
    |             +-- URLSession HTTP/fetch
    |             +-- FileManager temporary storage
    |             +-- configuration/secrets provider
    |             +-- native FFmpeg bridge
    |
    +-- RemoteByeTunesTransport (fallback while testing)
            |
            v
       api.byetunes.xyz
```

The production path should eventually call `LocalYoinkTransport` directly. A localhost HTTP listener is optional for compatibility testing only; Filza should not depend on an in-app HTTP daemon remaining alive while iOS suspends the app.

## Source layout to add

```
ByeTunesLocal/
  Upstream/
    yoink.lock
    patches/
      0001-byetunes-direct-deezer.patch
  Build/
    build-yoink-core.mjs
    yoink-core-entry.ts
  Runtime/
    YoinkRuntime.swift
    YoinkFetchBridge.swift
    YoinkFileBridge.swift
    YoinkConfigBridge.swift
    YoinkFFmpegBridge.swift
    YoinkModels.swift
  Transport/
    ByeTunesBackendTransport.swift
    LocalYoinkTransport.swift
    RemoteByeTunesTransport.swift
  Resources/
    yoink-core.js
```

The generated `yoink-core.js` must never be hand-edited. CI recreates it from the pinned Yoink commit plus our reviewed compatibility patch.

## Phase 1 — Pin and reproduce upstream

1. Add `yoink.lock` containing the exact upstream repository and commit.
2. CI checks out that exact Yoink revision.
3. CI verifies the expected upstream file hashes before applying patches.
4. Apply only the direct-Deezer compatibility patch.
5. Run upstream Yoink tests.
6. Add contract tests using the existing `.github/workflows/byetunes-api-surface.yml` observations.

Gate: patched Yoink must reproduce the known public contract without changing Filza runtime code.

## Phase 2 — Direct Deezer compatibility patch

Patch the pinned Yoink source, not Filza's downloader.

Changes are restricted to:

- `src/lib/spotify.ts`: add `deezer` to platform detection.
- `src/lib/resolve-track.ts`: resolve direct Deezer track URLs with Yoink's existing `fetchDeezerTrackMetadata()`.
- API validation text/behavior where needed to match `api.byetunes.xyz`.

Do not replace Yoink's existing Spotify/Apple Music resolver chains.

Gate:

- invalid URL -> same HTTP/status/error shape as Edu API
- nonexistent Deezer track -> same 404 shape
- valid Deezer metadata -> normalized TrackInfo
- existing Spotify/Apple Music behavior does not regress

## Phase 3 — Build an embeddable Yoink core

Use esbuild (or equivalent deterministic bundling in CI) to create one JavaScriptCore-compatible bundle from the pinned Yoink modules.

Initially include only the portable path required for metadata:

- platform detection
- Spotify URL parsing/resolution
- Apple Music/iTunes resolution
- Song.link resolution
- Deezer metadata resolution/search
- normalized TrackInfo models

Replace Node globals through narrow host adapters rather than changing resolver behavior.

Gate: the same metadata fixtures produce equivalent normalized output in Node Yoink and embedded JavaScriptCore.

## Phase 4 — iOS JavaScriptCore runtime

Add `YoinkRuntime.swift`.

Responsibilities:

- own a dedicated serial JavaScriptCore context
- load the generated `yoink-core.js`
- expose typed async calls such as:
  - `resolveTrack(url:)`
  - `metadata(url:)`
  - later `prepareDownload(...)`
- convert JS results to Codable Swift models
- enforce timeouts/cancellation
- never execute arbitrary user-provided JavaScript

Gate: Filza can resolve Deezer, Spotify, and Apple Music test URLs locally without touching `api.byetunes.xyz`.

## Phase 5 — Native host bridges

Implement only the Node facilities the bundled Yoink core actually needs.

### Network bridge

Yoink `fetch()` -> Swift `URLSession`.

Must support:

- GET/POST/HEAD
- redirects
- request headers/body
- response status/headers/body
- cancellation
- background download tasks where appropriate

### Configuration bridge

Replace `process.env.*` access with a controlled Swift configuration provider.

No credentials are committed to GitHub.

### Files bridge

Map temporary-file operations to the app's temporary/container directories using `FileManager`.

### Binary bridge

Use Data/ArrayBuffer transfers instead of unnecessary base64 copies for large audio buffers.

Gate: portable Yoink code sees equivalent host behavior without a Node process.

## Phase 6 — Audio path

Keep Yoink's source-selection policy as the source of truth.

The iOS host supplies the pieces that cannot run as Node subprocesses.

- direct HTTP media transfers -> URLSession
- ffmpeg process invocation -> linked native FFmpeg/libav wrapper
- temporary files -> FileManager
- unsupported CLI-only fallbacks -> explicitly isolated; do not silently replace the source-selection policy

Do not redesign the provider order unless a parity test demonstrates Edu's API differs from pinned Yoink.

Gate:

- MP3 path
- FLAC path where the configured source legitimately provides it
- metadata tagging
- artwork embedding
- lyrics handling
- cancellation
- cleanup after failures

## Phase 7 — Transport abstraction in existing ByeTunes client

Introduce:

```swift
protocol ByeTunesBackendTransport {
    func metadata(for url: URL) async throws -> ...
    func download(_ request: ...) async throws -> ...
}
```

Implement:

- `RemoteByeTunesTransport`: current behavior, unchanged.
- `LocalYoinkTransport`: calls `YoinkRuntime`.

Temporary branch default:

```
Local Yoink -> remote fallback
```

Production target after parity:

```
Local Yoink only
```

This avoids rewriting the existing queue/UI code and gives an immediate rollback during testing.

## Phase 8 — Background behavior

Do not rely on a localhost server remaining alive.

Use the existing ByeTunes queue plus background-capable URLSession transfers.

Local processing resumes when the app receives execution time. Persist enough state to recover interrupted jobs after relaunch.

Gate:

- foreground download
- screen lock
- app backgrounding
- app kill/relaunch recovery
- queue with multiple tracks
- cancellation during each stage

## Phase 9 — Contract/parity matrix

Every release candidate must compare local behavior with the observed ByeTunes API contract.

Test matrix:

- Deezer direct track
- Spotify track
- Apple Music track
- malformed URL
- nonexistent track
- MP3
- FLAC
- MP3 fallback
- artwork
- standard lyrics
- synced lyrics
- explicit flag
- track/disc numbers
- source/quality headers or equivalent internal metadata
- timeout
- cancellation
- multi-download queue

Failures must identify whether the difference is:

- upstream Yoink
- ByeTunes compatibility patch
- JS runtime bridge
- native audio bridge
- existing ByeTunes client

## Phase 10 — Cutover

Only after all parity gates pass:

1. switch the experimental IPA to local-first with remote disabled
2. run cold-install and upgrade tests
3. confirm no runtime request reaches `api.byetunes.xyz`
4. keep the remote transport in source for one rollback cycle
5. only then consider merging the local backend work toward main

## CI gates

Add jobs that fail closed on:

1. wrong Yoink upstream commit
2. unexpected upstream file hash
3. compatibility patch fails to apply
4. upstream Yoink tests fail
5. Yoink-core bundle generation differs unexpectedly
6. JavaScriptCore metadata fixtures fail
7. iOS build fails
8. contract fixtures differ
9. existing ByeTunes source is modified outside approved integration points

## First implementation milestone

Do not start with ffmpeg.

First milestone is:

```
pinned Yoink source
+ direct Deezer patch
+ generated yoink-core.js
+ JavaScriptCore runtime
+ local metadata for Deezer/Spotify/Apple Music
+ existing remote backend untouched
```

Once that is green, move the audio path on-device.

## Definition of done

This work is complete only when:

- Filza/ByeTunes no longer requires a deployed downloader server
- each device performs its own backend work
- resolver/source behavior remains traceable to the pinned Yoink source
- direct Deezer behavior matches the observed ByeTunes API
- Spotify and Apple Music do not regress
- existing download queue/background/recovery behavior still works
- no app runtime dependency on `api.byetunes.xyz`
- main was not changed during development
