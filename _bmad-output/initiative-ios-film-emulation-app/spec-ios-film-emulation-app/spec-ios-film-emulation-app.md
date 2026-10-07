---
id: SPEC-ios-film-emulation-app
companions:
  - film-stocks.md
sources:
  - ../brief-ios-film-emulation-app/brief-ios-film-emulation-app.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# iOS Film Emulation App

> **v1/v2/v3 roadmap:**
> - **v1:** Video capture with post-record film emulation render. Shoot Apple Log → pick stock → render → save. Original Log always kept.
> - **v2:** Post-processing unbaked footage. Save clean Log, browse in-app library, apply/swap stocks after capture.
> - **v3:** Photos. RAW capture with manual controls, film emulation pipeline, post-capture stock application.

## Why

A vision to realize: the creator wants to productize their personal Blackmagic Camera + desktop LUT video workflow into a dead-simple iOS app, combined with mood.camera's stripped-down film-shooting experience. No existing app delivers post-capture film emulation, video support, accurate film grain, and impulse-buy pricing in a single camera. v1 focuses on the video capture and render pipeline — the creator's primary pain point — with photos and the full post-capture library deferred to later versions.

## Capabilities

- **CAP-2**
  - **intent:** User can capture video in Apple Log with HEVC (H.265) encoding at 4K and ~36 Mbps, at 24fps, with manual control over shutter speed and ISO. Preview shows the standard camera feed — no LUT or filter applied during shooting.
  - **success:** A captured video produces a clean Apple Log .mov file at 4K, 24fps, HEVC H.265 ~36 Mbps. Preview is a clean AVCaptureVideoPreviewLayer with no processing artifacts.

- **CAP-3**
  - **intent:** User can lock shutter speed or ISO (or both) independently. When one is locked, the app auto-exposes the unlocked parameter to a user-set target EV. Shutter speed is clamped to 1/24–1/100; if exposure demands faster, the image overexposes.
  - **success:** Locking shutter at 1/48 and changing lighting results in ISO adjusting to maintain target EV. Shutter never exceeds 1/100 regardless of brightness. Locking both prevents any auto-exposure; an EV indicator shows over/under.

- **CAP-5**
  - **intent:** User can trim the start and end of a video clip before rendering. Trimming is non-destructive — the source Log file is never modified.
  - **success:** Trimmed render outputs only the selected time range. Source .mov remains at full length. Trimming does not re-encode untrimmed segments.

- **CAP-6**
  - **intent:** After recording, user picks a film stock and triggers a post-record render. The pipeline processes the Apple Log source through LUT → grain → halation → glow and outputs a processed .mov to the camera roll.
  - **success:** Side-by-side comparison with reference film stock shows matching color response, grain structure, highlight bloom, and soft light diffusion in the rendered output.

- **CAP-7**
  - **intent:** Film grain amount responds to a per-stock ISO slider. Video grain uses a 3D noise volume for temporal coherence — naturalistic frame-to-frame, not random static overlay. Rendered via GPU shaders during the post-record render pass.
  - **success:** Increasing ISO on Kodak 500T visibly increases grain intensity. Video grain does not flicker or produce static-like artifacts across frames.

- **CAP-9**
  - **intent:** User can try the full app free for 7 days, then unlock via $5/year subscription or $10 lifetime purchase. No feature gating between tiers.
  - **success:** First launch starts a 7-day trial with all features available. After expiry, features lock behind purchase. Either purchase option permanently unlocks all features.

- **CAP-11**
  - **intent:** User can record a new clip while a previous clip is rendering. Render jobs queue sequentially and persist across app backgrounding.
  - **success:** Starting a new recording does not block or cancel an in-progress render. Queue state (pending, current, completed) is visible. Closing and reopening the app restores the queue.

- **CAP-12**
  - **intent:** Single clip maximum duration is 5 minutes. Free device space is displayed and updated during recording. Recording is blocked if free space drops below 500MB.
  - **success:** Recording auto-stops at 5:00. Free space bar updates every 5 seconds. Record button is disabled when free space < 500MB.

- **CAP-13**
  - **intent:** Focus works exactly like the native iPhone camera — tap to focus on a point. Portrait mode (depth effect) is available on supported devices.
  - **success:** Tapping the preview sets focus at that point with the same behavior as the built-in Camera app. Portrait mode toggle enables depth capture on devices that support it.

## Constraints

- iOS-only. iPhone 13 Pro or newer required (Apple Log color space + HEVC 4K).
- Video locked to 24fps. No other frame rates in v1.
- Shutter speed clamped to 1/24–1/100 range. Overexpose if exposure demands faster shutter than 1/100.
- Preview shows clean camera feed — no real-time LUT, grain, or filter applied during shooting.
- Single clip maximum 5 minutes. Recording blocked below 500MB free space.
- Two starter video stocks only: Kodak 250D and 500T.
- No custom LUT import in v1.
- No photos in v1. No post-capture save-clean workflow in v1 (render is post-record but the Log-to-processed mapping is 1:1 at render time; no library of clean captures for re-processing).

## Non-goals

- Photos (RAW capture, photo film stocks) — deferred to v3
- Save-clean-and-apply-later workflow — deferred to v2
- In-app library of unprocessed captures — deferred to v2
- Android support
- Multi-clip video editing (combining, transitions, audio tracks)
- Community preset sharing or discovery
- Importing RAW files from external cameras
- Full editing suite or Lightroom-style adjustments
- In-app social sharing, cloud sync, or backup
- Custom LUT import or creation
- Non-24fps frame rates

## Success signal

- The creator stops using Blackmagic Camera + desktop LUT tools for quick-turnaround video and uses this app instead.
- Film enthusiasts who know the reference stocks say the emulation is convincing — "yeah, that's 500T."
- The app earns positive App Store ratings and steady organic download growth in the film-enthusiast niche.

## Assumptions

- Assumed Apple Log capture uses `AVCaptureColorSpace.appleLog` (not "Apple Log 2" — no such API exists in AVFoundation).
- Assumed two accurate video stocks are sufficient for v1; photo stocks and additional video stocks can be added in later versions.
- Assumed 24fps with 1/48 default shutter is the correct baseline for a "film look" video app.
- Assumed the 128³ 3D noise volume provides sufficient grain variation without visible repetition at 5-minute clip lengths.

> **ISO slider behavior:** Per-shot setting — each shot remembers its own ISO. App restores the last-used ISO per stock as the default for new shots, persisting across sessions.