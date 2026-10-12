# Combined development branch

The canonical local development checkout is
`/Users/johnazzinaro/projects/untitled-ios-film-emulation-app`, branch `main`.
On 2026-10-11 it was fast-forwarded from `3e24fc3f8c3f3c3478f9894f02f85ce80c1b0b36`
to the verified integration baseline `e58c2d13c7a65bcdb2db2afcbe3d4f449aa5bcd4`.
New color-contract work continues here; use this checkout for combined tests.

## Recent implementation attribution

Git records the author as John for these commits. Agent attribution below is
from the session handoffs and BMAD plans, not inferred from the Git author.

| Commit | Change | Recorded implementation |
|---|---|---|
| `aab63fe` | Durable originals, camera lifecycle, Metal wrapper lifetime, delivery persistence, accessibility | Luna `ios_luna_fixes`, responding to Sol `ios_sol_review`; coordinator verified/committed |
| `644b88c` | Current-session history, Show all, newest-first display, stock/ISO persistence, four K2383 stocks | Luna `session_statefulness` and `stock_catalog`; coordinator integrated/reviewed/committed |
| `cf911ae` | Remove six unused iOS LUT resources | Coordinator cleanup, separately verified/committed |
| `c50fde3` | Render history timestamps | `history_timestamps` agent with coordinator verification |
| `350b527` | Writer/queue reliability, retained originals/output, failure messages, activity indication | Luna writer/queue implementation with coordinator integration and review |
| `3e24fc3` | Two-row camera controls, EV/ISO ruler, lens-output settings | Agent identity not recorded in available evidence; Git author John |
| `e58c2d1` | Review report whitespace | Coordinator |

The older temporary handoff does not identify DeepSeek commits or a pending
DeepSeek patch. Do not attribute unrecorded commits to it.

The current Log 2 safeguards, provenance and neutral-contrast changes were
implemented by Luna `color_contract_luna`. The coordinator added the capability
selection policy tests, exact decoder reference checks, range/codec evidence and
compiler correction. An independent focused reviewer identified incomplete
conflict rejection; Luna fixed it and the coordinator verified the full suite.

## Branch reconciliation

`codex/integration-camera-render`, `codex/p0-render-reliability`, and
`branding/film-reel-icon` are all ancestors of the combined `main` baseline.
Their worktrees remain available as historical references; none has additional
committed implementation that still needs to be merged into this baseline.
No branches or worktrees were deleted and no remote operation was performed.
The local `origin/main` reference was 23 commits behind immediately after the
fast-forward; it is a cached reference, not a live remote-status check.

The later working-checkout audit found `/tmp/nitrate-camera-render-integration`
clean at `e58c2d13c7a65bcdb2db2afcbe3d4f449aa5bcd4`, with no commits or patches
missing from `main`. That checkout remains historical; build the project in the
canonical checkout to include subsequent color and capture fixes.

The existing deleted `docs/development.md` and untracked `docs/prioritization.md`
are user work. They were preserved through consolidation and excluded from
implementation commits.

## Color investigation

The supplied MOV is an already rendered 250D K2383 output, tagged Rec.709 with
an unverified legacy recipe. It does not retain enough source evidence to
establish the transfer/gamut delivered to its LUT. The Blackmagic JPEG is a
Display P3 look reference, with separate framing and user-reported ISO 250 and
5600K WB; it is not the matching unprocessed source.

A deterministic Mac experiment encoded 10-bit Apple Log 2 HEVC directly from
known YCbCr values. The source contained the separate log-transfer identifier
`com.apple.apple-wide-gamut.apple-log` and BT.2020 YCbCr matrix. With the existing
RGBAHalf reader settings, neutral values .40/.55/.70 returned within .001.
Colored patches also matched the independently computed 2020 range/matrix
decode within .001. Wide-color decoding off/on returned the same values on this
Mac. This is evidence that this synthetic decoder path preserves encoded Log 2
values; it does not establish phone capture behavior or calibrate the LUT.

The actionable defects are silent Apple Log fallback, possible session overrides
of manually selected capture space, missing log-transfer diagnostics, and no
source-domain validation. The new safeguards address these and preserve evidence
in exported movies. Visual matching to Blackmagic remains a separate acceptance
question after the capture/decoder contract is established.

The supplied render had a concrete processing difference from a LUT-only
reference: `pipeline.metal` applied `(LUT_RGB - .5) * .6 + .5` using the prior
catalog's contrast value before spatial effects and grain. A LUT black of .03
therefore became .218 at that stage. At the user's direction, the new catalogs
use neutral contrast 1.0 so the LUT's contrast is retained for comparison.
Historical explicit contrast settings still decode accurately.
The supplied render selected exposure index 500,
which scales grain; the reference was reported at camera ISO 250. The render
exposure-index metadata does not establish the capture camera's actual ISO.
Grain and spatial effects can still change the appearance even with correct
input transfer; they were preserved. Future matching should separate
decoder/LUT correctness from creative effects.

## Verification ownership

Implementation agents run `python3 scripts/verify.py lint`. The coordinator runs
`python3 scripts/verify.py verify` and then `python3 scripts/verify.py device`
outside the sandbox, with the signed device build last. Automatic signing/team
remain in `project.yml`; no per-build account reconfiguration is needed.
BMAD rendering now succeeds outside the sandbox with PyPI access; the prior DNS
failure was a sandbox network restriction. Logs remain under ignored
`build/verification`.

## Capture codec exception repair

The reported `setOutputSettings` exception exposed an unconditional HEVC request.
Camera settings now use advertised codecs and supported output keys after the
configuration transaction commits and immediately before recording. Unsupported
configurations produce camera errors rather than submitting an unsupported codec.
Format selection prefers declared 10-bit bi-planar 4:2:0 Log 2 formats when
available; this preference does not itself establish encoder or source bit depth.

Failed lens changes restore the previous device's format, color space and frame
durations, and revalidate its movie settings. Failed restoration invalidates the
configured state so later setup can retry. Existing white balance, exposure
sequence and custom movie metadata are retained.

Implementation: Luna `camera_hevc_fix`, with coordinator SDK checks and a focused
independent review. The review's configuration-recovery finding was fixed.
Verification passed: 67 tests, zero failures/skips, lint, generic iOS build,
diff check and final signed device build. Actual phone capture on this new main
build still requires device confirmation; the user's working run was on the
historical integration checkout.

## Digital ColorChecker sampler check

Luna `color_contract_luna` added 24 published numeric patches from Table 2's
bottom BabelColor Avg. sRGB column in the 2006 paper (20-chart spectral average,
IEC 61966-2-1 / D65):
[RGB coordinates of the Macbeth ColorChecker](https://babelcolor.com/index_htm_files/RGB%20Coordinates%20of%20the%20Macbeth%20ColorChecker.pdf).
The coordinator independently checked all 24 triples against that table. They
are numerical LUT probes, not retagged Apple Log 2 images or camera calibration.

The production Metal kernel failed both initial chart tests. Even a 33-cube
identity LUT changed the dark-skin probe by up to .007374 per channel and the
light-skin probe by .008350. The real 50D cube's first probe differed from the
independent CPU trilinear result by .006811. This established a sampler defect:
`.cube` knots i/(N-1) were passed directly to a normalized texture sampler whose
texel centers are (i+.5)/N.

Luna corrected only sample coordinates to `(x*(N-1)+.5)/N`, preserving direct
RGB/red-fastest upload and LUT data. Both focused GPU tests then passed, including
all 33³ identity grid knots, chart probes, ramps, corners and domain clamping,
and all four shipped creative cubes. Identity tolerance is .0001 and creative
cube tolerance .001; neither was weakened to hide the original failures.
The coordinator packed the large knot set into a bounded-width 2D test texture
and added explicit per-channel finiteness checks.

Current sampling identity is `resolve-rgb-red-fastest-texel-center-linear-clamp-v2`;
the explicit 500T recipe is v4. Older algorithm metadata still decodes but fails
current execution validation rather than silently reusing a different algorithm.
This correction and neutral contrast improve adherence to the LUT definition;
creative matching to Blackmagic remains uncalibrated.
