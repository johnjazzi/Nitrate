# Camera Control

This change adds in-app hardware capture and one optional light-press adjustment.
It does not add a lock-screen capture extension or register Nitrate as a system
Camera Control launch target.

## Behavior

- A full press captures on release, using the same action and feedback as the
  on-screen shutter. In Video it starts a take, stops it, or cancels startup.
- Cancelled presses and releases from a hidden/inactive camera do nothing.
- Settings → Camera Control selects **Zoom**, **Exposure**, or **Off**. The choice
  persists; a missing or unrecognized preference defaults to Zoom.
- Off removes the slide adjustment only. Full-press capture remains available.
- Light-press adjustments use one native `AVCaptureSlider` when the session
  supports controls. Values re-enter the existing zoom and EV setters; the
  hardware control never writes capture-device properties directly.
- Zoom follows the existing idle-preview crop or the recording zoom path.
  Exposure follows the existing EV preference and is disabled while recording,
  because the current capture pipeline does not apply EV writes during a take.
- Controls are inactive behind sheets, in Develop, in the background, or during
  camera/profile/record-start/record-stop transitions. On the visible camera,
  a running take remains stoppable by full press; sheets disable capture events.
- Apple's capture-event routing also sends supported volume/remote capture
  events to the shutter action. It does not expose a Camera-Control-only source
  identifier for full presses.

## Validation

Local automation covers press arming/cancellation/one-shot release, preference
restoration, slider selection/clamping/reconciliation, and source wiring. It does
not simulate hardware button delivery, slide gestures, haptics, or image quality.
Run `python3 scripts/verify.py verify` and `python3 scripts/verify.py device`.

On a supported physical iPhone with system Camera Adjustments enabled:

1. Full-press in Video: expect one start, immediate tally/feedback, then one stop
   on the next full press. Press during startup: expect cancellation, no queued take.
2. Light-press and slide with Zoom selected. Expect preview/ruler values to agree;
   repeat while recording and after switching lenses.
3. Select Exposure. Expect idle EV adjustment, matching ruler and persisted EV;
   during recording the exposure slide must be inactive, not silently accepted.
4. Select Off. Expect no slide adjustment, but full press must still start/stop.
   Relaunch and confirm the selected setting survives.
5. Open Settings/queue/stock sheets, enter Develop, and background/foreground the
   app. Expect no hidden capture; controls should return on the visible camera.
6. If Photo is enabled in the build, full-press captures one photo through the
   existing queue. A cancelled press or a press spanning a mode change must not
   capture on release.

For a failure, retain the selected setting, camera/lens, mode, lifecycle sequence,
and whether the same on-screen action succeeds. Build success is not a substitute
for these physical interaction checks.
