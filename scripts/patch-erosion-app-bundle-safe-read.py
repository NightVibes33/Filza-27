#!/usr/bin/env python3
"""Route installed .app snapshots through Erosion's recovery-aware reader.

The pinned Erosion reader already has a recovery-aware implementation for
Containers. Its legacy fallback for Bundle/Application/*.app returns directly
on ATC staging failures, without reaching that newer recovery attempt. Limit
this change to a real UUID/<name>.app location and leave other routes intact.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-erosion-app-bundle-safe-read.py <exploit.rs>")
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
marker = "FILZA_AIRLIFT_APP_BUNDLE_SAFE_ROUTE"
if marker in source:
    print("Airlift app-bundle recovery route already patched")
    raise SystemExit(0)

before = '''    if trimmed == "/var/mobile/Containers"
        || trimmed.starts_with("/var/mobile/Containers/")
    {
        exploit_read_folder_safe(pairing_path, target_dir, logger).await
    } else {
        // Restore the established first-source reader for other non-Media paths.
        exploit_read_folder_legacy(pairing_path, target_dir, logger).await
    }'''
after = '''    // FILZA_AIRLIFT_APP_BUNDLE_SAFE_ROUTE
    // Apply the recovery-aware reader ONLY to a direct installed .app bundle.
    // The legacy path returned immediately on ATC manifest errors, before
    // attempting the recovery-aware original-object restoration.
    let canonical = trimmed.strip_prefix("/private").unwrap_or(trimmed);
    let is_installed_app_bundle = canonical
        .strip_prefix("/var/containers/Bundle/Application/")
        .map(|suffix| {
            let mut parts = suffix.split('/');
            match (parts.next(), parts.next(), parts.next()) {
                (Some(uuid), Some(name), None) => {
                    uuid.len() == 36
                        && uuid.chars().enumerate().all(|(index, character)| {
                            if matches!(index, 8 | 13 | 18 | 23) {
                                character == '-'
                            } else {
                                character.is_ascii_hexdigit()
                            }
                        })
                        && name.len() > 4
                        && name.ends_with(".app")
                }
                _ => false,
            }
        })
        .unwrap_or(false);

    if is_installed_app_bundle {
        logger.log("airlift-folder: using recovery-aware installed-app bundle read");
        exploit_read_folder_safe(pairing_path, target_dir, logger).await
    } else if trimmed == "/var/mobile/Containers"
        || trimmed.starts_with("/var/mobile/Containers/")
    {
        exploit_read_folder_safe(pairing_path, target_dir, logger).await
    } else {
        // Preserve Erosion's legacy reader for every other non-Media path.
        exploit_read_folder_legacy(pairing_path, target_dir, logger).await
    }'''
count=source.count(before)
if count != 1:
    raise SystemExit(f"Erosion app-bundle reader anchor count={count}; expected 1")
if source.count("async fn exploit_read_folder_safe(") != 1:
    raise SystemExit("Pinned recovery-aware reader missing or changed")
path.write_text(source.replace(before, after, 1),encoding="utf-8")
print("GREEN: installed .app reads route to recovery-aware Erosion reader; other paths unchanged")
