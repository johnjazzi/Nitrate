---
type: epic
title: "Make Apple Log capture trustworthy across supported iPhones"
parent: initiative-ios-film-emulation-app
covers: [CAP-2, CAP-3, CAP-12, CAP-13]
assignee: ""
risk: high
---

# Make Apple Log capture trustworthy across supported iPhones

## Description

Make clean Apple Log capture, exposure, focus, and storage safeguards reliable through runtime capability checks on the supported-device matrix.

## Outcome

Users can record correctly tagged source clips with predictable controls without relying on iPhone 18 or beta-only behavior.

## Done when

1. Supported devices record the specified 4K/24 Apple Log source and unsupported combinations fail clearly.
2. Exposure modes, focus, duration, and storage gates pass device tests.
3. Runtime checks—not model-name branches—drive availability.

## Boundaries

Camera session, camera UI/view model, exposure, focus, storage, and supported-device coverage. It consumes but does not change the accepted render contract.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/initiative-ios-film-emulation-app.md
- spec — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/spec-ios-film-emulation-app.md
- architecture — _bmad-output/initiative-ios-film-emulation-app/architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md, AD-3 through AD-5
