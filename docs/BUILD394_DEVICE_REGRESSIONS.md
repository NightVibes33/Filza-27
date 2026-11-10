# Build 394 on-device regression: verified observations and next release gates

Based on the user's Filza runtime diagnostic supplied November 9, 2026.
This document deliberately excludes personal paths, pairing records, and app identifiers.

## Verified observations

- Cleaner scanned 341 InstallationProxy app-data candidates. It reported
  81 cache-positive apps, but the first pass required about 45 seconds and
  a second pass started immediately afterward.
- The asynchronous filesystem discovery attempted approximately 178 million
  inode numbers, taking more than eight minutes. It found 2,212 candidate
  paths; a later phase granted/linked those paths.
- Over 9,500 success events were written through Runtime.log's synchronous
  open / seek / write / synchronize / close routine.
- IPA Prepare failed at the remote AirTraffic/ATC manifest stage with
  `read length: channel closed`. There was no completed local .app snapshot,
  so local ZIP and Info.plist changes cannot resolve this failure alone.
- A separate Airlift operation later reported that the remote directory
  restoration had not been confirmed. Never clear the remote safety stop
  based solely on the fact that a new IPA was installed.
- Mond reported MG=true, Apps=true, PosterBoard=false. This is a partial
  grant result, not a global unsupported-device result.

## Implemented performance changes in the subsequent source update

- Cleaner waits for its already-requested paired catalog before the first
  long cache scan; a late inode discovery cannot automatically trigger a
  redundant scan once positive results already exist.
- Cleaner performs a lightweight root-enumeration accessibility check
  before its single recursive usage measurement; the UI and safe cleanup
  scope remain unchanged.
- The inode scanner uses no more than four utility-priority workers, saves
  a verified metadata-only cache keyed to filesystem ID and probe inode,
  and scans only newer object IDs on future launches (full refresh weekly).
- A prior completed scan logged by an existing Filza installation can
  bootstrap candidate metadata for migration, subject to minimum completed
  scan counts; all actual grants are verified again.
- WQ success logging is summarized every 128 successes instead of forcing
  a synchronous filesystem flush per directory. Error and recovery logs
  remain immediately recorded.
- Filza's own AirliftFFI calls are serialized to avoid overlapping remote
  sessions, with elapsed duration and explicit ATC failure classification.

## Release acceptance criteria

1. Mac runner builds a valid unsigned arm64 IPA and 3105 shared UI passes.
2. Device shows the expected app data and system directories promptly from
   a verified cached/paired catalog. No claim of full root access.
3. Cleaner scan durations and count of repeated rescans are measured on the
   actual iPhone. Positive rows correspond to accessible cache roots.
4. Prepare must deliver a verified .app folder from the remote service;
   Decrypt must produce Payload/<app>.app without claiming FairPlay removal.
   If ATC fails, do not claim a successful IPA or retry while recovery is
   unconfirmed.
5. Mond must report MG, Apps, and PosterBoard grants individually.

A green GitHub workflow demonstrates compilation, not device-level exploit
or IPA Prepare success. The ATC and PosterBoard failures require new
on-device evidence before they can be marked resolved.

## CI validation request

- A docs-only push requests a fresh feature-branch GitHub Actions run for the complete consolidated Filza 27 changes. It does not modify runtime behavior or signify on-device validation.
