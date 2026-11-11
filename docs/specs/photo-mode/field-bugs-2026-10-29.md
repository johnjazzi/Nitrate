# Photo field failures — October 29, 2026

## Reported behavior

- Frequent “wait for camera to finish changing” refusals.
- Camera breaks after changing apps or sleeping the phone.
- Photo shutter needs immediate haptic feedback.
- Auto EV is inconsistent.
- 8/16/35/75mm grain choices seem identical; 35mm is too rough.
- DEBUG renders a substantially different image.

## Constraints

Keep one shared SDR idle graph in Photo and Video; mode taps change intent only.
Record owns the transition to Apple Log 2. Preserve stock white-balance locking,
RGB/red-fastest LUT upload, movie metadata, and retained capture originals.
Neither exposure leg held means native AE plus target bias. An ISO hold must not
silently hold the shutter. Do not fabricate RAW framework termination on timeout.

The starting revision is `78104d3`, plus six unfinished color-noise-reduction
changes preserved from the previous task. Those changes are not evidence of an
installed fix. All compiler/GPU/device operations have one coordinator; workers
edit separate sparse worktrees, without builds.

## Investigation findings and implementation ownership

1. **Controller:** request identity must own ACK/deadline settlement. The old
   stop invalidated its own only recovery deadline; late bias ACK could underflow
   a count; late exposure ACK could release a newer operation. Clamped exposure
   corrections were computed but skipped; aperture Auto could remain custom.
   Implement tokenized ownership and executable callback-order regressions.
2. **Lifecycle/session:** reject stale profile delivery, reconcile foreground
   state rather than trusting `cameraConfigured`, bound recording-start setter
   ownership, handle interruption/reset on the session queue. Preserve actual RAW
   capture ownership. Stop injecting a film shutter hold on Photo→Video idle.
3. **Feedback:** reuse existing shutter feedback trigger, increment before each
   Photo callback, remove busy-state/completion haptics. Keep the whole donut
   tappable and the shutter enabled.
4. **Gauge:** resolve the selected library gauge synchronously at shutter time.
   Store the same effective gauge in still resources and delivered recipe. Keep
   video grain unchanged. Compare still presence candidates before reducing the
   existing 2.0 gain; aesthetic acceptance is separate from kernel tests.
5. **DEBUG:** record source color space at capture. SDR sRGB/P3 input requires
   decoding/transforming before the Log renderer; pixel format alone cannot
   identify transfer. Display final values with an explicit output transform.
   Label processed-camera diagnostics honestly: they are not RAW Photo replay.
6. **Coordinator wiring:** neutral scene-EV readings compare to requested EV
   regardless of ISO lock; the shutter and DEBUG snapshot the current gauge.
   Register new production helpers in the actual test targets.

## Validation before completion

- Callback permutations: ACK, timeout, duplicate, late A after B, stop while
  pending; no negative counts, unrelated release or permanently blocked drain.
- Exposure: both-auto native AE, mode round trips, boundary command applied once,
  aperture Auto, consistent neutral-EV meter, quantized shutter acknowledgement.
- Wiring tests: current gauge reaches Photo capture and DEBUG; rescue target uses
  the same neutral-EV coordinate system. Source tests prove wiring only.
- Render tests: four distinct gauge outputs and matching metadata; actual grain
  residual measurements; asymmetric SDR/P3→Log fixture and output display test.
- Full `scripts/verify.py verify`, then signed `scripts/verify.py device`.
- Fresh physical-device checks: repeated background/foreground, sleep/wake,
  capture after return, Record/cancel/Stop then Photo, selected-gauge job evidence,
  DEBUG source diagnostics. Installation is not proof of these interactions.

Source-reachable failures are not yet attribution of the exact field run. The
old append-only exposure trace contains mixed historical tests and does not
reproduce today's repeated refusal. Final handoff must distinguish policy,
source-wiring, GPU, device and visual acceptance evidence.
