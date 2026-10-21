# Camera layout and focal-length pinch controls

## Behavior

- Settings → Frame Mode displays a fixed **2:3** viewfinder, aspect-filled inside the available space between stationary controls. Its rectangle stays unchanged across portrait/both landscape holds, recording timer visibility, and Debug/Fault visibility. This is a preview crop only; capture/export dimensions are unchanged.
- Settings, manual controls, lens selector, and Debug/Fault toolbar keys have round 44pt faces. The lens menu retains readable rectangular selection keys.
- Pinching the preview while idle drives equivalent focal length from **13–150 mm**, within available hardware limits. Below 24 mm selects ultrawide; 24–96 mm selects wide; above 96 mm selects telephoto. Missing rear lenses fall back to available hardware; front-camera pinches stay on front. Starting, recording, and finalizing block pinch updates.
- During a pinch, a horizontal ruler appears above the bottom controls. Major marks are **13, 24, 35, 50, 75, 96, 110, 150 mm**; crossing a major mark requests a selection haptic. Manual-panel slow zoom remains per-device and retains its separate bounds.
- EV and ISO ruler detents request selection feedback. Successfully locking manual ISO gives rigid feedback; unlocking gives softer feedback. Capture audio explicitly permits control haptics without changing audio routing.
- The LCD sits above a recessed stock/gauge well. A confirmed live take shows **RECORDING** on the LCD and lights a red tally at the top-right of the preview area. Pending start and finalization do not claim live recording. Queue/storage access remains available during a take.
- The dot and elapsed timer are absent when not actively recording. In portrait, the timer floats horizontally centered over the top bar without reserving a control slot. In landscape, it floats over the preview at the physical top edge. The lens selector remains hidden during the take.
- Debug/Fault buttons float over the capture frame, below the stationary toolbar. They do not reserve toolbar height or change preview size.
- Tapping the stock/gauge well opens the stock browser. The selected stock is centered in a snapping horizontal carousel; tapping a neighboring stock or swiping updates the selection and restores that stock's remembered gauge. Selecting the same stock does not reset its gauge.
- An independent photo carousel previews the selected stock: one bundled Apple Log 2 plate per scene with the stock's own LUT applied live on the GPU (`platePreviewFragment`), so a user-supplied cube, a grade tweak or a gauge change needs no new asset. Changing stock preserves the selected example scene. Plates are illustrative — your own photographs pushed through the licensed neutral transform, not camera originals and not a calibration — and they preview colour plus the grain of the selected stock and print gauge, sampled from the shipped grain volume with the same footprint the renderer uses. Halation and glow are still to come. The vertically scrolling sheet keeps gauge and Render reachable on smaller screens.

## Automated checks

```sh
python3 scripts/verify.py verify
python3 scripts/verify.py device
```

The coordinating agent runs both; the signed device build goes last. The full RenderCLI suite includes focal policy, layout geometry, native shared-face renders, and iOS source-wiring checks. The CameraDesignTests scheme also explicitly registers these suites in `project.yml`.

For intentional failing negative controls, confirm the local Xcode supports and pass `-collect-test-diagnostics never` to avoid large failure sysdiagnoses. A source-wiring assertion does not exercise touches or hardware.

## Physical-device acceptance

Open **Nitrate Dev**, not the TestFlight Nitrate app. Dismiss the Debug Single Frame sheet with **Done** if it is open.

1. Enable **Settings → Frame Mode**. Check the 2:3 preview, round toolbar keys, LCD above the stock/gauge well, and legibility in portrait and both landscape holds. The preview rectangle must not move or resize when rotating, starting/stopping, or showing/hiding Debug/Fault. Check that the floating Debug/Fault buttons still open their expected surfaces.
2. While idle, pinch outward/inward across 24 and 96 mm and back. Check the selected physical lens, continuous focal ruler, requested major marks, and haptic ticks. Reach 13 and 150 mm where the installed lenses support them; repeat on front and verify it stays front.
3. Move EV, long-press to lock ISO, move ISO, then unlock. Check detent feedback and distinct lock/unlock feedback with capture audio active.
4. Before recording, confirm there is no dot or elapsed timer. Start a short take: the LCD reads RECORDING, the top-right tally lights, the portrait timer is screen-centered over the top bar, and the lens selector is hidden. In landscape, the timer floats over the preview. Neither timer placement changes the frame. Pinch must not change zoom. Stop: dot and timer disappear immediately while finalizing, and the lens selector returns. Check the clip plays and queue/storage access still works.

5. Tap the stock/gauge well below the LCD. Swipe the stock strip and tap its neighboring card: the selection should snap to center, tick once, and update the photo's color. Swipe the example photos, then change stock; the same scene should stay selected. Change gauge, choose another stock, and return; each stock should remember its gauge. Scroll down to reach Render on a small phone, dismiss with Done, and reopen: the selected stock should still be centered. With a completed take, confirm Render still resumes its existing queued entry rather than creating a duplicate.

Record the hold, lens, displayed focal length, action, and a screen recording if a transition fails. Visual preference, haptic feel, and physical camera transitions require hands-on acceptance; passing builds and policy tests do not establish those.
