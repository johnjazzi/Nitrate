# Camera layout and focal-length pinch controls

## Behavior

- Settings → Frame Mode displays a fixed portrait **2:3** viewfinder, aspect-filled inside the available space between stationary controls. This is a preview crop only; capture/export dimensions are unchanged.
- Settings, manual controls, lens selector, and Debug/Fault toolbar keys have round 44pt faces. The lens menu retains readable rectangular selection keys.
- Pinching the preview while idle drives equivalent focal length from **13–150 mm**, within available hardware limits. Below 24 mm selects ultrawide; 24–96 mm selects wide; above 96 mm selects telephoto. Missing rear lenses fall back to available hardware; front-camera pinches stay on front. Starting, recording, and finalizing block pinch updates.
- During a pinch, a horizontal ruler appears above the bottom controls. Major marks are **13, 24, 35, 50, 75, 96, 110, 150 mm**; crossing a major mark requests a selection haptic. Manual-panel slow zoom remains per-device and retains its separate bounds.
- EV and ISO ruler detents request selection feedback. Successfully locking manual ISO gives rigid feedback; unlocking gives softer feedback. Capture audio explicitly permits control haptics without changing audio routing.
- The LCD sits above a recessed stock/gauge well. A confirmed live take shows **RECORDING** on the LCD and lights a red tally at the top-right of the preview area. Pending start and finalization do not claim live recording. Queue/storage access remains available during a take.
- The dot and elapsed timer are absent when not actively recording. In portrait, the timer replaces the lens selector in the top bar. In landscape, it floats over the preview at the physical top edge; the lens selector remains hidden during the take.

## Automated checks

```sh
python3 scripts/verify.py verify
python3 scripts/verify.py device
```

The coordinating agent runs both; the signed device build goes last. The full RenderCLI suite includes focal policy, layout geometry, native shared-face renders, and iOS source-wiring checks. The CameraDesignTests scheme also explicitly registers these suites in `project.yml`.

For intentional failing negative controls, confirm the local Xcode supports and pass `-collect-test-diagnostics never` to avoid large failure sysdiagnoses. A source-wiring assertion does not exercise touches or hardware.

## Physical-device acceptance

Open **Nitrate Dev**, not the TestFlight Nitrate app. Dismiss the Debug Single Frame sheet with **Done** if it is open.

1. Enable **Settings → Frame Mode**. Check the 2:3 preview, round toolbar keys, LCD above the stock/gauge well, and legibility in portrait and both landscape holds.
2. While idle, pinch outward/inward across 24 and 96 mm and back. Check the selected physical lens, continuous focal ruler, requested major marks, and haptic ticks. Reach 13 and 150 mm where the installed lenses support them; repeat on front and verify it stays front.
3. Move EV, long-press to lock ISO, move ISO, then unlock. Check detent feedback and distinct lock/unlock feedback with capture audio active.
4. Before recording, confirm there is no dot or elapsed timer. Start a short take: the LCD reads RECORDING, the top-right tally lights, and the portrait top-bar timer replaces the lens selector. In landscape, the timer floats over the preview. Pinch must not change zoom. Stop: dot and timer disappear immediately while finalizing, and the lens selector returns. Check the clip plays and queue/storage access still works.

Record the hold, lens, displayed focal length, action, and a screen recording if a transition fails. Visual preference, haptic feel, and physical camera transitions require hands-on acceptance; passing builds and policy tests do not establish those.
