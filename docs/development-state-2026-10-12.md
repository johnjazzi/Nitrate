# Development state — October 12, 2026

## Current baseline

The checkout is at `6b70c35` on `main`. Camera capture is fixed and verified on an iPhone 18 Pro running iOS 27.2 in commit `002fcec` (`fix: record Apple Log 2 HEVC Main10 originals on device`). The fix removes the capture-output codec list as a writer capability gate, reads AVFoundation's codec value with its proper type, and requests AAC audio explicitly.

Two consecutive device smoke captures are recorded in `.pi/tmp/log2-fix-probe-2026-10-12/console-6.log` and `console-7.log`. Both select the 10-bit `x420` candidate from the active 4K Apple Log 2 format, write `hvc1` Main10 3840×2160 with the Apple Log 2 transfer tag and BT.2020 matrix, include AAC audio, and pass decoded YUV preservation checks. Console 6 reports maximum luma error 0.0009 and chroma error 0.0022; console 7 reports 0.0012 and 0.0030. Both are within the probe's 0.03 limits. The smoke tests demonstrate this device path and preservation probe; they do not establish film-look or colorimetric calibration.

## Work queue

Edge-modulated grain is implemented in commit `9545624` and has a documented single-run benchmark in `docs/edge-grain-benchmark.md`. The broader grain-size work and per-stock halation work remain active as uncommitted plans only; see `.pi/tmp/briefs/phase1-grain-size-implementation.md`, `.pi/tmp/briefs/phase2-halation-perstock-ring.md`, and `.pi/tmp/grain-halation-physics.md`. No corresponding new grain-size or halation implementation is part of the current committed baseline.

Aperture control for iPhone 18 is queued from `docs/prioritization.md`; its planning brief is `.pi/tmp/aperture-backlog-brief.md`. It has not been implemented.

## Evidence and history

The full camera root-cause analysis and device result are in `.pi/tmp/camera-hevc-log2-diagnosis.md`. The morning handoff is retained as a historical snapshot; its earlier statement that no phone capture had passed is superseded by this state note and the two later console logs.
