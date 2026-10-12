# Development summary since 6:00 PM, October 11, 2026

All code changes listed here are committed on the local `main` branch in the
canonical checkout. The deleted `docs/development.md` and untracked
`docs/prioritization.md` are user-owned working changes and were left untouched.

## Changes made after 6:00 PM

| Time (New York) | Commit | Change |
|---|---|---|
| 6:35 PM | `aab63fe` | Harden camera lifecycle and authorization changes, keep camera configuration off the main thread, retain captured originals durably, hold Metal texture wrappers through GPU completion, and persist delivered state before optional diagnostics. Add recording/exposure accessibility and prevent duplicate Photos saves. |
| 6:42 PM | `e58c2d1` | Clean up trailing whitespace in the iOS review report. |
| 8:31 PM | `2471fd6` | Require Apple Log 2 source evidence, reject incompatible/missing transfer metadata, preserve capture provenance in render output, and restore neutral contrast so the selected LUT is compared without the prior 0.6 contrast multiplier. |
| 8:49 PM | `9076f74` | Correct normalized Metal LUT coordinates so `.cube` grid knots map to texture texel centers. Preserve direct RGB/red-fastest LUT upload and LUT data. Add ColorChecker numeric probes and full identity-grid GPU checks. |
| 9:07 PM | `70ea1b3` | Avoid the reported HEVC capture crash by checking available codecs and supported settings before assigning movie output settings. Add capture-format selection and lens-change recovery checks. |
| 11:54 PM | `54c07bc` | Replace hash-speckled grain with coherent multiscale grain, add luminance latitude and detail softness, stop temporal RMS pumping, and allow B-frame reordering during offline HEVC export. |

The earlier queue statefulness, newest-first timestamped history, stock
persistence, four-stock catalog, camera controls, and render activity/error
states were already present on `main` before 6:00 PM; they remain in the
combined app and are not counted as changes from this period. The available
handoff history does not identify any additional pending DeepSeek patch.

## Grain and render behavior

Grain is applied after the LUT and spatial halation/glow passes. Its luma mask
fades in from near-black, covers shadows and midtones, then fades out toward
bright highlights. Halation and glow are generated from graded highlights and
diffuse outward before grain is applied, so grain also covers the resulting
light bloom. This is a practical optical-film-inspired order, not a calibrated
physical film simulation.

The prior single interpolated noise-volume Z position caused grain strength to
pulse across frames. Sampling centered Z planes removes the interpolation
variation while continuously changing the in-plane grain position. In the
reviewer's CPU 4K check, frame RMS variation fell from about 35% peak-to-peak
to about 2–3%. A GPU regression now checks 128 consecutive frames.

Offline export now permits HEVC frame reordering, which had been disabled and
therefore prevented B-frame coding. The target remains 60 Mbps; the writer
still uses an 8-bit BGRA pixel buffer. The improvement is based on the encoder
configuration and Apple VideoToolbox behavior. A local synthetic encode attempt
failed with VideoToolbox status `-12908`, so no controlled decoded-output A/B
has yet established how much additional grain survives on the iPhone encoder.
100–120 Mbps and a true 10-bit writer path remain untested options, not changes
included in this commit.

## Verification and branch state

The canonical checkout passed SwiftLint, 78 RenderCLI tests (zero failures and
zero skips), the generic iOS build, the signed iOS build, strict code-signature
verification for `com.filmemulation.app`, and `git diff --check`. The signed
artifact uses the configured Apple Development identity and team in
`project.yml`.

The changes are on local `main` at source commit `54c07bc`. Three clean temporary
worktrees were removed; their local branch references and commits remain. No
push was made. The local `origin/main` reference is cached and 27 commits behind
at the source commit; the report commit itself will add one more local commit.
The checked-out app was built successfully, but it was not installed or tested
with a physical phone during this verification.
