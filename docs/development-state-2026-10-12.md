# Development state — October 12, 2026

## Current baseline

`main` contains the verified camera foundation. Camera capture is fixed and verified on an iPhone 18 Pro running iOS 27.2 in commit `002fcec` (`fix: record Apple Log 2 HEVC Main10 originals on device`). The fix removes the capture-output codec list as a writer capability gate, reads AVFoundation's codec value with its proper type, and requests AAC audio explicitly.

Two consecutive device smoke captures are recorded in `.pi/tmp/log2-fix-probe-2026-10-12/console-6.log` and `console-7.log`. Both select the 10-bit `x420` candidate from the active 4K Apple Log 2 format, write `hvc1` Main10 3840×2160 with the Apple Log 2 transfer tag and BT.2020 matrix, include AAC audio, and pass decoded YUV preservation checks. Console 6 reports maximum luma error 0.0009 and chroma error 0.0022; console 7 reports 0.0012 and 0.0030. Both are within the probe's 0.03 limits. The smoke tests demonstrate this device path and preservation probe; they do not establish film-look or colorimetric calibration.

## Work queue

Edge-modulated grain is implemented in commit `9545624` and has a documented single-run benchmark in `docs/edge-grain-benchmark.md`. The broader grain-size work and per-stock halation work remain active as uncommitted plans only; see `.pi/tmp/briefs/phase1-grain-size-implementation.md`, `.pi/tmp/briefs/phase2-halation-perstock-ring.md`, and `.pi/tmp/grain-halation-physics.md`. No corresponding new grain-size or halation implementation is part of the current committed baseline.

Hardware aperture control is implemented in the Manual controls panel: supported f-stop choices plus Auto, capability-gated on the active format. Auto exposure retains the 180° shutter and software EV compensation; manual exposure retains its ISO and shutter. Recording pins the current Auto iris and restores Auto afterward. Fixed lenses display a read-only value; invalid startup readings show unavailable. Final verification passed 109 tests with zero failures/skips, generic and signed iOS builds, strict codesign, and focused Luna review. The phone reported rear stops f/1.5, f/1.8, f/2.8, f/4.0 and front fixed f/1.9; the HEVC Log2 recording smoke passed. The final signed artifact was installed with data preserved and launched normally. Manual stop selection and physical iris movement remain hands-on acceptance checks; evidence is in `.pi/tmp/aperture-phone-check-report.md`.

## Evidence and history

The full camera root-cause analysis and device result are in `.pi/tmp/camera-hevc-log2-diagnosis.md`. The morning handoff is retained as a historical snapshot; its earlier statement that no phone capture had passed is superseded by this state note and the two later console logs.

## Temporary artifact consolidation

Four historical review/research snapshots were consolidated under `.pi/tmp/archive/2026-10-12-review-snapshots/`. Byte counts and SHA-256 hashes matched before their `/tmp` originals were removed; the empty `/tmp/pi-github-repos/` directory was removed with `rmdir`. Active grain/halation plans and camera evidence were retained. The manifest is `.pi/tmp/tmp-consolidation-results.md`.

## Camera controls UI update

The Manual controls opener always uses the sliders icon. Its panel is compact (about half the screen width and three-quarters its former height), with less padding, anchored below the top toolbar at the left. Camera buttons use raised rectangular faces and beveled highlights; lens choices share a grouped bezel. Bottom controls place stock/lenses above queue/record on the left, with a taller EV/ISO ruler and free-space indicator on the right. The indicator turns red below 1 GB and opens a dark, scrollable storage sheet showing actual available/used/total capacity and estimated recording time. The estimate reserves the existing 500 MB buffer and budgets original plus rendered copies at configured video/AAC bitrates; Photos copies and variable encoding can reduce actual time.

Verification: 112 tests passed with zero failures/skips, lint, generic and signed iOS builds, strict codesign, and focused Luna review. The signed UI build installed with app data preserved; normal launch was blocked by the locked phone. Visual layout and button feel await manual review after unlocking. Evidence: .pi/tmp/camera-controls-layout-report.md, .pi/tmp/camera-controls-test-summary.json, and .pi/tmp/camera-controls-phone-install-report.md.

## Camera feedback follow-up

Stock and camera tiles now share matching sizes and select focal lengths directly (13/24/96 mm and Front). The selector group is centered in its row; the primary record face is 84 points and centered across the viewport. Queue activity has no raised button face. The status beneath exposure shows estimated recording time, retaining the below-1-GB red indication and storage details sheet. Aperture adjustment is restricted to the main rear camera with negotiated variable-aperture support; fixed lenses are read-only. Lens switches invalidate aperture commands and snapshots, and committed lens selection remains correct when a later switch fails.

The front recording diagnostic confirmed valid ten-bit Apple Log frames rejected solely because they arrived rotated at 2160×3840. Raw data-output rotation is now set to zero after the final input/format configuration commit; strict 3840×2160 and color validation remain intact. The diagnostic startup flag keeps front lens state consistent in the view and model. The follow-up front hardware launch was blocked by the locked phone, so acceptance of the orientation correction remains pending; the original failure is recorded in `.pi/tmp/front-probe-verification/probe-console.log`.

Final verification passed 113 tests with zero failures/skips, lint, generic and signed iOS builds, strict codesign, and focused Luna review. The latest signed app was installed in place with data preserved. No final launch was attempted while awaiting an unlocked phone. Evidence: `.pi/tmp/camera-feedback-release-verification-report.md` and `.pi/tmp/camera-feedback-final-review-report.md`.

## Front capture and camera TODO follow-up

The unlocked-phone retest showed that rotation zero still emits native portrait 2160×3840 frames on the front camera. The recorder now latches the first valid 4K frame geometry, creates HEVC writer settings at that coded size, and uses identity for portrait-coded input or the existing quarter-turn for landscape-coded input. It rejects resolution mismatches and changes within a clip; Log/color/profile checks remain strict. The renderer already uses track natural size and preferred transform. A fresh isolated front recording passed: HEVC Main10 2160×3840, identity transform, valid Log tags, decoded YUV maximum errors 0.0016/0.0017, audio skew 0.000 seconds and end delta 0.018 seconds. Visual uprightness and film-look calibration are separate manual checks.

Rear aperture support queries all passed; real setter calls reached f/1.8 and f/1.48. The reported rejection was not reproduced. Successful selection now clears an earlier aperture error without clearing unrelated errors; manual confirmation of the original complaint remains open. Temporary aperture diagnostic launch flags were removed. Recording-time storage refresh now begins automatically on launch/resume, with background capacity reads and stale-result rejection. Focal-length numbers appear above smaller mm labels.

Final verification passed 115 tests, zero failures/skips, lint, generic and signed iOS builds, strict codesign, and independent Luna review. The signed app was installed with existing data preserved. Evidence: `.pi/tmp/camera-todo-final-verification/`, `.pi/tmp/camera-p0-final-review-report.md`, and `.pi/tmp/aperture-setter-ready-phone-probe/`. The actionable list is `docs/camera-feedback-todo.md`; the stock button's full-height interpretation remains awaiting clarification.

## Screenshot follow-up

The user confirmed front recording works and the time estimate populates. The recurring aperture banner was still reported during lens switches. Automatic camera-operation errors now carry the lens that produced them; the view model rejects callbacks while switching or for another lens. Switch start clears only the previous aperture error, while explicit current-lens selection failures remain visible. Fixed-lens exposure paths were already capability-gated; no aperture support check was weakened. Manual confirmation of the original switching complaint remains open.

The stock-button clarification was about filling the tile with its stock colors. Stripes now cover the complete face, with matching primary-color backing; the camera group centers beside the left stock tile. The duration caption is REC LEFT with a full accessibility label. Final verification passed 115 tests, lint, generic and signed builds, strict codesign, diff-check, and independent Luna review. The app installed in place and launched normally as PID 8367. Evidence: `.pi/tmp/camera-screenshot-verification-final-report.md` and `.pi/tmp/camera-screenshot-review-report.md`.
