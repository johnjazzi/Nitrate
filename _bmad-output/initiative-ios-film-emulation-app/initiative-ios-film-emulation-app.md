---
type: initiative
title: "An iPhone film camera worth using instead of a desktop workflow"
parent: none
covers: [CAP-2, CAP-3, CAP-5, CAP-6, CAP-7, CAP-9, CAP-11, CAP-12, CAP-13, CAP-14, CAP-15]
assignee: ""
risk: high
---

# An iPhone film camera worth using instead of a desktop workflow

## Description

Deliver the video-first app defined by the canonical spec, proving the render aesthetic before completing capture reliability, workflow resilience, the second stock, and release commerce.

## Outcome

The creator chooses the app over the Blackmagic Camera plus desktop LUT workflow for quick clips; the spec's device checkpoint and final success signal decide it.

## Done when

1. Both v1 stocks produce accepted, reproducible SDR Rec.709 renders from Apple Log on supported hardware.
2. Capture, exposure, focus, storage protection, trimming, audio, and the persistent render queue satisfy their capability checks on the supported-device matrix.
3. Trial, annual, lifetime, and restore flows unlock the same production feature set.
4. No broken item remains in the render rubric and the end-to-end suite passes on the release candidate.

## Boundaries

The iOS video product in the canonical spec. It excludes the spec's photo, HDR, social, cloud, custom-LUT, and full-editor non-goals. Tracer path: versioned Apple Log fixture → 500T renderer → encoded movie → Photos → creator review.

- Touch point: Photos — save and playback verification; owner: epic-render-quality-vertical-slice
- Touch point: StoreKit/App Store configuration — products and entitlement restoration; owner: epic-purchase-release-readiness

## References

- spec — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/spec-ios-film-emulation-app.md
- architecture — _bmad-output/initiative-ios-film-emulation-app/architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md
- UX — _bmad-output/initiative-ios-film-emulation-app/ux-ios-film-emulation-app/DESIGN.md and EXPERIENCE.md

## Notes

- Decision: start with the render-quality vertical slice and pause for an iPhone review before hardening the rest of the app (user, 2026-10-08).
- Decision: the existing Xcode scaffold is the platform baseline; no separate baseline epic is needed. Each epic owns the tests and project changes it requires (2026-10-08).
- Decision: 250D remains in v1 but follows acceptance of the 500T vertical slice (2026-10-08).
