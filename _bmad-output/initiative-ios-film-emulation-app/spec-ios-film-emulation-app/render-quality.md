# Render Quality Contract

## First vertical slice

Render a 10–20 second Kodak Vision3 500T checkpoint clip captured on iPhone 18 running iOS 27.2 beta. The clip must include a face or skin-like reference, neutral gray/white, a saturated color, deep shadow texture, a practical point light, and highlight roll-off. Capture the same scene with the creator's Blackmagic workflow when practical. Record runtime camera, codec, color-space, and Metal capabilities so the result does not become an implicit minimum-device requirement.

## Stage contract

| Stage | Input | Output | Gate |
|---|---|---|---|
| Decode | Tagged Apple Log HEVC movie | Linear or explicitly declared high-precision working image | Orientation, dimensions, timing, and source color properties are recorded; no unexplained clipping or 8-bit intermediate. |
| Stock transform | Declared working image | 500T creative color response in declared delivery/working space | Neutral patches remain neutral unless intentionally biased; skin, saturation, and highlight roll-off are visually coherent; LUT domain is applied exactly as authored. |
| Halation | Stock-transformed image plus highlight mask | Localized warm/red scattering around qualifying highlights | Radius scales in image space, effect falls off spatially, shadows and broad midtones receive no global tint, and disabling it changes only localized highlight edges. |
| Glow | Halated image plus highlight mask | Soft highlight diffusion | Bright regions bloom with a broader, more neutral response than halation; blacks are not lifted globally and fine detail outside the mask is preserved. |
| Grain | Diffused image plus temporal state and stock parameters | Temporally evolving stock texture | No visible screen-space tiling, 128-frame loop, crawling edges, or independent random flicker; strength follows the selected exposure index. |
| Encode | Final high-precision image and source audio | Tagged SDR Rec.709 HEVC movie | Photos plays the movie with correct orientation, duration, frame cadence, synchronized audio, and consistent appearance across repeat exports. |

## Automated evidence

Each checkpoint run retains or reports:

- Source and output codec, dimensions, nominal frame rate, duration, transform, and color properties.
- Deterministic stills from the start, middle, and end, plus named stage outputs for at least one representative frame.
- Luma/RGB histograms and an over-range/under-range pixel report for the representative frame.
- A difference image for every on/off effect comparison.
- A temporal grain diagnostic over a static crop that detects identical-frame grain, short looping, and extreme frame-to-frame deltas.
- Render duration, peak memory when available, device thermal state, writer/reader completion status, and dropped/failed frame count.

Golden comparisons use tolerances rather than byte equality where GPU or codec behavior varies. Fixture generation is explicit and versioned; changing a golden requires a recorded visual decision.

## Creator phone-review rubric

Rate each item **accept**, **revise**, or **broken**, with a one-sentence observation:

| Area | Review question |
|---|---|
| Color | Do skin, neutrals, tungsten practicals, and saturated objects feel intentional and closer to the chosen 500T reference than untreated Apple Log? |
| Highlight latitude | Do bright sources roll off without abrupt clipping, hue skews, or gray plateaus? |
| Halation | Is the warm fringe localized, scale-appropriate, and visible without looking like a red outline? |
| Glow | Do highlights diffuse softly without fogging the whole image or lifting blacks? |
| Grain still frame | Does texture feel photographic at normal viewing size without destroying faces or smooth gradients? |
| Grain motion | Does texture evolve naturally without crawling, pulsing, frozen noise, obvious tiling, or a short loop? |
| Encoding | Are gradients clean, dark areas stable, orientation correct, and audio synchronized in Photos? |
| Overall | Would the creator use this result instead of exporting the clip to the desktop for a quick turnaround? |

The slice is accepted only when no area is **broken** and the overall item is **accept**. **Revise** items become focused follow-up work; acceptance does not imply final stock calibration.

## Failure boundaries

- A render that silently skips a frame, stage, or audio sample fails even if the movie opens.
- A missing shader, LUT, grain volume, pixel buffer, or writer append fails the job with a stage-specific error; it never produces a nominally successful partial movie.
- NaN, infinity, or unexpected out-of-range values before the delivery clamp fail the diagnostic fixture.
- Cancellation, background interruption, insufficient space, or thermal pressure must leave the original source intact and the queue recoverable.

## Current versioned checkpoint recipe

The `500t-current-v1` recipe (schema 1) declares expected Apple Log 2 input based on the user's capture intent. Input gamut and LUT output gamut/transfer remain unverified: the Resolve headers and numeric range do not establish export interpretation. The current implicit cube domain is [0,1] per RGB channel. Diagnostics preserve the recipe independently of LUT hashes, report each shot's effective ISO and effects, and inspect source/output media color tags; tags do not establish calibrated delivery.

Current algorithm identities describe existing behavior: `resolve-rgb-red-fastest-linear-clamp-v1` uploads Resolve RGB/red-fastest data directly; `input-luma-warm-highlight-addition-v1` adds masked warm highlights; `constant-warm-addition-v1` adds constant warm glow; `hashed-128-volume-iso-subtractive-dither-v1` samples the existing grain volume with ISO/size scaling, subtractive grain, and dither. These identities do not certify spatial diffusion or temporal quality. `clamp-bgra8-hevc-no-color-conversion-v1` retains the existing clamp and pixel format without adding a delivery conversion.

Grain ABI note (2026-10-09): the CPU/Metal grain uniform layout is now fixed — `GrainUniforms.frameIndex` is `UInt32`, matching `grain.metal`'s `uint`. Prior builds misread `iso`/`grainSize` offsets and silently reduced grain to the ~1 LSB dither term; after the fix ISO-scaled and grainSize-scaled grain is actually applied, so grain is visibly stronger. Strength is not re-tuned until visual validation; see `Tests/GrainABITests.swift` for the layout and GPU bit-exact round-trip verification.

The HEVC/H.265 writer targets 36,000,000 bps and preserves source encoded dimensions and orientation; a 4K source remains 4K. Verified Rec.709 delivery, deterministic chart reference, dependent color-transform implementation, and creator phone acceptance remain pending provenance and approved camera-fixture evidence. The stage table above expresses the desired acceptance contract, not a claim that the current recipe satisfies it.
