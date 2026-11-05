#!/usr/bin/env python3
"""Remove redundant pairing controls from embedded modules after upstream patches.

The single interactive pairing screen lives in Filza main Settings. Keep
ByeTunes onboarding/replay, but make it nonblocking and refer pairing setup to
Filza Settings; the same DeviceManager transport code stays intact.
"""
from pathlib import Path

def balanced_end(text: str, begin: int) -> int:
    opening = text.find("{", begin)
    if opening < 0: raise SystemExit("missing opening brace")
    depth, quoted, escaped = 0, False, False
    for pos in range(opening, len(text)):
        char = text[pos]
        if quoted:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == '"': quoted = False
            continue
        if char == '"': quoted = True
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return pos + 1
    raise SystemExit("unbalanced SwiftUI block")

root = Path("ByeTunes/MusicManager")
settings = root / "SettingsView.swift"
text = settings.read_text()
pairing_button = '''                        Button {
                            onDevicePairing.start(manager: manager)'''
pin = "                        if let pin = onDevicePairing.pin {"
if pairing_button in text:
    start = text.index(pairing_button)
    pin_start = text.index(pin, start)
    end = balanced_end(text, pin_start)
    text = text[:start] + '''                        HStack {
                            Image(systemName: "link.circle")
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pairing is managed by Filza 27")
                                Text("Open Filza Settings → Device Pairing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
''' + text[end:]
elif 'Text("Pairing is managed by Filza 27")' not in text:
    raise SystemExit("ByeTunes embedded Settings pairing row changed")
settings.write_text(text)

onboarding = root / "OnboardingView.swift"
text = onboarding.read_text()
action = '''                    onDevicePairing.start(manager: manager)'''
if action in text:
    text = text.replace(action, '''                    // Main Filza Settings is the only pairing owner.
                    // Completing the music tutorial no longer requests pairing.
                    withAnimation { isComplete = true }''', 1)
elif "withAnimation { isComplete = true }" not in text:
    raise SystemExit("ByeTunes onboarding pairing action changed")
text = text.replace('Text(onDevicePairing.isPairing ? "Pairing…" : "Pair This iPhone")',
                    'Text("Continue to Music")')
text = text.replace('StepRow(number: "2", text: "Tap Pair This iPhone below", isLast: false)',
                    'StepRow(number: "2", text: "Open Filza 27 Settings > Device Pairing when needed", isLast: false)')
text = text.replace('StepRow(number: "3", text: "Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes", isLast: false)',
                    'StepRow(number: "3", text: "Choose on-device pairing or select your existing RP pairing file", isLast: false)')
text = text.replace('StepRow(number: "4", text: "Approve the request and enter the PIN shown here", isLast: true)',
                    'StepRow(number: "4", text: "Return to Music when the device tunnel is connected", isLast: true)')
pin = "                if let pin = onDevicePairing.pin {"
if pin in text:
    start = text.index(pin)
    end = balanced_end(text, start)
    text = text[:start] + text[end:]
onboarding.write_text(text)

# 3105 retains the shared paired-app-icon/transport consumer, not a second
# settings screen or a redundant pairing-file importer.
settings3105 = Path("ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift")
text = settings3105.read_text()
marker = "/// Shared pairing controls shown inside 3105 -> Settings."
if marker in text:
    text = text[:text.index(marker)].rstrip() + "\n"
    settings3105.write_text(text)
elif "struct Filza3105PairingSettingsSection" in text:
    raise SystemExit("3105 pairing controls marker changed")

# The 3105 settings view still references the old pairing section after its
# definition is removed above. Remove that call as well so the generated Swift
# target doesn't refer to a symbol that no longer exists.
settings3105_view = Path("ThirdParty/3105/Sources/ThreeOneOSFiveSettingsView.swift")
settings3105_ui = settings3105_view.read_text(encoding="utf-8")
pairing_row = "                Filza3105PairingSettingsSection()\n"
if pairing_row in settings3105_ui:
    if settings3105_ui.count(pairing_row) != 1:
        raise SystemExit("3105 settings contains duplicate pairing rows")
    settings3105_ui = settings3105_ui.replace(pairing_row, "", 1)
    settings3105_view.write_text(settings3105_ui, encoding="utf-8")
elif "Filza3105PairingSettingsSection" in settings3105_ui:
    raise SystemExit("3105 settings pairing call changed; refusing partial removal")

assert "onDevicePairing.start(manager: manager)" not in settings.read_text()
assert "onDevicePairing.start(manager: manager)" not in onboarding.read_text()
assert "struct Filza3105PairingSettingsSection" not in settings3105.read_text()
assert "Filza3105PairingSettingsSection" not in settings3105_view.read_text()
print("Removed ByeTunes and 3105 duplicate pairing controls; Filza Settings owns pairing")
