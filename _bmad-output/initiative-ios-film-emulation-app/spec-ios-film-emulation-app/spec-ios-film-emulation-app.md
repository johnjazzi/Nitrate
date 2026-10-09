---
id: SPEC-ios-film-emulation-app
companions:
  - film-stocks.md
  - render-quality.md
sources:
  - ../brief-ios-film-emulation-app/brief-ios-film-emulation-app.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability only.

# iOS Film Emulation App

## Why

Realize a simple iPhone camera whose rendered video can replace the creator's Blackmagic Camera plus desktop LUT workflow for everyday clips. The defining product quality is convincing film character, so v1 proves one excellent, inspectable video path before expanding the library, editor, or photo feature set.

## Capabilities

- **CAP-2**
  - **intent:** User can capture clean Apple Log video at 4K, 24 fps with manual shutter and ISO controls and an unprocessed preview.
  - **success:** A device recording reports HEVC, 4K, 24 fps, Apple Log color properties, expected audio, and no preview filter.

- **CAP-3**
  - **intent:** User can lock shutter, ISO, or both while an unlocked exposure parameter follows a target EV.
  - **success:** At 1/48 shutter lock, ISO responds to lighting; shutter remains within 1/24–1/100; locking both holds both values and displays deviation from target EV.

- **CAP-5**
  - **intent:** User can non-destructively trim the start and end of a clip before rendering.
  - **success:** Output duration and audio match the chosen range while the source movie remains byte-for-byte unchanged.

- **CAP-6**
  - **intent:** User can render an Apple Log clip into a color-managed film emulation with stock color response, spatial halation, highlight glow, and grain.
  - **success:** The output passes the transform, metadata, artifact, and creator-review gates in `render-quality.md`; disabling each effect produces an attributable difference without changing unrelated stages.

- **CAP-7**
  - **intent:** User can choose per-shot exposure-index grain behavior appropriate to the selected stock, with stable motion over time.
  - **success:** Grain responds monotonically to the control, does not visibly tile or repeat during the checkpoint clip, avoids frame-to-frame flicker, and preserves rather than obscures facial and highlight detail.

- **CAP-9**
  - **intent:** User can try the full app for seven days, then unlock it for $5/year or $10 lifetime without tier-based feature gating.
  - **success:** Trial and both purchases unlock the same features; expiry blocks protected actions and restore purchases works.

- **CAP-11**
  - **intent:** User can record while prior clips render through a persistent sequential queue.
  - **success:** Capture remains usable during render; pending, current, completed, and failed jobs survive relaunch and execute once in order.

- **CAP-12**
  - **intent:** User is protected from oversized recordings and insufficient storage.
  - **success:** Recording stops at five minutes, available space refreshes during recording, and capture is blocked below 500 MB.

- **CAP-13**
  - **intent:** User can tap the preview to focus with native-camera behavior.
  - **success:** A supported device focuses at the tapped point and communicates focus state; unsupported depth features are not presented.

- **CAP-14**
  - **intent:** Developer can repeatably evaluate every render stage and detect regressions before device review.
  - **success:** The same fixture produces captured source metadata, named intermediate/final frames, scopes, automated invariants, and a review sheet whose failures identify a pipeline stage.

- **CAP-15**
  - **intent:** Creator can capture and render a short Kodak Vision3 500T clip on a supported iPhone as the first end-to-end quality checkpoint.
  - **success:** A 10–20 second mixed-light clip renders with synchronized audio, correct orientation and SDR metadata, survives Photos playback, and is accepted or returned with observations using the rubric in `render-quality.md`.

## Constraints

- v1 is iOS-only, requires a device that supports Apple Log capture, and locks capture to 4K at 24 fps.
- The first checkpoint runs on iPhone 18 with iOS 27.2 beta; runtime capability checks and a supported-device matrix must protect older Apple Log-capable iPhones from assumptions specific to that beta environment.
- Every render stage declares its input/output color space and transfer function; arbitrary log scale/offset mapping and untagged delivery are forbidden.
- The first accepted slice targets Kodak Vision3 500T and SDR Rec.709 HEVC delivery; additional stocks and HDR delivery cannot delay it.
- Shutter remains within 1/24–1/100, defaulting to 1/48; exposure may clip when the upper limit is reached.
- Halation and glow are spatial, highlight-derived effects. A constant full-frame tint is not compliant.
- Grain must remain temporally stable, stock-configurable, and evaluated at delivery resolution after encoding.
- The source Apple Log movie is never modified and audio remains synchronized through trim and render.
- Correctness and inspectability precede optimization for the vertical slice, which must still finish without crash or thermal shutdown on the checkpoint device.
- No custom LUT import, multi-clip editing, or real-time filtered camera preview in v1.

## Non-goals

- Photos or RAW photo processing in v1
- A clean-capture library or stock swapping after the initial render in v1
- HDR delivery before the SDR 500T slice is accepted
- Scientific reproduction of a particular physical negative, laboratory process, scanner, or print stock
- Android, social features, cloud sync, community presets, or DSLR/mirrorless RAW import
- A full color-grading or timeline editor

## Success signal

The creator renders the checkpoint clip on their phone, prefers or considers it competitive with their quick Blackmagic-plus-desktop result, and can identify remaining defects by pipeline stage rather than describing the result only as “off.” The same fixture can then catch color, grain, temporal, metadata, and A/V regressions automatically or through the recorded rubric.

## Assumptions

- SDR Rec.709 is the v1 delivery target; HDR delivery will be specified only after the first slice is accepted.
- The creator's current Blackmagic Camera plus desktop LUT result is the primary subjective reference, supplemented by scopes and metadata checks.
- Kodak Vision3 500T is the highest-value first stock because it exercises tungsten color response, low-light texture, halation, and glow.
