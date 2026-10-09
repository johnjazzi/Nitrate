---
type: epic
title: "Unlock and ship the complete v1"
parent: initiative-ios-film-emulation-app
covers: [CAP-9]
after: [epic-trustworthy-camera-capture, epic-trim-resilient-render-operations, epic-250d-stock-calibration]
assignee: ""
risk: medium
---

# Unlock and ship the complete v1

## Description

Complete trial, purchase, restore, release verification, and production packaging only after the capture and render product is accepted.

## Outcome

Users can try and unlock the same complete v1 through either paid option, and the release candidate passes its product gates.

## Done when

1. Trial expiry, annual, lifetime, restore, offline entitlement behavior, and cancellation paths are verified.
2. Neither paid option gates features differently.
3. The production build passes device, purchase, privacy, and end-to-end release checks.

## Boundaries

StoreKit entitlement UX, App Store configuration, and release gates. It does not alter capture or render behavior.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/initiative-ios-film-emulation-app.md
- spec — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/spec-ios-film-emulation-app.md

## Notes

- Waits on earlier epics because: commerce unlocks the complete accepted product rather than an unfinished feature subset.
