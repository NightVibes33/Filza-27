#!/usr/bin/env bash
set -euo pipefail
ROOT='ThirdParty/3105'
PIN='4a15d823b711bc0639de1f3fd2c764b5982d9245'
test "$(cat "$ROOT/UPSTREAM_PIN")" = "$PIN"
(cd "$ROOT" && shasum -a 256 -c UPSTREAM_MANIFEST.sha256 >/dev/null)
test -f "$ROOT/UpstreamRepo/ThreeOneOSFive/helpers/PackageRepositoryStore.swift"
test -f "$ROOT/Sources/PackageRepositoryStore.swift"
grep -Fq 'RepositoryHomeView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'FeatureVisibility(developerModeEnabled: developerModeActive || forceFilesVisible)' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'return developerModeEnabled' "$ROOT/Sources/AppTabNavigationState.swift"
grep -Fq 'Filza3105PairingSettingsSection()' "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift"
grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' "$ROOT/Sources/AppDataBrowserView.swift"
grep -Fq 'FILZA_3105_APP_VIEW_SORT_V2' "$ROOT/Sources/AppDataBrowserView.swift"
grep -Fq 'Repackage as IPA' "$ROOT/Sources/AppDataBrowserView.swift"
! grep -Fq '.tabViewStyle(.page' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
! test -e scripts/patch-3105-feature-tabs.sh
! test -e scripts/patch-3105-compact-tabbar.sh
