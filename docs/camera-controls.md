# Camera layout and focal-length pinch controls

## Behavior

- Settings → Frame Mode displays a fixed **2:3** viewfinder, aspect-filled inside the available space between stationary controls. Its rectangle stays unchanged across portrait/both landscape holds, recording timer visibility, and Debug/Fault visibility. This is a preview crop only; capture/export dimensions are unchanged.
- Settings, manual controls, lens selector, and Debug/Fault toolbar keys have round 44pt faces. The lens menu retains readable rectangular selection keys.
- Pinching the preview while idle drives equivalent focal length from **13–150 mm**, within available hardware limits. Lens preference changes at 24 and 96 mm, but the installed lens stays selected until the requested focal length moves more than 1 mm past a boundary. This prevents small reversals from repeatedly rebuilding capture. The engine receives the raw gesture target while the ruler and haptics use the hardware-clamped readout. Manual lens selection is unchanged. Missing rear lenses fall back to available hardware; front-camera pinches stay on front. Starting, recording, finalizing and frame-rate changes block pinch updates.
- During an expected lens handoff, the LUT preview briefly holds its last successfully graded image instead of switching to the native Log view. A persistent missing or unsupported preview source becomes visible after a bounded grace of 1.5 seconds, measured again when the handoff completes. A valid graded frame ends the hold. A centered **Switching lenses…** notice uses the malfunction headline's 46-point compressed black-weight system font, without its red fault glow. Other brief preview interruptions say **Updating preview…**. Neither notice blocks controls. Missing LUTs and GPU failures remain immediate; changing LUT, selecting Log view or leaving the active scene clears the held image. Capture format, recording and Log validation are unchanged.
- During a pinch, a horizontal ruler appears above the bottom controls. Major marks are **13, 24, 35, 50, 75, 96, 110, 150 mm**; crossing a major mark requests a selection haptic. Manual-panel slow zoom remains per-device and retains its separate bounds.
- The exposure meter shows its numeric reading, dot and target band without OVER/UNDER or status captions. The setting keeps its value above the ruler, including ISO in manual mode, but has no bottom ISO/EV caption. Long-pressing the setting visibly expands it and returns it to rest when the hold ends; Reduce Motion uses an outline instead. Dragging or cancelling before the hold completes changes no mode. Existing detent and committed lock/unlock haptics remain, and recording or a frame-rate transition blocks the hold.
- The LCD sits above a recessed stock/gauge well. A confirmed live take shows **RECORDING** on the LCD and lights a red tally at the top-right of the preview area. Pending start and finalization do not claim live recording. Queue/storage access remains available during a take.
- The dot and elapsed timer are absent when not actively recording. In portrait, the timer floats horizontally centered over the top bar without reserving a control slot. In landscape, it floats over the preview at the physical top edge. The lens selector remains hidden during the take.
- While the session-only **60 fps** mode is armed and no take is running, an idle-only badge takes that same centered (portrait) or physical-edge (landscape) spot and opens the modal that returns to 24 fps. It is the only idle chrome: it carries no recording dot and no elapsed timer, and it is a floating sibling, so it never hides the lens selector or reserves a control slot. Above the rescue threshold the armed rescue button serves that purpose instead.
- Debug/Fault buttons float over the capture frame, below the stationary toolbar. They do not reserve toolbar height or change preview size.
- Tapping the stock/gauge well opens the stock browser. The selected stock is centered in a snapping horizontal carousel; tapping a neighboring stock or swiping updates the selection and restores that stock's remembered gauge. Selecting the same stock does not reset its gauge.
- An independent photo carousel previews the selected stock: one bundled Apple Log 2 plate per scene with the stock's own LUT applied live on the GPU (`platePreviewFragment`), so a user-supplied cube, a grade tweak or a gauge change needs no new asset. Changing stock preserves the selected example scene. Plates are illustrative — your own photographs pushed through the licensed neutral transform, not camera originals and not a calibration — and they preview colour plus the grain of the selected stock and print gauge, sampled from the shipped grain volume with the same footprint the renderer uses. Halation and glow are still to come. The vertically scrolling sheet keeps gauge and Render reachable on smaller screens.

## Decisions

### ISO lock is not persisted across app restarts — accepted October 21, 2026

Keep the current behavior: a full app restart begins with automatic ISO. Do not persist either the manual ISO lock or its selected value between launches. Returning from the background while the same app instance remains alive may retain and reapply its in-memory lock; this decision does not introduce a new reset on every foreground transition. The saved auto-exposure compensation preference is independent and remains persistent.

A manual lock still provides steady ISO during a shot. The owner considered remembering the lock between launches but rejected it for usability: different cameras have different ISO ranges, so a remembered selection may be limited on another lens, and someone repeatedly switching cameras may forget that a wider range is available elsewhere. A forgotten lock also makes returning to automatic exposure harder to discover. Those risks outweigh consistency between launches. Existing per-camera ISO limits and lock/unlock behavior remain unchanged; no exposure code change is required for this decision.

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
2. While idle, pinch outward/inward across 24 and 96 mm and back. Wobble just around each boundary: the selected lens must not bounce. Cross beyond the 1 mm band in both directions and check the switch and ruler; the readout must not become stuck at a lens's minimum. Repeat with manual lens selections. In a LUT preview mode, the previous graded picture may pause briefly during the handoff, but it must recover without a raw-Log flash or transient preview warning. Check portrait, both landscape holds and front/rear transitions. Reach 13 and 150 mm where installed hardware permits them; front pinches must stay on front. Check requested ruler marks and haptic ticks separately from this transition behavior.
3. Move EV, long-press to lock ISO, move ISO, then unlock. Check detent feedback and distinct lock/unlock feedback with capture audio active.
4. Arm 60 fps from the rescue modal, then let the meter drop below the threshold: confirm the idle 60 badge stays visible (centered on the top bar in portrait, at the physical edge in landscape) with no dot or timer, that the lens selector remains available, and that tapping it reopens the return-to-24 fps modal.
5. Before recording, confirm there is no dot or elapsed timer. Start a short take: the LCD reads RECORDING, the top-right tally lights, the portrait timer is screen-centered over the top bar, and the lens selector is hidden. In landscape, the timer floats over the preview. Neither timer placement changes the frame. Pinch must not change zoom. Stop: dot and timer disappear immediately while finalizing, and the lens selector returns. Check the clip plays and queue/storage access still works.

5. Tap the stock/gauge well below the LCD. Swipe the stock strip and tap its neighboring card: the selection should snap to center, tick once, and update the photo's color. Swipe the example photos, then change stock; the same scene should stay selected. Change gauge, choose another stock, and return; each stock should remember its gauge. Scroll down to reach Render on a small phone, dismiss with Done, and reopen: the selected stock should still be centered. With a completed take, confirm Render still resumes its existing queued entry rather than creating a duplicate.

Record the hold, lens, displayed focal length, action, and a screen recording if a transition fails. Visual preference, haptic feel, and physical camera transitions require hands-on acceptance; passing builds and policy tests do not establish those.
