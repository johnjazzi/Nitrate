---
type: epic
title: "Accept the 500T render-quality vertical slice"
parent: initiative-ios-film-emulation-app
covers: [CAP-6, CAP-7, CAP-14, CAP-15]
assignee: ""
risk: high
---

# Accept the 500T render-quality vertical slice

## Description

Turn the existing renderer scaffolding into an inspectable, color-managed 500T pipeline and decide its quality on the checkpoint iPhone before broader app work continues.

## Outcome

The creator accepts a 10–20 second 500T SDR render in Photos, with evidence that identifies color, diffusion, grain, encoding, or device failures by stage.

## Requirements

- CAP-6: Color-managed stock transform, spatial halation, highlight glow, and isolated effect behavior.
- CAP-7: Per-shot exposure-index grain selection with stable, non-repeating delivered motion.
- CAP-14: Repeatable fixtures, stage evidence, scopes, metadata, temporal diagnostics, and failure attribution.
- CAP-15: An accepted iPhone 18/iOS 27.2 beta clip with synchronized audio, orientation, SDR tags, and Photos playback.

## Done when

1. The versioned Apple Log fixture renders deterministically enough for tolerant golden and temporal regression checks.
2. Output is explicitly color-managed and tagged SDR Rec.709, with synchronized source audio and correct orientation.
3. Stock transform, halation, glow, and grain each pass isolated on/off evidence from `render-quality.md`.
4. The iPhone checkpoint has no broken rubric item and receives an overall accept.
5. Missing resources, failed appends, invalid pixels, or interrupted writes cannot produce a successful partial movie.

## Boundaries

Owns the renderer, Metal effects, versioned 500T configuration, minimal per-shot render EI control, diagnostics, and render-to-Photos checkpoint. It consumes the existing capture path or an external Apple Log clip; the later camera epic owns capture reliability, runtime camera capability gating, and the older-device matrix.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/initiative-ios-film-emulation-app.md
- spec — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/spec-ios-film-emulation-app.md
- quality contract — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/render-quality.md
- stock contract — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/film-stocks.md
- architecture — _bmad-output/initiative-ios-film-emulation-app/architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md, AD-6 through AD-10

## Notes

- Decision: automated work uses a checked-in/versioned Apple Log fixture; the phone clip is reserved for human acceptance (2026-10-08).
- Decision: the checkpoint records render/codec/Metal/source properties only; camera capability compatibility belongs to epic 2 (2026-10-08).
- Source conflict: architecture AD-6/AD-8 describe the current fused effects and writer settings, while the newer canonical render-quality contract requires explicit color stages and true spatial effects; this epic follows the canonical spec.
