# Photo mode implementation plan

Status: Implementation begins with P0/P1 capture/color feasibility. These technical gates must pass before broad UI/queue work; continuing the accepted scope does not require a second implementation approval. Publication and release remain separately approved. Device feasibility has not passed.

Read with `spec-photo-mode.md`, `capture-and-processing.md` and `delivery-and-validation.md`. All named new types/files below are proposed. No broad parallel implementation starts before P0 and P1 pass.

## 1. Decisions and corrected color contract

- Capture Bayer DNG at a native **12 MP-class** resolution. Proposed concrete maximum: 12,192,768 usable pixels, which includes 4032×3024. A strict 12,000,000 cutoff would incorrectly exclude that common nominal-12-MP size. Verify the actual RAW dimensions, not just the requested photo size. The first physical P0a DNG has 4224×3024 coded Bayer storage with a 4032×3024 DNG ActiveArea/DefaultCropSize. Validate that usable area against the request and bound backing storage separately to the measured 4224×3024 ceiling; do not reject padding as an oversized image or accept an unbounded sensor buffer. Retain these measured limits until another device/layout is demonstrated.
- Reuse the actual 5207 and 5219 color cubes. Do not bake a second film look, apply a monitoring LUT first or feed decoded RAW directly into a Log cube.
- The cubes consume **Apple Wide Gamut primaries + Apple Log 2 transfer**. This is established by `tools/lut-generation/generate.py`, `docs/lut-provenance.md` and the pinned OpenColorIO source. The current catalogue's `Rec.2020` input label is stale; it is not the mathematical input of these generated cubes.
- Their output is **Rec.709 primaries + pure gamma 2.4**, not the piecewise Rec.709 camera transfer function. Export must use the real generator contract rather than its generic catalogue transfer label.
- Keep the original video recipes/bytes and movie validation unchanged in this feature. Add truthful photo-specific contracts and retain the catalogue discrepancy as a separate video-contract correction, with historical decoding compatibility. Do not silently re-tag old exports or infer a camera transform from YCbCr matrix tags.
- Keep JPEG/sRGB as the proposed first-slice delivery, pending the owner's format decision. Photos supports JPEG and HEIF; it does not require JPEG. Apple Camera's Most Compatible selects JPEG and High Efficiency selects HEIF. The JPEG quality value is an encoder input, not a guaranteed percentage of original image quality.

## 2. What the LUT contains

A 33³ cube stores 35,937 output RGB triples for a grid of input RGB colors. The generator performed the expensive film simulation offline:

1. Decode each Log 2 grid color into linear Apple Wide Gamut.
2. Convert that color to CIE XYZ.
3. Constrain nonphysical grid chromaticities for the spectral model.
4. Simulate the selected negative, the 2383 print stage and projection.
5. Write Rec.709-primary, gamma-2.4 output values.

At runtime the phone interpolates this table. It does not run the spectral simulator. The confinement/filtering decisions are already baked into the cube; do not repeat them as an unrelated runtime gamut compressor. The LUT changes color and tone. Grain and spatial effects remain separate GPU passes.

The bridge is necessary because a RAW decoder produces color-managed image data, not the Log 2 code values the table expects. **Changing a tag cannot perform this bridge.**

## 3. Concrete runtime transform

| Stage | Input → output | Implementation boundary |
|---|---|---|
| RAW development | Bayer DNG → oriented, color-managed RGB image | `RAWPhotoDecoder` using `CIRAWFilter`, snapshotted decoder settings and one WB interpretation. |
| Explicit linear render | CI image → extended-linear sRGB, RGBA16Float | Metal-backed `CIContext` with explicit working/destination `CGColorSpace.extendedLinearSRGB`; do not use an untagged texture as proof of linearity. |
| Gamut + exposure adapter | linear sRGB → linear Apple Wide Gamut | `RAWToLog2Stage`, 3×3 matrix and validated, fixed reference exposure normalization. |
| Log encoding | linear Apple Wide Gamut → Apple Log 2 RGB | New photo input kernel using the pinned curve; preserve superwhites, no display tone map. |
| Shared halation | Log 2 → decode to linear → spatial scatter → Log 2 | Existing `SpatialEffectsStage.applyHalation`; logical effect remains scene-linear before LUT. |
| Stock/color | Log 2 → graded gamma-2.4 RGB | Existing LUT sampling convention, then authored output contrast. |
| Glow/grain | graded RGB → final gamma-2.4 RGB | Shared established math, but a floating-point output for stills before export conversion. |
| Delivery transform | gamma-2.4 RGB → linear Rec.709/sRGB primaries → sRGB-encoded RGB | Explicit photo output kernel; color-space conversion happens once. |
| File | sRGB RGB → tagged JPEG | Quantize once, encode with Image I/O, reopen/validate, then Photos add-only save. |

The encode/decode around the shared halation stage is deliberate initial reuse. It avoids changing video's halation input contract. A later linear-input optimization must prove parity before replacing it; it is not a prerequisite for the first still.

### 3.1 RAW decode and white balance

Configure `CIRAWFilter(imageURL:)` with a supported decoder version and store all relevant values. Disable supported optional local tone mapping, boost, sharpening/detail enhancement and noise reduction. Query capabilities and record unavailable controls. Preserve the DNG and native usable extent.

Use a Metal-backed color-managed context with RGBA half-float output. Set the working and destination spaces explicitly. Render to a texture using `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)`; its destination space is a color-conversion instruction, not just a metadata attachment. Do not disable color management with `NSNull` and then assume the sensor RGB primaries.

Extended-linear sRGB is a convenient known coordinate system, not a request to squeeze the scene into an SDR sRGB gamut. Preserve negative and above-one components in float until the photo adapter's declared handling. Test saturated RAW fixtures to prove the decoder/context did not introduce a hidden tone map or gamut clamp. If that fails, revise the decode path before using the LUT.

Snapshot the chosen stock's capture WB intent and resolve it once in RAW decoding; the existing looks use their stock WB policy before the LUT. Camera WB metadata, decoder neutral temperature/tint and generator calibration are different things. The generator's `exp_kelvin=6504` is its neutral reference for already-balanced RGB; it is not another 6504 K adjustment to apply after decoding a tungsten-balanced photo.

Exposure normalization is a versioned calibration value, not automatic per-image histogram normalization. First test the decoder's baseline/exposure behavior with a known gray chart and exposure brackets. Set the normalization policy from that evidence, store its revision and gain, and do not add an unexplained brightness factor until a chart looks pleasing. The numerical 18% example below assumes a correctly normalized linear input of 0.18; it does not prove the RAW decoder maps a photographed gray card there.

### 3.2 Linear gamut matrix

For column-vector linear RGB, use:

```text
appleWG = M × linearSRGB

M = [ 0.608104009994  0.259353392239  0.132542597767 ]
    [ 0.062315533594  0.804608849742  0.133075616663 ]
    [ 0.031132614739  0.133755845081  0.835111540179 ]
```

Derivation: `inverse(M_AppleWG_to_XYZ_D65) × M_sRGB_to_XYZ_D65`. Derive from source chromaticities rather than typing a visually tuned matrix. Apple Wide Gamut primaries are R(0.725,0.301), G(0.221,0.814), B(0.068,-0.076), white D65(0.3127,0.3290). sRGB/Rec.709 use R(0.64,0.33), G(0.30,0.60), B(0.15,0.06), the same D65. No D50 adaptation or Bradford step is needed between these two declared spaces.

Apply the validated scalar exposure normalization in linear light. Test a non-neutral vector to catch a matrix transpose or RGB/BGR swap; neutral vectors alone cannot catch either. Keep alpha 1 for opaque photographs and avoid accidental premultiplied-RGB scaling.

For the initial adapter, clamp residual negative AppleWG channels to zero **after** matrix conversion and record the clipping count. This matches the generated cube's nonnegative scene-light interpretation. Do not clamp to [0,1] in linear light: 1 is diffuse white, not the highest representable highlight. The negative policy and its saturated-color consequences are a photo acceptance gate, not a claim that clamping is colorimetrically lossless.

### 3.3 Apple Log 2 encoding

For each normalized, nonnegative AppleWG component `x`:

```text
if x < 0.01:
    E(x) = 47.28711236 × (x + 0.05641088)²
else:
    E(x) = 0.69336945 + 0.08550479 × log2(x + 0.00964052)
```

Constants match the generator, `spatial.metal` and OCIO v2.6.0 `AppleCameras.cpp`. This is Apple Log 2's curve, not ordinary logarithm-of-RGB and not an arbitrary camera LUT.

CPU reference values computed for this plan:

| Scene-linear channel | Log 2 code |
|---|---|
| 0 | 0.1504764523 |
| 0.01 | 0.2085553187 |
| 0.18 | 0.4882724585 |
| 1 | 0.6945529831 |
| 2 | 0.7794674259 |
| 4 | 0.8646759795 |
| 8 | 0.9500323841 |
| 12 | 0.9999999784 |

That is why feeding linear 0.18 straight into the LUT is wrong: the cube expects about 0.48827 at that scene level. Encode does not add the look; it just puts the color into the coordinate system the existing film cube understands.

Keep above-one Log values in half-float through pre-LUT halation when present. At the LUT boundary, clamp coordinates to the authored [0,1] domain, matching existing clamp-to-edge behavior. Log code 1 corresponds to roughly 12 scene-linear units. Count/report clipped components in diagnostic fixtures; do not claim the LUT preserves unlimited RAW highlight latitude. No additional display tone map runs before the film LUT.

### 3.4 LUT layout and interpolation

Load the actual `.cube` through the existing parser and texture upload. Preserve red-fastest row layout:

```text
row = r + g × N + b × N²
N = 33
```

For a clamped Log input `c`, the CPU reference uses `p=c×(N−1)`, surrounding grid indices and trilinear interpolation of all eight corners. Metal normalized coordinates must target texel centers:

```text
uv = (c × (N−1) + 0.5) / N
rgb = lut.sample(linearClampSampler, uv).rgb
rgb = (rgb − 0.5) × outputContrast + 0.5
```

The existing `Resources/Shaders/pipeline.metal` already implements this center correction and authored post-LUT contrast. Share it unchanged. Sampling at `uv=c`, transposing cube axes, swapping channels or applying another input contrast curve changes the look.

With halation/glow/grain disabled, linear neutral (0.18,0.18,0.18) gives these CPU trilinear values from the actual files:

| Stock | Direct cube RGB | After contrast 0.85 | After gamma-2.4 → sRGB |
|---|---|---|---|
| 5207 | 0.50888984, 0.50604270, 0.50375518 | 0.50755636, 0.50513630, 0.50319191 | 0.48047196, 0.47791879, 0.47586746 |
| 5219 | 0.50922307, 0.50623148, 0.50400868 | 0.50783961, 0.50529676, 0.50340738 | 0.48077079, 0.47808808, 0.47609479 |

These are checkpoints, not final photo-quality judgments. Keep tolerances appropriate to GPU half-float and JPEG loss; compare the float GPU output before the codec against the CPU reference first.

### 3.5 Spatial effects, grain and output encoding

Keep halation before the LUT in linear scene light, glow after the LUT and grain after glow. Reuse existing per-stock parameters and gauge behavior. Resolve any geometry-dependent radius scaling against actual still dimensions; do not use hard-coded 4K sizes or the video's grain frame-pairing policy.

The current video grain pass targets an 8-bit buffer. Add a float-output still variant or extract common grain math with a separate float destination; preserve video's current kernel/bindings and bytes. Do not quantize gamma-2.4 output to BGRA8, re-expand it and then claim a full-precision photo conversion.

After those look stages, for each gamma-2.4 output channel `v`, convert:

```text
L = max(v, 0)^2.4
S = 12.92 × L                         if L ≤ 0.0031308
S = 1.055 × L^(1/2.4) − 0.055         otherwise
```

Rec.709 and sRGB share primaries/white, so this step needs transfer conversion, not another gamut matrix. Clamp/quantize the final SDR output once. For example, a gamma-2.4 value of 0.5 becomes an sRGB code of 0.4725; simply tagging the old 0.5 as sRGB changes its intended displayed brightness.

Two valid implementations exist: explicit photo Metal transfer conversion followed by encoding already-sRGB pixels, or a correctly described source profile followed by one color-managed conversion. Choose the explicit kernel for the first slice and ensure Image I/O does not apply a second transfer conversion. A helper that assumes piecewise Rec.709 transfer is wrong for these cubes.

Use `CGImageDestination` with JPEG UTType, an sRGB color space/profile, normalized orientation, available photographic metadata and loss-quality 0.95. Keep no GPS unless an approved future requirement adds it. Reopen via `CGImageSource`, verify type/dimensions/profile/nonblank pixels, then persist the output and receipt before Photos delivery.

## 4. Work packages, files and exit gates

Implement each package as a reviewed, independently verified commit. Write assertion-level failing tests before production changes; do not count compilation failures as RED. The coordinator owns full native validation and physical-device work. Names describe file ownership, not a requirement to create a new framework for each row.

| Package | Concrete changes | Tests before implementation / exit gate | Depends on |
|---|---|---|---|
| **P0: RAW/exposure feasibility** | `CameraSession.swift` photo configuration seam; proposed `CameraPhotoCapture.swift` + `PhotoCapturePolicy.swift`; explicit output attach, Bayer query, 12-MP-class selection, fresh request/delegate owner and rollback. Preserve current ISO UI/range/Float/Lock; prototype independent Photo shutter Float/Lock across the active RAW format’s full supported duration range. Define four modes, mixed-mode metering/stabilization, EV-only-floating behavior, both-locked meter-only/no mutation, finite/range validation, `.speed` prioritization and DNG EXIF comparison. Set `activeMaxExposureDuration` after format/preset selection for Photo AE and reset/restore appropriately on Video. Handle long exposure busy/timeouts/cadence/restore. Keep P production-hidden. | Unsupported/proRAW-only/oversize candidates rejected. On phone produce readable Bayer DNG including 4032×3024 when supported, record actual dimensions/exposure, return to valid Log 2 video with audio. No broad fan-out until this passes. | None |
| **P1: RAW color adapter (authorized feasibility only)** | Proposed `RAWPhotoDecoder.swift`, `RAWToLog2Stage.swift`, photo-only `raw_to_log2.metal`; named decoder/WB/exposure contract; explicit linear render, matrix, normalization, encoding. Save development-only checkpoints outside shipping UI. | CPU transfer/matrix/domain vectors; GPU vs CPU synthetic textures; real DNG neutral/chart/exposure brackets and saturated/highlight fixtures. Verify decoder has not already display-tone-mapped. Gate exposes all unresolved normalization or clipping observations. | P0 |
| **P2: Shared still film renderer** | Extract existing LUT load/sampling and single-frame pass orchestration into a shared internal color stage; proposed `StillRenderer.swift`; float-output grain and `photo_output.metal`; no movie front-door validation for stills. | Existing video LUT/kernel tests unchanged; identity/nonlinear cube and RGB-axis tests; actual 5207/5219 CPU parity; effect order, deterministic grain, odd dimensions and JPEG reopen/profile/orientation. Full Video regression after extraction. | P1 |
| **P3: Photo recipes** | Add distinct photo IDs via `FilmStockConfig`/`FilmStockLibrary.photoStocks()`; surgical additions to both `stocks.json` copies; reuse hash-pinned existing cubes, set truthful AppleWG/Log2 input and gamma-2.4 Rec.709 output, adapter/output revisions. | Photo vs Video filtering; independent selection keys; catalogue copies equal; original video entries unchanged; snapshot round-trip; missing asset/revision fails rather than substitutes. | P1, API agreed with P2 |
| **P4: Persistence and scheduling** | Proposed `PhotoJob.swift`, `PhotoJobStore.swift`, capture journal and a shared render coordinator; integrate readiness/backpressure with current video queue without rewriting its JSON schema. | Real temporary-file round trips; journal/job acknowledgment interruption; corrupt store; container path changes; legacy movie fixtures; one active photo/video renderer; ready-job order; immutable recipe/seed and unavailable-history behavior. | P0 + P2/P3 snapshot contract |
| **P5: Delivery and recovery** | Proposed `PhotoDeliveryService.swift` sharing safe receipt/Photos primitives; JPEG first, optional original DNG separate; add-only authorization, per-save durable flags, uncertain-outcome state and safe cleanup. | Actual-file injection tests for each save/persist/unlink failure; confirmed save not repeated; ambiguous crash asks before retry; original-only recovery; shared path protection. Real Photos JPEG and optional DNG save on phone. | P4 |
| **P6: UI and controls (after feasibility)** | `CameraModeSelection.swift`, current centered carousel, `ContentView`, `CameraControlBar`, `CameraViewModel`; capability-gated P, native-aspect neutral preview, still shutter, photo controls/stock/gauge state and storage/queue status. Reconcile latest integration work first. | Actual narrow/landscape view renders, no REC timer/60fps/stabilization in P; selection commits only after session config; focus mapping, unsupported lens, one-capture busy state, Video/Develop preservation. | P0 and shared APIs; ship only after P5 |
| **P7: Integrated acceptance** | `project.yml` membership/XcodeGen, targeted tests, full suite, Debug + Release-optimized compilation, signed development build; capture evidence and owner image review. | Every A01–A12 requirement in delivery companion; real 20-shot queue/resource workload, permissions/relaunch/partial save, both stocks/all eligible lenses/holds, Video record/render and Develop import afterward. P stays production-hidden until accepted. | P0–P6 |

**Parallel boundaries:** after P1, P2/P3 and model/store preparation may run in isolated worktrees only after matching snapshot/renderer interfaces are written down. Do not let separate workers modify `CameraSession.swift`, `ContentView.swift` or catalogue arrays concurrently. Integrate engine/recipe/store commits before UI wiring. No worker installs over the coordinator's shared phone.

### Proposed shared interfaces

```swift
// Design signatures, not implemented API.
struct PhotoRecipeSnapshot: Codable, Sendable {
    // Exact resolved stock config, LUT hash, decoder and adapter revisions,
    // exposure normalization, gauge, seed, output profile/codec/quality.
}

struct CapturedPhoto: Sendable {
    let shotID: UUID
    let sourceURL: URL
    // Actual metadata, request orientation, journal ownership.
}

protocol PhotoRendering: Sendable {
    func render(sourceURL: URL,
                recipe: PhotoRecipeSnapshot,
                outputURL: URL) async throws -> PhotoRenderReceipt
}
```

`PhotoRenderReceipt` records actual encoded properties and diagnostics separately from settings. The renderer must not save to Photos, own the capture session or mutate UI selection. Capture must not resolve a recipe again after the shutter. Delivery must not render a second time merely because a save failed. Keep full-resolution textures/CI objects actor-confined rather than passing non-Sendable GPU state through public boundaries.

### P0 incremental exit gates

1. **P0a — Capture/restoration:** Add a production-hidden, explicit Debug capture path. Produce one real Bayer DNG within the native 12-MP-class budget, retain measured source metadata and restore a validated Log 2 movie with audio. Initial automatic Photo exposure is sufficient for this first experiment. The evidence directory is not a production Photo queue and does not mean a shot was delivered to Photos.
2. **P0b — Exposure:** Extend the same capture seam with the four ISO/shutter combinations. Exercise lock transitions, compensation, supported endpoints, lens revalidation and long exposures; compare requests with returned DNG exposure values. Preserve existing ISO UI behavior. Test limits and feedback without silently changing a locked variable or reopening AE.
3. **P1 — Color:** Use retained real DNGs for the explicitly color-managed decode and RAW adapter. Calibrate normalization from chart/exposure evidence. Synthetic CPU/GPU parity alone cannot close the real-RAW gate.

Keep P hidden throughout. Do not start broad renderer, queue, delivery or Photo UI work while these gates remain incomplete.

## 5. Verification specifics and evidence already obtained

Documentation-time calculations were executed with a Python reference, not inferred from the desired appearance:

- Derived the matrix from the published primaries/D65 and checked the neutral mapping.
- Computed Apple Log encode/decode for the table above, including black, branch boundary, gray and superwhites.
- Parsed all 35,937 triples from each actual cube in red-fastest layout, performed CPU trilinear sampling and applied contrast/output-transfer math for the gray table.
- Compared app/CLI cube copies and computed SHA-256 values:
  - 5207: `f483e2fb151b3b4699b8d5fd1c36df9f583952941d48c0bc99dd311e574d32b5`
  - 5219: `d2320ea308730f3aa5186d66691b91d4a94595806970cbb16059c2d067d4924a`

**Still unverified:** real Bayer negotiation at this budget; actual decoder/WB/exposure normalization; GPU parity of the new photo adapter; memory, latency, image quality, JPEG/HEIF grain comparison and Photos delivery. Existing cube math does not prove the new RAW path is correct.

Do not set all rendered-grain tests to exact JPEG byte equality. Compare precodec float checkpoints numerically, inspect decoded JPEG at suitable tolerances, and separately judge encoded grain/halation in Photos. A UI source-string assertion is neither a color test nor hardware proof.

## 6. JPEG versus HEIF decision

JPEG is a supported, compatibility-first choice for the first slice, not an Apple Photos standard that third-party apps must obey. HEIF/HEIC is Apple's High Efficiency still-image path; both belong in Photos. The file container does not decide whether the picture is HDR, wide-gamut or film-like.

Do not silently switch the spec's codec on the basis of Apple's compression claim. For Nitrate, compare the same final 12-MP-class float output encoded as JPEG and supported HEIF at documented settings. Check actual file bytes, decode/profile/orientation, delivery and visible grain/highlight quality in Photos. Quality scales are codec-specific, so 0.95 in two encoders is not evidence of equal quality. If the owner chooses HEIF, update snapshot/output/acceptance contracts before implementing that encoder; do not add a format picker unless requested.

## Primary and repository references

- Apple format compatibility: `https://support.apple.com/en-us/116944`
- RAW decoder API: `https://developer.apple.com/documentation/coreimage/cirawfilter`
- CI working-space conversion: `https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace`
- CI destination texture conversion: `https://developer.apple.com/documentation/coreimage/cicontext/render(_:to:commandbuffer:bounds:colorspace:)`
- Pinned curve/primaries: `https://raw.githubusercontent.com/AcademySoftwareFoundation/OpenColorIO/v2.6.0/src/OpenColorIO/transforms/builtins/AppleCameras.cpp`
- Repository: `tools/lut-generation/generate.py`, `docs/lut-provenance.md`, `Resources/Shaders/pipeline.metal`, `Resources/Shaders/spatial.metal`, `App/Modules/ProcessingPipeline/PipelineRenderer.swift` and `SpatialEffectsStage.swift`.
