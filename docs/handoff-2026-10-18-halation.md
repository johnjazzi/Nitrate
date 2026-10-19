# Handoff — Nitrate, 2026-10-18 (halation + warning cleanup)

Written for a model switch (manager → `openai-codex/gpt-6.1-sol`; workers stay on
`openrouter/deepseek-v4.1-flash`). Everything below is verified unless marked
otherwise.

## Repo state

| where | what |
|---|---|
| `~/projects/untitled-ios-film-emulation-app` | main checkout, on `main`, `M docs/prioritization.md` (**user-owned, never commit**) |
| `~/projects/nitrate-warnings-integration` | on `dev`, the release integration worktree |
| `~/projects/nitrate-halation` | on `feat/physical-halation`, the active branch |
| `~/projects/nitrate-halation-bench` | older worktree, uncommitted harness copy — disposable |

`dev` = `27c2ccf`, pushed. `feat/physical-halation` = `27386a1`, **not pushed**.

Disk: **4.4 GiB free** and falling. 28 worktrees exist, 14 prunable. This is the
most likely thing to hard-block a build.

## Done and verified

**Warning cleanup** (on `dev`, in PR #18): app-target warnings 117 → **1**, 468/468
tests, lint, unsigned + signed device builds all pass. The one remaining warning is
`appStoreReceiptURL` in `StoreManager.swift`, **held deliberately** — it is the only
thing separating an unresolved launch from `.development`, which grants unrestricted
access, and the migration cannot be verified before the app ships.

**Capture regression found and fixed** (`525c242`, cherry-picked to `dev` as `27c2ccf`):
the AVFoundation migration deleted `expectsMediaDataInRealTime = true` from both
writer inputs, following the iOS 27 deprecation text. Result: recording failed on
device at a deterministic **28 appended frames**, `writerError=none`. Restoring the
flag fixes it, confirmed on device (clip recorded, finalized, saved). Two deprecation
warnings come back with it — correct trade, a warning is cosmetic.

**PR #18 is a DRAFT** and must stay one until `dev` is re-verified with the capture
fix. Then: `python3 scripts/verify.py verify` + `verify.py device`, push, un-draft.

**Spatial stage storage mode** (`791a17f`): the three GPU-only scratch textures now
set `.private`; the returned composite stays `.shared` because the tests read it back
with `getBytes` (making it private broke 6 tests). Worth ~0.86 ms/frame at 4K.

**Halation radius retune** (`451c997`): 5207 → 0.0055, 5219 → 0.0065. Both
`stocks.json` copies must stay **byte-identical** (RenderContractTests asserts it) —
edit them surgically, never via a JSON re-serializer.

## Physical halation — written, tests pass, NOT validated

`27386a1`. What it does:

- `spatial_halation_mask` reads the **ungraded** Apple Log 2 frame, decodes with
  Apple's own constants (vendored OCIO v2.6.0), and writes per-layer superwhite
  excess above each layer's knee.
- Three per-channel blurs: red widest, green, blue narrowest.
- `spatial_halation_composite` adds the three diffusions back. No tint — the colour
  ramp is emergent.
- `runPass1` returns `(graded, source)`; both call sites pass the ungraded frame.
- **Glow kernels are byte-identical** to before. Its look is deliberately unchanged.

Grounding: the decode reproduces the Apple Log 2 white paper table exactly (18% →
0.4882725, 90% → 0.6816867). 100% scene reflection = decoded linear **1.0**, so
knees are in multiples of diffuse white; the recorded range tops out near **12x**.

### The unvalidated part — read this before trusting the look

The per-layer **knees (1.0 / 2.0 / 4.0)**, the **radius multipliers (1.8 / 1.0 / 0.5)**
and the **8x reference superwhite** are starting points I invented. They are not
derived from anything. Consequences already known:

- The 8x normalization makes the effect roughly **half the previous magnitude** at
  equal strength, so every `halationStrength` in `stocks.json` will need re-tuning.
- Red at 1.8x the base radius makes the halo **substantially wider** than the old
  single radius.
- **Nothing has been seen on a device.** Only the macOS test suite has run.

## Known issues

1. **Flaky test:** `MovieWritingReliabilityTests.cancelledDuringRenderingRemovesPartialAndPreservesSource`
   fails under full-suite load, passes in isolation (2/2) and passed on a later full
   run. Load-sensitive, not proven to pre-date this work.
2. **Test targets carry 31 warnings** never in scope (the reported 115 counted only
   the app target). Same families, mechanical, untouched.
3. **`.storeKitTesting` is unproven**: `StoreManager.resolveDistribution()` returns
   `.debug` before consulting StoreKit in Debug, so the local fixture cannot reach
   the real paywall as things stand.
4. **watchman is crash-looping** on this machine (linked against `libfmt.11`,
   Homebrew now ships `fmt 12.1.0`). Causes repeated crash dialogs. `brew reinstall
   watchman`.

## Device testing

UDID `00008160-000648E83460000A`, bundle `com.nitrate.app.dev`. `verify.py` must run
outside the agent sandbox (Metal).

```sh
xcrun devicectl device install app --device <UDID> <path>/Nitrate.app
xcrun devicectl device process launch --device <UDID> --console --terminate-existing com.nitrate.app.dev -- -halation-benchmark
```

- **The `--` before app arguments is required**; without it devicectl parses
  `-halation-benchmark` as its own `-l` flag.
- The phone **must be unlocked** or launch fails with `reason: Locked`.
- `HalationDeviceBenchmark` runs only with `-halation-benchmark`, DEBUG only, and
  prints to stdout. It is **interleaved** on purpose: the camera session is live
  during a launch and steals GPU time in bursts, so measuring one arm as a block
  hands all the drift to whichever ran second. That produced a run reporting the
  3-blur version as 30% *faster*, which is impossible.

## Next, in order

1. Commit/land what is on `feat/physical-halation` as it is verified.
2. Re-verify `dev` (with the capture fix) → push → un-draft PR #18.
3. **Device-test the physical halation and tune it.** This is the real remaining
   work. The knobs to move first are the channel knees and radius multipliers.
4. Update the README with the physically accurate halation (user's explicit task).
5. Optionally: test-target warnings, `.storeKitTesting`, worktree/disk cleanup.
