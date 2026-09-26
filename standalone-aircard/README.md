# NFCARD standalone temp build

Temporary standalone iOS build based on the current AirCard integration in Filza 27.

Build contract:
- Work stays on `temp/aircard-wallet-standalone`; `main` is not part of this build.
- AirCard upstream is pinned to `097a058c984ffc33ccb697b9dfe8058be3e86244`.
- App display name: `NFCARD`.
- Native Pairing and Wallet Cards screens use the approved dark graphite + mint NFCARD visual system.
- The real pairing, live card scanner, image picker and flash paths remain wired to the existing AppViewModel/Airlift code.
- Visible tabs remain Pairing, Wallet Cards and Library.
- Library remains the existing embedded Card Studio launcher/content; its internal design is not redesigned by the NFCARD shell.
- Passcode and Wallpapers tabs remain removed.
- The Filza-specific pairing-file picker patch remains intentionally excluded.
- Output is an unsigned IPA.
