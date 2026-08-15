#!/usr/bin/env bash
set -euo pipefail
set -x

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IOS_RUNTIME_BUILD="${IOS_RUNTIME_BUILD:-24A5390f}"
SIM_NAME="${SIM_NAME:-Filza27-iPhone16-iOS27}"
BYETUNES_COMMIT="${BYETUNES_COMMIT:-8a4be32f188f30b98f15b00566c5ff3edc1c03b1}"
MOND_COMMIT="${MOND_COMMIT:-4a37bfca5cb4abb2c99891972365d872d700525e}"
THREEONE_COMMIT="${THREEONE_COMMIT:-438f3ccae6a436d0017185407bc286e55c357883}"
IDEVICE_SIM_ROOT="${IDEVICE_SIM_ROOT:-$ROOT/Vendor/idevice-simulator}"

test -s "$IDEVICE_SIM_ROOT/lib/libidevice_ffi.a"
test -s "$IDEVICE_SIM_ROOT/include/idevice.h"
test -s "$IDEVICE_SIM_ROOT/include/ByeTunesSimulatorBridging.h"

mkdir -p .sim/artifacts .sim/results .sim/logs .sim/derived
SIM_UDID=""
cleanup() {
  if [[ -n "$SIM_UDID" ]]; then
    xcrun simctl shutdown "$SIM_UDID" || true
    xcrun simctl delete "$SIM_UDID" || true
  fi
}
trap cleanup EXIT

xcodebuild -version | tee .sim/artifacts/xcode-version.txt
test "$(uname -m)" = "arm64"
xcrun simctl list -j runtimes > .sim/artifacts/runtimes.json
xcrun simctl list -j devicetypes > .sim/artifacts/device-types.json

RUNTIME_ID="$(python3 - "$IOS_RUNTIME_BUILD" <<'PY'
import json, sys
expected=sys.argv[1]
data=json.load(open('.sim/artifacts/runtimes.json'))
matches=[r for r in data['runtimes'] if r.get('buildversion')==expected and r.get('isAvailable', True)]
if len(matches)!=1:
    raise SystemExit(f'expected exactly one installed runtime build {expected}, got {matches}')
print(matches[0]['identifier'])
PY
)"
DEVICE_TYPE_ID="$(python3 - <<'PY'
import json
data=json.load(open('.sim/artifacts/device-types.json'))
matches=[r for r in data['devicetypes'] if r.get('name')=='iPhone 16']
if len(matches)!=1:
    raise SystemExit(f'expected exactly one iPhone 16 device type, got {matches}')
print(matches[0]['identifier'])
PY
)"
printf 'runtime_build=%s\nruntime=%s\ndevice_type=%s\n' "$IOS_RUNTIME_BUILD" "$RUNTIME_ID" "$DEVICE_TYPE_ID" | tee .sim/artifacts/exact-target.txt

SIM_UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
echo "$SIM_UDID" | tee .sim/artifacts/simulator-udid.txt
xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b
xcrun simctl list -j devices > .sim/artifacts/devices-after-boot.json
python3 - "$RUNTIME_ID" "$SIM_UDID" "$SIM_NAME" <<'PY' | tee .sim/artifacts/booted-device.txt
import json, sys
runtime, udid, name=sys.argv[1:]
data=json.load(open('.sim/artifacts/devices-after-boot.json'))
rows=data.get('devices', {}).get(runtime, [])
matches=[d for d in rows if d.get('udid')==udid]
if len(matches)!=1:
    raise SystemExit(f'created simulator {udid} missing from runtime {runtime}; rows={rows}')
d=matches[0]
if d.get('name')!=name or d.get('state')!='Booted' or not d.get('isAvailable', True):
    raise SystemExit(f'created simulator has wrong state: {d}')
print(json.dumps(d, sort_keys=True))
PY

# Apply the same source transforms compiled into the Filza integration.
test "$(git -C ByeTunes rev-parse HEAD)" = "$BYETUNES_COMMIT"
bash scripts/patch-byetunes-upstream-parity-v2.sh
bash scripts/restore-byetunes-v24-metadata-compat.sh
bash scripts/patch-byetunes-metadata-parity-post.sh
bash scripts/patch-byetunes-background-provider-parity.sh
bash scripts/patch-byetunes-download-provider-parity.sh
bash scripts/patch-byetunes-device-library-save.sh
cp ByeTunesMetadataCompat.swift ByeTunes/MusicManager/Filza27MetadataCompat.swift
cp ByeTunesDownloadParityCompat.swift ByeTunes/MusicManager/Filza27DownloadParityCompat.swift
grep -R -Fq 'All Sources' ByeTunes/MusicManager
grep -R -Fq 'YouTube' ByeTunes/MusicManager
grep -R -Fq 'MetadataProviderSettings' ByeTunes/MusicManager

cat > ByeTunes/MusicManagerTests/Filza27ParityTests.swift <<'SWIFT'
import Foundation
import XCTest
@testable import ByeTunes

final class Filza27ParityTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MetadataProviderSettings.sourcesKey)
        UserDefaults.standard.removeObject(forKey: MetadataProviderSettings.legacySourceKey)
        super.tearDown()
    }

    func testAllSourcesLegacyMigration() {
        UserDefaults.standard.removeObject(forKey: MetadataProviderSettings.sourcesKey)
        UserDefaults.standard.set("all", forKey: MetadataProviderSettings.legacySourceKey)
        XCTAssertEqual(MetadataProviderSettings.selectedSources().map(\.rawValue), ["local", "youtube", "itunes", "deezer", "apple"])
    }

    func testYouTubeLegacyMigration() {
        UserDefaults.standard.removeObject(forKey: MetadataProviderSettings.sourcesKey)
        UserDefaults.standard.set("youtube", forKey: MetadataProviderSettings.legacySourceKey)
        XCTAssertEqual(MetadataProviderSettings.selectedSources().map(\.rawValue), ["local", "youtube"])
    }

    func testYouTubeParsing() {
        XCTAssertEqual(MetadataProvider.extractYouTubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(MetadataProvider.extractYouTubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        let normalized = MetadataProvider.normalizeYouTubeTitle("Rick Astley - Never Gonna Give You Up (Official Video)", channel: "Rick Astley")
        XCTAssertEqual(normalized.artist, "Rick Astley")
        XCTAssertEqual(normalized.title, "Never Gonna Give You Up")
        XCTAssertEqual(normalized.source, .youtube)
    }

    func testProviderNames() {
        XCTAssertEqual(MetadataProviderID.youtube.displayName, "YouTube")
        XCTAssertEqual(MetadataProviderID.itunes.displayName, "iTunes API")
        XCTAssertEqual(MetadataProviderID.deezer.displayName, "Deezer API")
        XCTAssertEqual(MetadataProviderID.apple.displayName, "Apple Music")
    }

    func testLiveMetadataDNSAndHTTPS() async throws {
        let urls = [
            URL(string: "https://itunes.apple.com/search?term=rick%20astley&entity=song&limit=1")!,
            URL(string: "https://api.deezer.com/search?q=rick%20astley&limit=1")!,
            URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ&format=json")!
        ]
        for url in urls {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue((200..<300).contains(http.statusCode), "HTTP \(http.statusCode) from \(url.host ?? "unknown")")
            XCTAssertFalse(data.isEmpty)
        }
    }
}
SWIFT

cat > ByeTunes/MusicManagerUITests/Filza27LaunchUITests.swift <<'SWIFT'
import XCTest

final class Filza27LaunchUITests: XCTestCase {
    func testLaunchAndScreenshot() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "patched-bytunes-iphone16-ios27"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
SWIFT

xcodebuild -list -project ByeTunes/MusicManager.xcodeproj | tee .sim/artifacts/byetunes-project-list.txt
xcodebuild test \
  -project ByeTunes/MusicManager.xcodeproj \
  -scheme MusicManager \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$ROOT/.sim/derived/ByeTunes" \
  -resultBundlePath "$ROOT/.sim/results/ByeTunes.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_OBJC_BRIDGING_HEADER="$IDEVICE_SIM_ROOT/include/ByeTunesSimulatorBridging.h" \
  HEADER_SEARCH_PATHS="$IDEVICE_SIM_ROOT/include" \
  LIBRARY_SEARCH_PATHS="$IDEVICE_SIM_ROOT/lib" \
  OTHER_LDFLAGS="-lidevice_ffi" \
  2>&1 | tee .sim/logs/byetunes-xcodebuild.log

BYETUNES_APP="$(find .sim/derived/ByeTunes/Build/Products -type d \( -name 'ByeTunes.app' -o -name 'MusicManager.app' \) -print -quit)"
test -n "$BYETUNES_APP"
BYETUNES_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$BYETUNES_APP/Info.plist")"
xcrun simctl install "$SIM_UDID" "$BYETUNES_APP"
BYETUNES_LAUNCH="$(xcrun simctl launch "$SIM_UDID" "$BYETUNES_BUNDLE_ID")"
echo "$BYETUNES_LAUNCH" | tee .sim/artifacts/byetunes-launch.txt
sleep 4
BYETUNES_PID="$(echo "$BYETUNES_LAUNCH" | awk -F': ' '{print $2}')"
test -n "$BYETUNES_PID" && kill -0 "$BYETUNES_PID"
xcrun simctl io "$SIM_UDID" screenshot .sim/artifacts/byetunes.png
xcrun simctl terminate "$SIM_UDID" "$BYETUNES_BUNDLE_ID"

rm -rf .sim/mond
git clone --filter=blob:none https://github.com/rooootdev/mond.git .sim/mond
git -C .sim/mond checkout --detach "$MOND_COMMIT"
test "$(git -C .sim/mond rev-parse HEAD)" = "$MOND_COMMIT"
xcodebuild -list -project .sim/mond/mond.xcodeproj | tee .sim/artifacts/mond-project-list.txt
xcodebuild build \
  -project .sim/mond/mond.xcodeproj -scheme mond \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$ROOT/.sim/derived/Mond" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee .sim/logs/mond-xcodebuild.log
MOND_APP="$(find .sim/derived/Mond/Build/Products -type d -name 'mond.app' -print -quit)"
test -n "$MOND_APP"
MOND_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$MOND_APP/Info.plist")"
xcrun simctl install "$SIM_UDID" "$MOND_APP"
MOND_LAUNCH="$(xcrun simctl launch "$SIM_UDID" "$MOND_BUNDLE_ID")"
echo "$MOND_LAUNCH" | tee .sim/artifacts/mond-launch.txt
sleep 4
MOND_PID="$(echo "$MOND_LAUNCH" | awk -F': ' '{print $2}')"
test -n "$MOND_PID" && kill -0 "$MOND_PID"
xcrun simctl io "$SIM_UDID" screenshot .sim/artifacts/mond.png
xcrun simctl terminate "$SIM_UDID" "$MOND_BUNDLE_ID"

rm -rf .sim/3105
git clone --filter=blob:none https://github.com/NightVibes33/3105.git .sim/3105
git -C .sim/3105 checkout --detach "$THREEONE_COMMIT"
test "$(git -C .sim/3105 rev-parse HEAD)" = "$THREEONE_COMMIT"
xcodebuild -list -project .sim/3105/ThreeOneOSFive.xcodeproj | tee .sim/artifacts/3105-project-list.txt
xcodebuild build \
  -project .sim/3105/ThreeOneOSFive.xcodeproj -scheme ThreeOneOSFive \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$ROOT/.sim/derived/3105" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee .sim/logs/3105-xcodebuild.log
THREEONE_APP="$(find .sim/derived/3105/Build/Products -type d -name 'ThreeOneOSFive.app' -print -quit)"
test -n "$THREEONE_APP"
THREEONE_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$THREEONE_APP/Info.plist")"
xcrun simctl install "$SIM_UDID" "$THREEONE_APP"
THREEONE_LAUNCH="$(xcrun simctl launch "$SIM_UDID" "$THREEONE_BUNDLE_ID")"
echo "$THREEONE_LAUNCH" | tee .sim/artifacts/3105-launch.txt
sleep 4
THREEONE_PID="$(echo "$THREEONE_LAUNCH" | awk -F': ' '{print $2}')"
test -n "$THREEONE_PID" && kill -0 "$THREEONE_PID"
xcrun simctl io "$SIM_UDID" screenshot .sim/artifacts/3105.png
xcrun simctl terminate "$SIM_UDID" "$THREEONE_BUNDLE_ID"

cat > .sim/artifacts/COVERAGE.md <<EOF
# Simulator coverage

Runtime build: $IOS_RUNTIME_BUILD
Device type: iPhone 16

Covered by this lane:
- patched ByeTunes compile + XCTest + UI launch
- complete ByeTunes DeviceManager compiled against the same pinned idevice FFI, built for the simulator ABI
- All Sources / YouTube migration and parser tests
- live iTunes, Deezer, YouTube HTTPS/DNS from the simulator
- Mond standalone compile + launch
- 3105 standalone compile + launch
- simulator screenshots and xcresult evidence

Physical-device-only:
- successful idevice lockdown/pairing/AFC transport against the phone
- bad_query sandbox escape
- kernel/vnode/APFS/SPTM behavior
- real MobileGestalt/private-service mutations
- HouseArrest/MCM access to other installed app containers
- physical-device Filza executable / injected arm64-apple-ios dylib loading
- device-only entitlement behavior
- actual lockdown/pairing and real Music library device services
EOF
