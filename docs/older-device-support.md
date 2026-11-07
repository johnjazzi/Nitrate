# Non-Apple-Log device HLG capture (P2)

## Scope and verification status

The non-Log path uses native 10-bit video-range 4:2:0 HLG BT.2020 (`x420`).
It is not an 8-bit fallback or an Apple Log 1 implementation. Film delivery is
still the existing SDR Rec.709 output. The original remains HDR HLG.

Rebased onto main 0.6.1 (31), base b04ea1f. This rebase has lint-only
verification; compiler, automated tests, and physical-device verification belong
to the parent. Historical coordinator results below describe the pre-rebase
feature, not a fresh 0.6.1 verification claim.

The integration reuses main's CaptureFormat, capture.format preference,
CaptureFormatAvailability, transactional live transitions, delivery framing,
RAW-photo adapters, push/pull curves and current grain ladder. There is no second
geometry enum or settings Capture section. The old installed 0.3.0 HLG app is not
the current main version; ordinary Debug builds keep 0.6.1 (31).

## Runtime eligibility, not model lists

The runtime discovers physical cameras and inspects their advertised format color
spaces. HLG is permitted only when the device advertises neither Apple Log nor
Apple Log 2. A device with Apple Log 1 but without Log 2 remains unsupported; it
must not fall through to HLG. A device with Log 2 stays on the existing Log 2
path, including when a particular lens cannot supply Log 2. No model-name list
selects the path and no stored setting can select HLG on a Log-capable device.

On first configuration, the app queries actual native formats, not device model
names. The existing Settings Capture Format row lists only geometries supported
by the active camera, permitted source profile and current session FPS. It
recomputes when the observed lens/rate changes, including session resets. No
capability means an unavailable row with no bogus UHD choice.

Open Gate 2K remains the default where capable; the existing startup/default and
stale-preference clamp uses UHD on hardware without open gate. An explicit live
geometry request is exact: an unavailable geometry fails through the existing
notice/rollback path rather than silently selecting another geometry. Log2 open
gate keeps main's native 4:2:2 requirement and UHD retains its pixel preferences.
HLG requires native video-range x420 at the chosen geometry and 24 or 60 fps.
Actual dimensions, framing and source profile remain in original metadata.

`isVideoHDRSupported` is deliberately not an HLG eligibility condition. Apple's
`AVCaptureDevice.isVideoHDREnabled` documentation says the setting is ignored
when active color space is HLG BT.2020 because HDR is always on. The implementation
does not toggle HDR or change white-balance locking.

## Hardware enumeration supplied by the coordinator

Measured device: iPhone 14 Pro / iPhone15,2, iOS 27.3.

- Each measured rear lens advertises 1920×1440 x420 up to 60 fps with HLG2020,
  while `isVideoHDRSupported` is false.
- Its x422 formats reach 30 fps with sRGB/HLG color spaces and report HDR true.
  Those are not candidates for this x420 path.
- UHD 3840×2160 x420 formats advertise HLG at 30/60 fps maxima.
- Neither Apple Log nor Apple Log 2 was advertised.

The selector checks that the frame-rate range actually includes the requested
rate; a 30 fps maximum alone does not prove 24 fps eligibility. The above is
supplied capability evidence, not a recording result from this implementation.
Recording validation on device `00008120-0016692C0C10C01E` is recorded below.
Do not infer the same capabilities for an unprobed non-Pro model.

## Color contract

The immutable film and neutral-monitor LUTs expect Apple Log 2 in Apple Wide
Gamut, not HLG and not BT.2020 RGB. See `tools/lut-generation/README.md`,
`docs/lut-provenance.md`, and `App/Resources/Preview/README.md`.

The shared Metal input adapter does:

1. Range-expand native x420 (10 bits in the high bits of 16-bit storage) and
   convert BT.2020 non-constant-luminance YCbCr to HLG RGB.
2. Apply the scene-referred inverse HLG OETF, not a display inverse OOTF, display
   gamma, or an HLG-to-SDR display tone map.
3. Apply an explicit house exposure normalization: nominal inverse-OETF 75% HLG
   white (0.2649625598) maps to scene-linear 1.0. The multiplier is
   3.7741181275. This is a declared exposure convention, not a measured camera
   calibration. CAEDRMetadata's unnormalized 0…12 convention is not used as if
   it were nominal 0…1 scene data.
4. Transform scene-linear BT.2020 D65 RGB to Apple Wide Gamut D65 RGB, using
   primaries from the vendored OCIO AppleCameras implementation. No white-point
   adaptation is needed between these D65 spaces. This is a real gamut transform,
   not just applying the Apple Log curve to BT.2020 values.
5. Encode the shared Apple Log/Log 2 curve, then run the existing halation,
   selected stock LUT, glow and grain stages. The live preview uses the same
   input adapter before its selected monitoring LUT. Push/pull behavior is not
   disabled and no cubes are regenerated or edited.

For the HLG video decoder, the renderer requests native x420 rather than asking
AVFoundation to turn HLG into RGBA-half with an implicit display transform.
Frozen HLG frames retain their native buffer and attachments into the same
adapter. Unknown/mismatched source tags fail closed. Log 2 continues to require
its distinct LogTransferFunction evidence; ordinary HDR tags are not substitutes.

## Original, queue and retry provenance

Original writer settings explicitly select HEVC Main10 and BT.2020 primaries,
HLG transfer and BT.2020 matrix. They do not label the original Apple Log 2.
The recorder checks native input layout/tags against the take's expected source,
then checks finalized HEVC Main10 4:2:0, ten-bit depth, dimensions, orientation,
source-specific tags and existing audio integrity requirements. A readable
original failing validation is still retained under existing rescue semantics.

`RenderCapturePolicy` carries `sourceProfile` through the take ledger, capture
journal, queue JSON, stock assignment, retry and renderer. Missing legacy fields
mean Apple Log 2, not HLG inferred from current hardware. Orphaned capture rescue
retains journal policy and remains original-only. Movie metadata and render color
provenance preserve the original source profile and record the adaptation into
the LUT domain. Imports still default to the Log-2-only contract; this change
does not admit HLG or Log 1 imports.

## Historical pre-rebase coordinator verification

Added suites: `HLGSupportTests` and `HLGRenderIntegrationTests`. They cover the
Log-1-not-Log-2 gate, geometry/FPS/native format selection, settings clamp,
source-tag rejection, explicit original tags, legacy policy decoding, ledger /
journal / queue persistence, independent transfer and gamut reference vectors,
production recorder finalization, actual still rendering, video rendering, and
SDR delivery tags. Existing preview GPU uniforms and runtime shader test fixtures
were updated for the shared HLG adapter.

The coordinator ran the suites and full verification, Debug/Release builds and
signed device build. Additional coverage exercises both actual Log 2 and HLG
encode/decode/render paths without the synthetic-input bypass, six preview GPU
source/code-value cases, and a frozen HLG ramp that rejects blank output. A negative
control disabled the preview HLG adapter: its three HLG cases failed; restoring
the adapter made the complete suite pass.

Physical evidence (iPhone 14 Pro, 2026-11-07):

- Native 1920×1440, 24 fps HEVC Main 10, `yuv420p10le`, video range,
  BT.2020 non-constant-luminance matrix, HLG (`arib-std-b67`) transfer.
- 77 frames / 3.208333 seconds; original source/profile metadata identifies HLG.
- Production renderer processed that actual camera file with stock 5219, with
  `syntheticTestBypass=false`. Delivered file retained all 77 frames and portrait
  orientation, with the existing eight-bit SDR Rec.709 delivery tags.
- A delivered frame was inspected: coherent, nonblank image, no gross channel or
  orientation corruption. This is not colorimetric or aesthetic approval.
- Final signed Nitrate Dev was installed; production Nitrate was not replaced.

The parent additionally supplied successful native 24 fps Open Gate and UHD
recordings rendered on the Mac to SDR, and a visually confirmed installed LUT
filtering fix. These are pre-rebase observations, not new executions here.
Remaining post-rebase verification: compilation, automated suites, first-launch
choices, 60 fps, camera/lens/mode transitions, preview/frozen parity, photos,
restart/retry and microphone/audio. Prior results do not replace these checks.

For repeatable Mac inspection, `RenderCLI` accepts an explicit
`--source-profile hlgBT2020` (default remains `appleLog2`). Its diagnostics overload
now receives the same capture policy as the normal renderer. This does not
broaden the app's video-import picker. The standalone CLI still requires a
resource bundle containing stocks/LUTs/grain/Metal shaders; the local inspection
used the already-built test resources in a scratch app wrapper.

## Primary references

- Apple `AVCaptureDevice.isVideoHDREnabled`:
  https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled
- Apple `AVCaptureColorSpace.appleLog2` specifies Apple Gamut (not the stale
  BT.2020 wording on the writer Log 2 transfer constant):
  https://developer.apple.com/documentation/avfoundation/avcapturecolorspace/applelog2
- Apple WWDC 2021 session 10047, Capture high-quality video with AVFoundation:
  https://developer.apple.com/videos/play/wwdc2021/10047/
- ITU-R BT.2100 HLG OETF equations:
  https://www.itu.int/rec/R-REC-BT.2100
- Vendored OCIO Apple transfer constants and Apple Wide Gamut chromaticities:
  `tools/lut-generation/ocio-apple-cameras.cpp`.
