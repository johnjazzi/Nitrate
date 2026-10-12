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
