
- source_plan: `epic-render-quality-vertical-slice/story-version-the-500t-transform-and-effect-contract-plan.md`
  summary: RESOLVED 2026-10-09 — corrected and verified the CPU/Metal grain uniform ABI.
  evidence: PipelineRenderer.swift GrainUniforms.frameIndex changed Swift UInt → UInt32 (16-byte struct matching grain.metal uint/float/float/float). Previously Metal read iso at offset 4 (0) and grainSize at offset 8 (Swift iso), so grain was dither-only. Tests/GrainABITests.swift verifies size/stride/offset and a GPU echo-kernel bit-exact round-trip of ISO 123.456 / grainSize 7.89. Grain strength re-tuning deferred to visual validation (tickets 1.5–1.6).

- source_plan: `plan-embed-render-settings-in-movies.md`
  summary: Keep capture ISO readout synchronized with actual active camera ISO.
  evidence: ContentView currentDeviceISO defaults to 400 and changes only at AE lock; auto exposure, unlock and switch can show stale values. Pre-existing capture/UI work.

- source_plan: `plan-embed-render-settings-in-movies.md`
  summary: Make AE lock preserve current exposure and report completion accurately.
  evidence: CameraSession.lockCurrentExposure sets autoExpose, permitting remetering before lock, while UI immediately indicates lock and samples ISO. Pre-existing capture/UI work.
