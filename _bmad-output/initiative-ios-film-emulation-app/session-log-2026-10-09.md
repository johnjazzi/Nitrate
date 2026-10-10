---
type: session-log
date: 2026-10-09
initiative: initiative-ios-film-emulation-app
---

# Session log — 2026-10-09

Work in the render-quality vertical slice: grain correctness, delivery bitrate,
color-contract declaration, capture audio, camera controls, queue UX, and the
spatial halation/glow stage.

## Shipped, by theme

### Render correctness

- **Grain ABI mismatch fixed.** `GrainUniforms.frameIndex` was Swift `UInt`
  (8 bytes) against Metal's `uint` (4), so the GPU read `iso` from the high half
  of `frameIndex` (always 0) and `grainSize` from Swift's `iso`. Grain had been
  reduced to its ~1 LSB dither term. Changed to `UInt32` in the three places in
  `PipelineRenderer.swift`; `Tests/GrainABITests.swift` pins the struct layout
  and a bit-exact GPU round-trip of ISO/grainSize. Grain strength then raised
  (`grain.metal` base 0.12 → 0.55, additive 0.35 → 0.85) because the ABI fix
  alone was necessary but not sufficient.
- **Spatial halation and glow (story 1.4).** Halation and glow used to be
  per-pixel: a pixel was brightened by its own luma, so a highlight could never
  bleed to its neighbours, and "glow" was a constant frame-wide add whose real
  effect was lifting blacks. Now a genuine diffusion stage
  (`Resources/Shaders/spatial.metal` + `SpatialEffectsStage.swift`) extracts one
  half-res highlight mask, blurs it separably twice (tight radius for halation,
  wide for glow), and composites each back with its own tint and a shadow fade.
  The far field is now exactly the untouched source level, which the old
  constant glow could not manage. Recipe identities moved to
  `input-luma-spatial-highlight-addition-v2` / `blurred-warm-highlight-addition-v2`,
  version `500t-current-v3`.

### Delivery

- **Output color tags.** `RenderEncodingContract` tags output Rec.709 via
  `AVVideoColorPropertiesKey`; ffprobe confirms bt709. The LUTs are declared
  "Apple Log 2 → Rec.709" and the recipe declares Apple Log 2 input with
  BT.2020 primaries (Apple-documented). Provenance stays **user-declared**:
  `RenderRecipe.colorContractVerified` remains `false`, because the LUTs resolve
  an Apple Log 2 source and feeding a raw chart would be transformed by the cube
  rather than measured.
- **Bitrate made configurable** (`DeliverySettings`, UserDefaults
  `delivery.averageBitRate`, default 60 Mbps; CLI `--bitrate`). At 36 Mbps only
  ~40–50% of grain survived; 60 Mbps keeps ~93–94%; 80 Mbps adds little.
- **Human-readable metadata.** Custom `com.filmemulation.*` keys were always
  written but Finder/Photos/QuickTime ignore unknown keys, so Title and
  Description now carry a readable summary ("ISO N · 180° shutter · halation ·
  glow · grain · hvc1 @ N Mbps").

### Capture

- **Audio actually records now.** Two distinct defects: the render path called
  `append` during backpressure (dropping samples) and shared one reader across
  threads; separately the app never captured audio at all — no microphone input
  and no usage description. Both fixed (dedicated audio reader, mic input,
  `NSMicrophoneUsageDescription`, permission request).
- **Launch / lens-switch hang.** `configure()` and lens switching ran
  `sessionQueue.sync` camera reconfiguration **from the main thread**, stalling
  launch. There is now no synchronous configure path. Lens switching also
  stopped throwing `cannotAddInput` (the old input was being removed *after*
  `canAddInput` was checked).
- **Camera controls:** lens selection (front/ultrawide/wide/tele), manual ISO
  and exposure, a fixed 180° / 1/48s shutter via meter-and-hold (frozen during a
  take), and a focus/zoom panel with tap-to-focus, pinch-to-zoom (damped 0.45×)
  and manual focus.

### Workflow

- **Commit-at-every-boundary rule recorded in `AGENTS.md`** — commit on every
  "ok on to the next" / "looks good" before starting other work; commit only
  verified work; never commit a failing tree.

## Commits

- `5cefe90` — Film reel app icon and branded launch screen.
- `ea17429` — Merge PR #1 (branding).
- `58d80f5` — Film emulation core: grain, color management, white balance,
  audio, camera controls.
- `8340a8a` — chore: untrack bmad transient build state.
- `78be21b` — Camera controls, queue replay, recipe gamut declaration.
- `0ff62fd` — Fix launch and lens-switch hang from blocking session config.
- `5a5e6ed` — Make halation and glow spatially diffuse instead of per-pixel.

Every commit landed with the RenderCLI suite green (22/22 at the latest), a
generic iOS build at exit 0, and a clean `git diff --check`.

## Verification state

Unit/integration coverage exists for the grain ABI, the LUT neutral axis, the
render/recipe/diagnostics contract, and now the spatial stage. **No device
verification exists yet** for any of this: launch fix, audio, contrast 0.6 and
spatial halation/glow all still need a real build on a phone.

## Next

Highest value first.

1. **Device checkpoint.** Rebuild, re-apply signing, and confirm on-phone:
   launch no longer hangs, lens switching works, audio is present, contrast 0.6
   reads correctly, and halation/glow look right. Nothing above is confirmed
   visually until this happens.
2. **Visual checkpoint against the MOOD references** (ticket 1.8) —
   `/Users/johnazzinaro/Downloads/MOOD_1791549399894.JPG` and
   `MOOD_1791549393397.JPG` (one tungsten, one daylight; filename mapping
   unknown).
3. **Re-tune halation/glow strengths.** The 500T values (hal 0.2 / glow 0.08)
   were carried over from the per-pixel implementation, and glow was previously
   dimmed by a 0.1-magnitude tint it no longer has — so glow now reads stronger
   than before.
4. **Saturation vs MOOD.** Investigate with the original unprocessed source; no
   guessed global tint and no white-balance change.
5. **Story 1.5** exposure-index selection, then **1.6** temporally stable grain
   (validate grain visibility before tuning strength), then **1.7** harden movie
   writing (trim-relative timestamps, A/V tests).
6. **#24 film-shake emulation** — low priority, research first (amplitude,
   frequency spectrum, per-axis behaviour, film-gate jitter vs handheld,
   procedural vs optical flow). Must not disturb the locked color contract or
   the white-balance lock.
7. **Open quality questions:** exact transfer gamma 2.2 vs 2.4; replace the Etsy
   LUTs with home-built ones (they cannot be distributed commercially — see
   README); optional 10-bit pipeline (output is currently `bgra8Unorm`/32BGRA)
   and B-frames (`AVVideoAllowFrameReorderingKey` is still false); no automated
   grain-survival regression test.
