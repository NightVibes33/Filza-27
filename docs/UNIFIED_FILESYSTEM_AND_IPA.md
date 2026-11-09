# Filza 27 unified filesystem and Erosion IPA flow

Integration snapshot: 2026-11-09. Target: iOS 18–27, with iOS 27.0.1 device verification outstanding.

## Sources and licensing

- WQFiles (kolbicz/WQFiles, GPL-3.0): https://github.com/kolbicz/WQFiles
  - Independently implemented the dynamic `fsgetpath` inode-discovery strategy.
  - No WQFiles source files, icons, or UI were copied.
  - Underlying `forcequitOS/worse_query` sources are already vendored with their GPL-3.0 license. Follow those obligations when distributing modified binaries.
- Erosion (ceoca69/erozzion-mod): https://github.com/ceoca69/erozzion-mod
  - AppsManagementView.swift is the functional reference for the two-action `Prepare` / `Decrypt` flow.
  - Erosion's `Prepare`: InstallationProxy bundle metadata → Airlift `al_exploit_read_folder` snapshot of remote `.app` → persist extracted `.app` plus manifest.
  - Erosion's `Decrypt`: package the prepared `.app` into an IPA with `Payload/<bundle>.app`. It **does not decrypt FairPlay**.
  - No Erosion app tab or separate browser is added.
- Ketamine (Nouvborne/Ketamine): https://github.com/Nouvborne/Ketamine
  - MobileGestalt/PosterBoard and backup/rollback behavior are reviewed as defensive design references.
  - Its original bad_query beta support does not establish iOS 27.0.1 access; original Mond bad_query/CMG logic is retained instead.

## One native browser and one verified access model

- Native Filza `TGFileSystemListViewController` and its existing file actions remain the UI.
- `FZContainerDiscovery` scans data-volume inode IDs once off the UI thread using an APFS probe-based upper bound, caches **candidate paths only**, and notifies original Filza and 3105 on completion.
- The native MCM links remain first. `bad_query`/CMG continue supporting older compatible builds.
- `worse_query` is attempted only for supported paths after real sandbox verification; the signed disposable App Group is required. Sandbox extension handles are bounded and cannot be passed to `bad_query_release`.
- Verified container aliases go in the existing Device Storage sections, never in an extra browser. Symlink target navigation renews expired grants.
- Paired Airlift produces read-only local folder snapshots through the original browser, not a live writable mount.
- Mond uses the existing sources; WQ fallbacks for app, PosterBoard, and MobileGestalt system-group paths require actual file-access verification. Merely finding a path is never success.
- Cleaner keeps upstream 3105's main layout, `Library/Caches` and `tmp` only, measured open/read roots only. Inaccessible does not equal zero-byte cache.
- NFCARD/other integrated features and existing iOS 18.5 kernel flow remain unchanged.

## Safety gates

- The original Airlift remote-folder restoration stop remains independent from local WQ grants and still blocks unsafe remote reads.
- `SecureZIPArchive` rejects path traversal and symbolic-link entries for prepared IPA snapshots; existing destination folders are not overwritten by extraction.
- IPA preparation saves verified .app bundles and a manifest; it does not claim to decrypt FairPlay.
- No silent writes based on InstallationProxy metadata, raw inode discovery, or unconfirmed sandbox token return.

## Verification

The GitHub ARM64 workflow is the packaging gate; the upstream-staged 3105 verification and source-integrity checks must pass. Only a real iOS 27.0.1 on-device trial can verify another app's live folder access and Airlift's restoration behavior. The build's `filza27.ipa` must be verified as an IPA archive before distribution.
