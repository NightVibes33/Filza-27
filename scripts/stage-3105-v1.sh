#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105"
UPSTREAM_OWNER="NightVibes33"
UPSTREAM_REPO="3105"
UPSTREAM_COMMIT="438f3ccae6a436d0017185407bc286e55c357883"
ARCHIVE_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_COMMIT}"

for path in "$ROOT" "$ROOT/Sources" "$ROOT/Resources/Filza3105.bundle"; do
  test -d "$path" || { echo "Missing 3105 integration path: $path" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-3105-v1.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 "$ARCHIVE_URL" -o "$TMP/3105.tar.gz"
tar -xzf "$TMP/3105.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name '3105-*' -print -quit)"
test -n "$SRC" || { echo "Could not locate extracted 3105 source tree" >&2; exit 1; }
UPSTREAM="$SRC/ThreeOneOSFive"

test -f "$UPSTREAM/helpers/FileOperationCoordinator.swift"
test -f "$UPSTREAM/helpers/ZIPArchiveWriter.swift"
test -f "$UPSTREAM/views/FileBrowserView.swift"
test -f "$UPSTREAM/views/PatchProjectsView.swift"
test -f "$UPSTREAM/Info.plist"

copy_source() {
  local relative="$1"
  local destination="$2"
  test -f "$UPSTREAM/$relative" || { echo "Missing upstream 3105 file: $relative" >&2; exit 1; }
  cp "$UPSTREAM/$relative" "$ROOT/Sources/$destination"
}

# Files changed by upstream 1.0. Unchanged Filza-adapted files remain in place.
copy_source helpers/AppIconHelper.m AppIconHelper.m
copy_source helpers/CleanerCatalog.swift CleanerCatalog.swift
copy_source helpers/ContainerBrowserLogic.swift ContainerBrowserLogic.swift
copy_source helpers/ContainerStore.swift ContainerStore.swift
copy_source helpers/FileManagerService.swift FileManagerService.swift
copy_source helpers/FileOperationCoordinator.swift FileOperationCoordinator.swift
copy_source helpers/PatchDraftCoordinator.swift PatchDraftCoordinator.swift
copy_source helpers/PatchDraftService.swift PatchDraftService.swift
copy_source helpers/PatchPackageCodec.swift PatchPackageCodec.swift
copy_source helpers/PatchProjectLibrary.swift PatchProjectLibrary.swift
copy_source helpers/PatchProjectModels.swift PatchProjectModels.swift
copy_source helpers/PatchProjectStore.swift PatchProjectStore.swift
copy_source helpers/PatchTransaction.swift PatchTransaction.swift
copy_source helpers/ZIPArchiveWriter.swift ZIPArchiveWriter.swift
copy_source views/AppDataBrowserView.swift AppDataBrowserView.swift
copy_source views/CleanerView.swift CleanerView.swift
copy_source views/FileBrowserView.swift FileBrowserView.swift
copy_source views/FolderPatchSelectionView.swift FolderPatchSelectionView.swift
copy_source views/PatchProjectEditorView.swift PatchProjectEditorView.swift
copy_source views/PatchProjectsView.swift PatchProjectsView.swift
copy_source views/WallpaperLabView.swift WallpaperLabView.swift

for lang in en vi zh-Hans; do
  test -f "$UPSTREAM/$lang.lproj/Localizable.strings"
  mkdir -p "$ROOT/Resources/Filza3105.bundle/$lang.lproj"
  cp "$UPSTREAM/$lang.lproj/Localizable.strings" \
     "$ROOT/Resources/Filza3105.bundle/$lang.lproj/Localizable.strings"
done

# Keep a copy of upstream 1.0's app metadata for deterministic IPA merging.
cp "$UPSTREAM/Info.plist" "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist"

# Fail closed if the source refresh did not actually bring in 1.0 behavior.
grep -Fq 'FileOperationCoordinator' "$ROOT/Sources/FileBrowserView.swift"
grep -Fq 'importPackage(from:' "$ROOT/Sources/PatchProjectsView.swift"
grep -Fq 'PatchImportSource' "$ROOT/Sources/PatchDraftCoordinator.swift"
grep -Fq 'ZIPArchiveWriter' "$ROOT/Sources/FileManagerService.swift"
grep -Fq 'bulk' "$ROOT/Resources/Filza3105.bundle/en.lproj/Localizable.strings"
plutil -lint "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist" >/dev/null

echo "Staged 3105 1.0 from ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_COMMIT}"
