# Subject-tracking focus — feasibility, not enabled

## Existing autofocus fix

The shared point-of-interest writer now prefers `.continuousAutoFocus` at the
selected circle, falling back to one-shot AF only if the device lacks continuous
AF. Manual focus stays held. This is continuous focus around a fixed point, not
a moving-subject lock.

## Native option

The installed iOS 27.1 SDK exposes a native non-Cinematic path:

- `device.activeFormat.isContinuousAutoFocusTrackingSupported`
- `device.isContinuousAutoFocusTrackingEnabled`
- `device.isContinuousAutoFocusTrackingSubjectAcquired`
- `AVCaptureMetadataOutput` with `.focusTrackedObject`

When supported, enable tracking while the device is locked for configuration,
set the focus point, then select `.continuousAutoFocus`. The camera chooses a
subject at that point. Metadata reports the moving subject; the device's focus
point/rectangle do not move with it. The acquired-status property cannot report
true unless the metadata output subscribes to focus-tracked objects.

This is separate from Cinematic capture. Do not enable Cinematic as a shortcut:
it applies simulated depth-of-field treatment and conflicts with the existing
manual-focus contract. No Vision tracker is needed unless the native path proves
unavailable and a separate fallback is explicitly selected.

## Gate before adding a control

- [ ] Read support on the actual still-idle and 4K Apple Log 2 recording formats.
      The opt-in Debug AF trace records this when a focus point is applied.
- [ ] If supported, attach a metadata output only after `canAddOutput` succeeds;
      verify `.focusTrackedObject` is available.
- [ ] Demonstrate acquisition and moving subject bounds, loss/reacquisition,
      tap-to-retarget, and returning to ordinary AF/MF.
- [ ] Reapply capability checks after camera/format changes. Never persist an
      enabled hardware state onto an unsupported format or silently change format.
- [ ] Verify recorded Log 2/10-bit HEVC, cadence, audio, and RAW coexistence are
      unchanged. Measure overhead rather than assuming metadata is free.
- [ ] Only then expose an optional Track control on supported configurations.
      Use the existing focus-coordinate conversions and state owner.

No tracking control or tracking setter is enabled by the autofocus bug fix.
Device-format compatibility is still unverified.

## Primary references

- Installed SDK `AVCaptureDevice.h`, categories
  `AVCaptureDeviceContinuousAutoFocusTracking` and
  `AVCaptureDeviceFormatContinuousAutoFocusTracking` (iOS 27.0+).
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuousautofocustrackingenabled
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuousautofocustrackingsubjectacquired
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/iscontinuousautofocustrackingsupported
- https://developer.apple.com/documentation/avfoundation/avmetadatafocustrackedobject
