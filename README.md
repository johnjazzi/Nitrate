# Nitrate (iOS)

Film-emulation renderer for Apple Log 2 footage, delivering 4K HEVC (hvc1) with
film-stock LUTs, halation/glow, and grain.

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the single
source of truth. XcodeGen feeds them into the generated Info.plist, and the launch
splash renders them through `AppVersion` (`App/AppIdentity.swift`).

- Bump `MARKETING_VERSION` for a user-visible release (currently `0.1.0`).
- Bump `CURRENT_PROJECT_VERSION` for every build.
- Pre-release builds show the stage suffix: `0.1.0 (1) · ALPHA`. Pass `stage: nil`
  to `AppVersion.current()` for a shipping build.

The Xcode project, app target, and scheme are named `Nitrate`. The bundle
identifier (`com.filmemulation.app`), the `com.filmemulation.*` movie metadata
keys, and the StoreKit product identifiers deliberately keep the original name:
they are already shipped, and changing them would orphan existing installs,
renders, and purchases.

## ⚠️ LUT Licensing

**REPLACE THE LUTs WITH HOME-BUILT ONES — WE CANNOT DISTRIBUTE THESE LUTs. WE DO NOT HAVE THE RIGHTS FOR COMMERCIAL APPLICATION.**

The `.cube` files in `App/Resources/LUTs/` and `Resources/LUTs/` are third-party
Kodak Vision3 emulation LUTs and are **not** cleared for distribution or commercial
use. Replace them with in-house LUTs before shipping.
