#!/usr/bin/env python3
"""Use separately bounded, symlink-safe app snapshot extraction.

The upstream SecureZIPArchive's 512 MiB / 768 MiB wallpaper limits are
appropriate for wallpaper packs, not ordinary iOS app bundles. Keep the
wallpaper call sites at their original limits and extend ONLY IPA snapshots.
ZIP32, traversal, duplicate path and symlink validation remain enforced.
"""
from pathlib import Path

path = Path("ThirdParty/3105/Sources/SecureZIPArchive.swift")
text = path.read_text(encoding="utf-8")
if "FILZA_IPA_SNAPSHOT_EXTRACTION_LIMITS" in text:
    print("IPA-specific ZIP limits already staged")
    raise SystemExit(0)

def one(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"IPA extraction {label}: expected 1 anchor, got {count}")
    text = text.replace(old, new, 1)

one(
    "    private static let endSignature: UInt32 = 0x0605_4b50\n",
    """    private static let endSignature: UInt32 = 0x0605_4b50

    // FILZA_IPA_SNAPSHOT_EXTRACTION_LIMITS
    private struct ExtractionLimits {
        let archiveBytes: Int64
        let expandedBytes: Int64
        let entryBytes: Int64
        let entryCount: Int
        let pathBytes: Int
    }
    private static let wallpaperLimits = ExtractionLimits(
        archiveBytes: WallpaperLabLimits.maximumArchiveBytes,
        expandedBytes: WallpaperLabLimits.maximumExpandedBytes,
        entryBytes: WallpaperLabLimits.maximumEntryBytes,
        entryCount: WallpaperLabLimits.maximumEntryCount,
        pathBytes: WallpaperLabLimits.maximumPathBytes
    )
    // ZIP32-only: do not silently pretend ZIP64 is supported.
    private static let applicationLimits = ExtractionLimits(
        archiveBytes: 3 * 1_024 * 1_024 * 1_024,
        expandedBytes: 5 * 1_024 * 1_024 * 1_024,
        entryBytes: 3 * 1_024 * 1_024 * 1_024,
        entryCount: 60_000,
        pathBytes: 4_096
    )
""", "limits definitions")

one(
    "        fileManager: FileManager = .default\n    ) throws -> SecureZIPExtraction {\n",
    """        fileManager: FileManager = .default,
        appSnapshot: Bool = false
    ) throws -> SecureZIPExtraction {
        let limits = appSnapshot ? applicationLimits : wallpaperLimits
""", "backward-compatible extractor signature")

for before, after in (
    ("              archiveSize <= WallpaperLabLimits.maximumArchiveBytes else {", "              archiveSize <= limits.archiveBytes else {"),
    ("        let entries = try readEntries(handle: handle, archiveSize: UInt64(archiveSize))", "        let entries = try readEntries(handle: handle, archiveSize: UInt64(archiveSize), limits: limits)"),
    ("        guard entries.count <= WallpaperLabLimits.maximumEntryCount,", "        guard entries.count <= limits.entryCount,"),
    ("              expandedBytes <= UInt64(WallpaperLabLimits.maximumExpandedBytes) else {", "              expandedBytes <= UInt64(limits.expandedBytes) else {"),
    ("        archiveSize: UInt64\n    ) throws -> [Entry] {", "        archiveSize: UInt64,\n        limits: ExtractionLimits\n    ) throws -> [Entry] {"),
    ("              Int(entryCount) <= WallpaperLabLimits.maximumEntryCount,", "              Int(entryCount) <= limits.entryCount,"),
    ("                  nameLength <= WallpaperLabLimits.maximumPathBytes,", "                  nameLength <= limits.pathBytes,"),
    ("                  UInt64(uncompressedSize) <= UInt64(WallpaperLabLimits.maximumEntryBytes) else {", "                  UInt64(uncompressedSize) <= UInt64(limits.entryBytes) else {"),
    ("            guard totalExpanded <= UInt64(WallpaperLabLimits.maximumExpandedBytes) else {", "            guard totalExpanded <= UInt64(limits.expandedBytes) else {"),
    ("            let components = try safeComponents(rawName, isDirectory: isDirectory)", "            let components = try safeComponents(rawName, isDirectory: isDirectory, maxPathBytes: limits.pathBytes)"),
    ("        isDirectory: Bool\n    ) throws -> [String] {", "        isDirectory: Bool,\n        maxPathBytes: Int\n    ) throws -> [String] {"),
    ("              rawName.utf8.count <= WallpaperLabLimits.maximumPathBytes else {", "              rawName.utf8.count <= maxPathBytes else {"),
):
    one(before, after, before[:65])

assert text.count("WallpaperLabLimits.") == 5  # only the original wallpaperLimits
assert "entryCount: 60_000" in text
assert "appSnapshot: Bool = false" in text
path.write_text(text, encoding="utf-8")
print("GREEN: app snapshots use separate bounded ZIP32 limits; wallpaper safety unchanged")
