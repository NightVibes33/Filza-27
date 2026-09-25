# Standalone AirCard Wallet temp build

Temporary extraction of Filza 27's current embedded AirCard integration.

Build contract:
- Standalone iOS app only; Filza 27 is not packaged.
- AirCard upstream is pinned to `740cfd9e7f00be77887638a3e65edbdb19ff1867`, matching the current embedded Filza 27 AirCard build.
- Visible tabs: Pairing, Wallet Cards, Library.
- The Library surface comes from the current `FilzaAirCardLibrary.swift`.
- Passcode and Wallpapers tabs are removed.
- Filza 27's restored pairing-file picker patch is intentionally not applied.
- Output is an unsigned IPA.
