
- source_plan: `epic-render-quality-vertical-slice/story-version-the-500t-transform-and-effect-contract-plan.md`
  summary: RESOLVED 2026-10-09 — corrected and verified the CPU/Metal grain uniform ABI.
  evidence: PipelineRenderer.swift GrainUniforms.frameIndex changed Swift UInt → UInt32 (16-byte struct matching grain.metal uint/float/float/float). Previously Metal read iso at offset 4 (0) and grainSize at offset 8 (Swift iso), so grain was dither-only. Tests/GrainABITests.swift verifies size/stride/offset and a GPU echo-kernel bit-exact round-trip of ISO 123.456 / grainSize 7.89. Grain strength re-tuning deferred to visual validation (tickets 1.5–1.6).

- source_plan: `tracking/epic-render-quality-vertical-slice/tickets.toml` (story 4)
  summary: RESOLVED 2026-10-09 — halation and glow are now genuinely spatial.
  evidence: The per-pixel warm-highlight addition in `pass1_lut_halation_glow` (and its constant frame-wide glow lift) was replaced by a spatial stage: `Resources/Shaders/spatial.metal` (mask/blur_h/blur_v/composite kernels) driven by `App/Modules/ProcessingPipeline/SpatialEffectsStage.swift`, run between the LUT pass and the grain pass. One untinted half-resolution highlight mask is blurred separably twice (tight halation radius, wide glow radius) and composited back with per-effect tint and strength plus a shadow fade. Recipe identities for the 4 500T stocks became `input-luma-spatial-highlight-addition-v2` / `blurred-warm-highlight-addition-v2`, version `500t-current-v3`. Measured on a bright block over dark: halation adds +8/255 red at the edge (R:G:B = 1:0.39:0.13) decaying to the source level by ~40px; glow still lifts the frame at 40-60px; the far field stays at the untouched source level, which the old constant glow could not do. `Tests/SpatialEffectsTests.swift` pins the spatial properties; RenderCLI 22/22 pass; generic iOS build exit 0. Modified `App/ContentView.swift`? No — render pipeline only. REMAINING: the visual checkpoint against MOOD references is still owed (ticket 1.8), and the effect strengths (500T hal 0.2 / glow 0.08) were carried over from the per-pixel implementation and may deserve re-tuning now that glow is no longer dimmed by a 0.1-magnitude tint.

- source_plan: `plan-embed-render-settings-in-movies.md`
  summary: Keep capture ISO readout synchronized with actual active camera ISO.
  evidence: ContentView currentDeviceISO defaults to 400 and changes only at AE lock; auto exposure, unlock and switch can show stale values. Pre-existing capture/UI work.

- source_plan: `plan-embed-render-settings-in-movies.md`
  summary: Make AE lock preserve current exposure and report completion accurately.
  evidence: CameraSession.lockCurrentExposure sets autoExpose, permitting remetering before lock, while UI immediately indicates lock and samples ISO. Pre-existing capture/UI work.

- source_plan: `tracking/epic-render-quality-vertical-slice/tickets.toml` (story 2)
  summary: RESOLVED 2026-10-09 — advanced the declared input interpretation; contract stays user-declared.
  evidence: Apple documents Apple Log as BT.2020 primaries (`AVCaptureColorSpace.appleLog`), so the 4 shipped 500T recipes in both `stocks.json` copies now declare `input.gamut = "Rec.2020"` (was "unverified") and bump `version` to `500t-current-v2`, which makes the diagnostic bundle identify the revised recipe. Provenance was NOT advanced — the LUTs resolve an Apple Log 2 source, so feeding raw sRGB/Rec.2020 would be transformed by the cube rather than verified; `RenderRecipe.colorContractVerified` stays false. `Tests/RenderContractTests.swift` (`recipeRoundTripAndRevisionEvidence`) pins the new declared gamut/transfer/provenance; 19/19 RenderCLI tests pass; generic iOS build exit 0.
