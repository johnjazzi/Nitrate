---
type: epic
title: "Add and accept the 250D stock"
parent: initiative-ios-film-emulation-app
covers: [CAP-6, CAP-7, CAP-14]
after: [epic-render-quality-vertical-slice]
assignee: ""
risk: medium
---

# Add and accept the 250D stock

## Description

Reuse the accepted pipeline and calibration harness to add the second required v1 stock without destabilizing 500T.

## Outcome

Creators can choose an accepted daylight stock as well as 500T, with reproducible stock-specific configuration and evidence.

## Done when

1. 250D has a versioned transform and effect recipe with daylight reference evidence.
2. Its grain and diffusion characteristics pass the same isolation and temporal gates.
3. 500T goldens and its accepted recipe remain unchanged.

## Boundaries

250D calibration and selection only; it extends rather than forks the renderer contract.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/initiative-ios-film-emulation-app.md
- stock contract — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/film-stocks.md
- quality contract — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/render-quality.md

## Notes

- Waits on epic-render-quality-vertical-slice because: 250D adopts its accepted stage, recipe-versioning, and evidence contracts.
