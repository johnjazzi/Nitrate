# Handoff — film-emulation app, session of 2026-10-12 (morning → 14:30 EDT)

Written for the next agent. This covers **one** workstream (camera capture +
grain/halation planning). A **different, concurrent session** was editing the same
checkout during this period (iPhone 18 aperture work); its changes are listed
separately at the end and are **not** part of this handoff's work.

**The only file this handoff itself adds is this document.** It changed no source
files. Everything else described here was either committed earlier (§2–§4) or is a
local-only planning artifact (§5e).

Source session record (local): `~/.pi/agent/sessions/--Users-johnazzinaro-projects-untitled-ios-film-emulation-app--/2026-10-12T13-16-59-033Z_01a13042-6118-703c-b2e6-ae1b9ebb1873.jsonl`

---

## 1. State at handoff

- Branch `main`. Tree is **dirty with another session's aperture work** — see §6.
- The camera failure that opened this session is **fixed and device-verified** (§2).
- Grain-size / print-gauge and halation are **planned only, zero code written** (§4–§5).
  Four delegated worker runs were spent on the grain ticket and all four produced
  **no code**; the reasons are recorded so they are not repeated.

## 2. Camera: Apple Log 2 HEVC — FIXED, device-verified, committed

**Original symptom (user, m00001):** app would not start the camera, console showed
`Apple Log 2 HEVC Main10 recording is unavailable.` User noted Blackmagic Cam *does*
allow Apple Log 2 in HEVC 10-bit, and suggested setting active colour space to
`.appleLog2` with `x422`.

**Two root causes were found, both real:**

1. **A bogus capability gate.** `configureWriterForDataOutput` required HEVC to appear
   in `AVCaptureVideoDataOutput.availableVideoCodecTypesForAssetWriter(writingTo:)`.
   On this device that list is **ProRes-only** when an Apple Log 2 4K24 format is
   active. The SDK documents that list as bounding only what
   `recommendedVideoSettingsForVideoCodecType:` may be *asked for* — it is **not** an
   `AVAssetWriter` capability check. The correct check is
   `AVAssetWriter.canApply(outputSettings:forMediaType:)`.

2. **An AVFoundation boxing bug.** The constructed-settings guard read
   `settings[AVVideoCodecKey] as? String`. AVFoundation boxes that value as
   `AVVideoCodecType`, so the cast was **always nil** and rejected the settings it had
   just built. The policy now takes `AVVideoCodecType`. The same bug had already been
   fixed in the unit test but not in production code.

3. **A third issue, found on device:** the recorded original's audio came back as
   **`lpcm`** (the device's recommendation, `AVFormatIDKey 0x6C70636D`), and the
   preservation probe hard-required AAC, **aborting every capture after the writer had
   already produced a valid file**. Audio is now requested explicitly as AAC 48 kHz.

**User's `x422` theory was never the blocker** and was already satisfied: the code
already did `lockForConfiguration` + `automaticallyConfiguresCaptureDeviceForWideColor = NO`
before setting `activeColorSpace`. The fix instead prefers the native 10-bit
**`x420`** (Main10 is nominally 4:2:0; `x422` would be silently subsampled).

**Device verification (iPhone 18 Pro, `iPhone19,2`, iOS 27.2 / 24B5089g):** smoke
capture selects `x420`, writes `hvc1` Main10 3840×2160 with the Apple Log 2
log-transfer tag (`com.apple.apple-wide-gamut.apple-log`, verified against CoreVideo)
and BT.2020 matrix, with AAC audio present. Preservation probe: max luma error
0.0012, chroma 0.0030 (limits 0.03), audio skew 0.000 s. Two consecutive smoke runs
recorded in `.pi/tmp/log2-fix-probe-2026-10-12/console-6.log` and `console-7.log`.

**Commit: `002fcec` — `fix: record Apple Log 2 HEVC Main10 originals on device`**
Files in that commit:
- `App/Modules/CameraCapture/CameraCapturePreservationProbe.swift`
- `App/Modules/CameraCapture/CameraPolicies.swift`
- `App/Modules/CameraCapture/CameraSession.swift`
- `App/Modules/FilmStockLibrary/FilmStockConfig.swift`
- `Tests/CameraPolicyTests.swift`

Earlier commits on the same chain (all in `main`):
- `7bf2822` — `fix: record Apple Log 2 through HEVC sample buffers` (the HEVC
  sample-buffer recorder: `CameraSampleBufferRecorder.swift` added, `CameraSession.swift`,
  `CameraPolicies.swift`, `CameraCapturePreservationProbe.swift`, plus new tests
  `CameraCapturePreservationProbeTests.swift`, `CameraSampleBufferRecorderTests.swift`,
  `MovieWritingReliabilityTests.swift`, and `project.yml`)
- `000c153` — `fix: retry advertised ten-bit capture formats and expose rejections`
- `54a5b7c` — `docs: preserve verified changes and pending device diagnosis`
- `4b7e239` — `docs: consolidate current camera status and temporary evidence`

## 3. Docs commit made in this session

**Commit: `6b70c35` — `docs: add prioritization master doc and drop development verification notes`**
- Added `docs/prioritization.md` (user's hand-maintained master priority list — treat as authoritative ownership, not agent output)
- Deleted `docs/development.md` (superseded; `verify.py` modes are documented by
  `python3 scripts/verify.py --help`, signing team lives in `project.yml`)
- ⚠️ Side effect it recorded: `AGENTS.md:38` still pointed at the deleted
  `docs/development.md`. **This session then fixed that** — `AGENTS.md:38` now reads
  "Use `python3 scripts/verify.py` (see the commands listed below)… There is no
  separate development setup document; this section is the source of truth." That fix
  is **uncommitted** (see §6); the tree now shows `AGENTS.md` unmodified again because
  the edit was reverted when the tree was yielded — **so the dangling reference is back
  and still needs fixing.**

## 4. Edge-modulated grain — COMMITTED (not this ticket, but relevant)

**Commit: `9545624` — `feat: modulate film grain amplitude at image edges`**
- `App/Modules/FilmStockLibrary/FilmStockConfig.swift`
- `App/Modules/ProcessingPipeline/PipelineRenderer.swift`
- `App/Modules/ProcessingPipeline/RenderDiagnostics.swift`
- `App/Resources/stocks.json`, `Resources/stocks.json`
- `Resources/Shaders/grain.metal`
- `Tests/GrainABITests.swift`, `Tests/GrainShadowTests.swift`,
  `Tests/PipelineStageAvailabilityTests.swift`, `Tests/RenderContractTests.swift`
- `docs/edge-grain-benchmark.md`

Introduced `edgeBoostMultiplier` on the grain uniform and versioned v3 recipes.
**This is the commit that made the grain uniform struct ABI-sensitive:**
`Tests/GrainABITests.swift:12-21` pins `GrainUniforms` to exactly **16 bytes**, stride
16, alignment 4, with `frameIndex`/`iso`/`grainSize`/`edgeBoostMultiplier` at offsets
0/4/8/12. Any new grain uniform field must update that test in the same change.
Commit body notes: Apple M2 benchmark 2.02594 ms off / 2.02871 ms on (+0.137%), and
explicitly **"Gauge controls deferred."**

## 5. Grain-size + print-gauge and halation — PLANNED ONLY, no code

**Nothing in this section is implemented.** All four worker runs produced zero repo
edits (verified: `grain.metal`, both `stocks.json`, `GrainABITests.swift` all show no
diff attributable to them).

### 5a. Why the worker runs failed (read this before dispatching again)

Four runs, four failures:

| runId | model | outcome |
| --- | --- | --- |
| `del_mv5er0rd_tieb` | `deepseek/deepseek-v4-pro` | killed, no output for 5 min. Burned ~30 min building a custom Swift probe harness that segfaulted repeatedly. |
| `del_mv5fs6sp_5tq3` | `deepseek/deepseek-v4-pro` | exit 0, **zero tokens**, zero tool calls, zero diff. |
| `del_mv5fv8qm_avu3` | `openrouter/~deepseek/deepseek-v4-flash-latest` | 30 min hard-limit timeout. Recon only, zero diff. |
| `del_mv5h0m8y_w2du` | `openrouter/~deepseek/deepseek-v4-flash-latest` | cancelled deliberately (tree yielded to the concurrent session). Recon only, zero diff. Do **not** resume — it would redo recon. |

**Infrastructure problem 1 — the configured delegate providers are out of credit.**
Verified by direct API call, not inferred:

```
POST https://api.deepseek.com/chat/completions
{"error":{"message":"Insufficient Balance","code":"invalid_request_error"}}
```

```
zai/glm-4.7 → HTTP 429 {"code":"1113",
  "message":"余额不足或无可用资源包,请充值"}
```

`deepseek/*` and `zai/*` delegates return **nothing at all** until credit is topped up
(this is what produced the silent exit-0-with-zero-tokens run). Only `openrouter` has
credit. **Use `openrouter/...` models for delegation.**

**Infrastructure problem 2 — scope ambiguity cost entire runs.** The v1/v2 briefs told
the worker to "wire the gauge into the existing grain amount control". Verified by
grep: **there is no grain UI and no grain amount control anywhere in the tree.**
`grep -rni "gauge|8mm|16mm|35mm" --include=*.swift App/` → no matches. Ticket 13's
"grain amount control" language refers to a deferred item that was never built. The
worker spent a whole run trying to interpret a deliverable that did not exist.
**Deliverable removed.**

**Infrastructure problem 3 — the worker builds probe harnesses instead of editing.**
Three runs burned their budget on custom measurement binaries. The briefs now say
explicitly: "do not build probe harnesses, lldb sessions, or throwaway executables."

### 5b. Measured constraints that must survive (all verified locally against the real asset)

`Resources/Grain/grain3d.raw` is **128³ little-endian float32**, values `[0.385, 0.615]`,
mean `0.49996`, std `0.04908`, **spatially uncorrelated white noise** (asset lag-1
correlation −0.02).

The shader samples it as `pixelCoord = float2(gid) / (128.0f * max(footprint, 0.1f))`
(`Resources/Shaders/grain.metal:89`), so **texels advanced per pixel = 1 / footprint**.
Simulating that exact path against the real volume:

| footprint | texels/px | lag-1 corr | stdev | regime |
| --- | --- | --- | --- | --- |
| 0.5 | 2.00 | −0.150 | 0.065 | undersampled |
| **1.0** | 1.00 | **+0.405** | 0.065 | unit rate |
| 1.5 | 0.67 | +0.498 | 0.076 | coherent |
| 3.0 | 0.33 | +0.849 | 0.076 | coherent |
| 12.0 | 0.08 | +0.988 | 0.077 | coherent |

**Consequences (these are the load-bearing findings):**

1. Coarser grain needs footprint **> 1**. Below ~1.0 the volume is undersampled: the
   correlation collapses and the result is **aliased noise, not finer grain**. A gauge
   multiplier below 1 buys noise, not finer grain → the effective footprint must be
   floored (~0.95).
2. **Noise stdev is roughly invariant to footprint** (0.065–0.083 across the whole
   range). So a size change barely changes perceived amplitude — and **size alone
   cannot make grain disappear**. That is why "75mm almost grain-free" is delivered by
   an *amplitude* multiplier, not by size.
3. **The shipped per-stock `grainSize` values are partly in the aliased zone.**
   `stocks.json` has 50D `0.6`, 200T `0.8`, 250D `1.0`, 500T `1.3` → three of four
   advance 1.25–1.67 texels/pixel. Pre-existing issue, not caused by this session.

### 5c. The ISO loudness law

`grain.metal:73` `float intensity = iso / 400.0f;` feeds `:110`
`float amount = 0.55f * intensity * (0.8f + 0.2f * min(grainSize, 2.0f)) * edgeFactor;`
→ amount is **linear** in ISO. Measured Kodak diffuse RMS granularity (48 µm aperture,
ECN-2): 50D σD≈0.007, 250D≈0.013, 500T≈0.020 → a 10× ISO change gives 2.86× σD →
**σD ∝ ISO^0.46**. Not a curve fit: speed rises with crystal projected area and
σD ∝ √area, so σD ∝ √speed. Fix: `pow(iso / 50.0f, 0.46f)`. 50→500 loudness ratio
drops from ~10.8× to **~2.9×** — this is the actual fix for the user's "heavy at high
ISO" complaint.

### 5d. User decisions already made (do not re-litigate)

- **m00404** — halation gets **per-stock geometry** (radius + tint into stock data).
- **m00404** — grain loudness at high ISO should be **slightly louder**, not ~1:1.
- **m00459** — **"Ticket 13 stands — gauge owns size."** The print-gauge selector owns
  grain *size*; ISO owns *loudness*. This **reversed** an earlier reading where ISO
  would own size (the user's own m00347 request). Note it does *not* mean keeping the
  linear loudness law.
- **m00581** — the gauge **also scales amplitude at the fine end** (75mm near-silent),
  because size alone provably cannot produce "grain-free" (§5b-2). The strict
  "size only" split is deliberately relaxed for this.
- **m00581** — ship **engine + tests only**; the selector UI is a separate ticket.
- **m00581** — **fix the shipped `grainSize` values** in the same change.

### 5e. Where the work lives

**Authoritative brief (final, v3):**
`.pi/tmp/briefs/phase1-grain-size-implementation.md` — 183 lines, contains the gauge
multiplier table (8mm 2.5/1.10, 16mm 1.6/1.00, 35mm 1.0/1.00, 75mm 0.55/0.15 as
sizeMultiplier/amplitudeMultiplier), the footprint floor, the ABI requirement, the
stock-value table, and the test list. **Dispatch from this file; do not rewrite it.**

Supporting artifacts:
- `.pi/tmp/grain-ticket-blocked-findings.md` — the failure analysis and both measured
  tables in detail (this is the source for §5a–§5c)
- `.pi/tmp/grain-halation-physics.md` — physics research, with an ACTIONABLE NUMBERS
  section
- `.pi/tmp/grain-halation-implementation.md` — implementation audit of the existing stage
- `.pi/tmp/applelog2-hevc-research.md` — Apple Log 2 / HEVC research (446 lines)
- `.pi/tmp/camera-hevc-log2-diagnosis.md` — the camera root-cause analysis
- `.pi/tmp/plan-grain-size-and-halation-response.md` → actually at
  `_bmad-output/initiative-ios-film-emulation-app/plan-grain-size-and-halation-response.md`
  — planning doc, annotated with superseded sections

Ticket tree (validated TOML, 15 entries):
`_bmad-output/initiative-ios-film-emulation-app/tracking/epic-render-quality-vertical-slice/tickets.toml`
- **entry 13** — edge-modulated grain + print gauge. **Updated** in this session to
  record the reversed axis split (gauge owns size) and the measured σD ∝ ISO^0.46 rate.
- **entry 14** — **NEW**, created in this session: halation composites as a **filled
  disc instead of a ring**, plus per-stock radius/tint.
- **entry 15** — **NEW**, created in this session: the print-gauge selector **UI**
  (blocked `after = [13]`, `hitl = true`), because there is no grain UI to extend.

⚠️ `.pi/tmp/` is gitignored via `.git/info/exclude:7`, and `_bmad-output/` is
gitignored via `.gitignore:49`. **None of the above planning artifacts will travel with
a clone or push.** They exist only in this local checkout.

### 5f. Halation defect detail (ticket 14)

`Resources/Shaders/spatial.metal` builds a highlight mask, blurs it separably, then
`spatial_composite` (kernel at `:132`) samples the blurred masks at `:152` and **adds**
it over the graded image. **Nothing subtracts the source highlight contribution**, so
added light also lands *on top of* the highlight → a bright filled disc, not a halo.
Real halation is light reflecting off the film base and re-exposing the emulsion
*around* the source; published implementations subtract the source to isolate the ring
(e.g. Darkroom Halation exposes `ring_radius` + `tail_length` + `ring_tail_balance`).

Separately, halation geometry is **global for every stock**:
`App/Modules/ProcessingPipeline/SpatialEffectsStage.swift:28-29` (radius fractions),
`:37-38` (tints), `:22-23` (thresholds), `:42` (shadow floor). Only strength varies per
stock. The app's tint `(1.0, 0.4, 0.2)` is **less red than every published reference**
(green 0.20–0.32, blue 0.10).

## 6. NOT this session — concurrent aperture work (leave alone)

A **different session** was editing this same checkout concurrently. Its work is
**not part of this handoff**.

Commits it made (13:00–13:59, after this session's last commit at 09:55):
- `6aadac1` — `feat: add capability-aware hardware aperture controls`
- `d362aff` — `feat: add tactile camera controls and storage details`
- `26f5ca9` — `Fix camera control layout and recording configuration`

**Uncommitted at handoff (dirty tree — these are theirs):**
- ` M App/Modules/CameraCapture/CameraSession.swift`
- ` M App/Modules/CameraCapture/CameraViewModel.swift`
- ` M docs/prioritization.md`
- `?? docs/camera-feedback-todo.md`

⚠️ **The tree was still actively changing when this handoff was written** (14:32 EDT).
A second file, `CameraViewModel.swift`, appeared as modified between two consecutive
status checks moments apart. Re-run `git status` before acting; the list above is a
snapshot, not the current truth.

⚠️ **Two agents wrote to one working directory during this session.** That is a hazard:
either can commit the other's half-finished edits. If you are starting fresh, confirm no
other session is active in this checkout before editing, and prefer a separate worktree
or `/tmp` isolation for delegated workers.

⚠️ **Attribution caveat.** For commits before 13:16 the two sessions' work is
interleaved in the same history and I could not definitively separate authorship from
the session logs. §2–§5 lists the **file inventory** of each commit so you can judge by
subsystem rather than trusting attribution. Commits this session verifiably authored:
`002fcec`, `6b70c35`.

## 7. Verification commands (per `AGENTS.md`)

- `python3 scripts/verify.py lint` — implementation subagents use this only
- `python3 scripts/verify.py check` — cached lint + incremental unsigned iOS compile
- `python3 scripts/verify.py verify` — lint, RenderCLI tests, generic iOS build,
  `git diff --check` — **run at task completion**
- `python3 scripts/verify.py device` — signed device build; **run last** so the final
  artifact is signed and runnable from Xcode

Xcode/Metal commands **must run outside the sandbox**. The coordinating agent owns the
compiler/build passes; implementation subagents run `lint` only.

## 8. Open items, ordered

1. **Re-fix `AGENTS.md:38`** — the dangling `docs/development.md` reference is back
   (the fix was reverted when the tree was yielded). One line.
2. **Commit the concurrent session's aperture work** — it is uncommitted and at risk.
   Not mine to commit; flagging it.
3. **Dispatch the grain ticket** from `.pi/tmp/briefs/phase1-grain-size-implementation.md`
   using an **openrouter** model, once no other session is editing the tree.
4. **Halation ticket (entry 14)** — unimplemented; the disc-vs-ring defect is a real bug.
5. **Gauge selector UI (entry 15)** — blocked on 13.
6. **Pre-existing**: three of four stocks sample the grain volume below the unit rate
   (§5b-3). User chose to fix the values as part of the grain ticket.
7. **Pre-existing**: `CLI/CLI.swift:28` hard-codes `var iso: Float = 400`, so CLI
   renders do not reflect shipped stock behaviour. Noted, not fixed.

## 9. Standing constraints (do not violate)

- Do not change **white balance locking**, the **direct RGB/red-fastest LUT upload**, or
  **remove custom movie metadata** without explicit instruction.
- Do not claim **visual or colorimetric calibration** from passing unit tests. The
  LUT/delivery contract is "user-declared", not "verified". This applies directly to
  the grain and halation work — neither may be described as matching real Vision3
  stocks.
- `project.yml` is the source of truth; `*.xcodeproj` is gitignored. Run
  `xcodegen generate` after adding or removing source files.
- Commit at every boundary (the acknowledgement is the trigger), only verified work,
  one commit per coherent batch.
