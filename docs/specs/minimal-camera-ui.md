# Minimal camera UI

**Status:** implemented on `feat/minimal-camera-ui`; native hands-on acceptance pending.
**Scope:** camera presentation and appearance preferences only.
**Reference:** `minimal-camera-ui/mockup.html` (self-contained interactive study).

The HTML is a design reference, not an app build. Its capture state, exposure values and processing options are mock interactions. Native capabilities, capture state and processing semantics remain authoritative.

## 1. Goal

Reduce the camera's visual weight without removing useful information or making one-handed operation harder. The viewfinder is the primary surface. Controls should read through typography, spacing and selection state, not simulated hardware.

Keep Nitrate's Barlow typography and stock identity colors. Remove raised rims, bevels, unnecessary shadows, stacked borders and nested decorative panels from the controls in scope. Use flat dark surfaces sparingly; selected states use one resolved accent and a restrained matching dark fill.

## 2. Priorities and scope

### P1 — Lens placement

Add a persisted **Lens control position** preference with two choices:
- **Top right:** compact selector opening the available lens choices.
- **Above shutter:** horizontal row for direct one-handed switching.

Retain Top right as the migration default for existing users; Above shutter is the preferred layout demonstrated in the study. This default is an implementation recommendation rather than a separately tested native behavior.

### P2 — Minimal controls

Simplify the measured-exposure display, recording status, remaining-time readout, lens faces, stock/gauge selector and mode switcher. Add the stock-aware appearance setting described below.

Do not change preview framing, capture/exposure behavior, available modes, stock rendering, grain/gauge processing or push/pull semantics as part of this work.

## 3. Lens controls

### Above shutter

- One compact horizontal row centered above the shutter.
- Reference labels: **13 · 24 · 96 · F**. F means front camera.
- Numeric labels must come from the actual available lenses. Do not advertise unsupported focal lengths or synthesize missing hardware choices.
- Visual circles approximately **30pt** in diameter, with **44 × 44pt minimum hit targets**. Space the hit targets without overlap; do not shrink accessibility targets to match the visible circles.
- Selected lens uses the resolved accent and a subtle dark fill. Inactive labels remain neutral and quiet.
- Keep the row stable when selection changes; it must not resize the preview or move the shutter.

### Top right

- Retain a compact toolbar trigger and an available-lens menu/popover.
- Use the same committed selection and lens-switch action as the bottom row.
- Changing placement changes presentation only. Do not reset zoom, switch cameras or create separate lens state.

Both placements must preserve existing transition guards, recording restrictions, front-camera behavior, accessibility labels and orientation handling. Reflect a committed lens switch rather than optimistic state if switching fails.

## 4. Measured exposure and exposure adjustment

These are distinct controls and must not be conflated:

| Element | Placement | Purpose |
| --- | --- | --- |
| Measured exposure | Bottom edge, inside preview | Reports the existing live meter value |
| Exposure adjustment | Beside shutter, on the right | Edits the existing exposure setting |

- Replace the right-side measured-exposure presentation with a fine horizontal ruler at the bottom of the preview.
- Use hairline ticks, a clear accent pointer and a compact numeric readout. No surrounding panel.
- Preserve the existing meter's value, sign, range and unavailable-state behavior. Do not substitute the requested EV setting for measured exposure.
- Keep the meter clear of the lens row, shutter and preview-edge overlays. Honor safe areas and the app's orientation policy.
- Preserve exposure adjustment gestures, manual/auto semantics, accessibility actions and haptics. The HTML does not specify new exposure math.
- Existing focus/zoom rulers remain distinct; moving the exposure meter must not delete or repurpose them.

## 5. Stock and gauge selector — concept 01

Use the approved **Beside the stock** treatment:
- Retain the colored stock chip and stock/ISO text.
- Display the gauge number immediately beside it, with **mm beneath the number**, not squeezed onto the same baseline.
- Preserve the stock colors in both minimal camera treatments and in the picker choices. The appearance accent must not replace stock identity colors.
- Stock and gauge form a clear entry point into the selection modal. Retain existing stock availability and selection behavior.
- Keep remaining recording time below this group as a quiet type-only readout, not another bordered panel.

### Selection modal

The modal contains:
1. Stock choices, with their actual identity colors and a clear selected state.
2. Print gauge choices, sourced from the existing model.
3. **Push / pull**, sourced from the existing processing controls.

Push/pull is **inside the modal only**. Do not place an N/+1/−1 processing button beside the gauge on the shooting screen.

Use the existing native push/pull range, increments, neutral label, persistence and rendering path. The HTML's example −2/−1/N/+1/+2 row demonstrates placement only; it is not authority to narrow or redefine native processing. Opening, closing or changing the modal's layout must not silently reset stock, gauge or push/pull.

## 6. D / V / P mode selection

- Minimal compact selector with the selected letter centered and neighboring available modes visible at the edges.
- Use flat selection fill and the resolved accent; avoid a heavy track, nested rings or raised faces.
- Support direct taps and the existing deliberate horizontal swipe behavior.
- Keep a small mode-name label where needed for comprehension.
- Preserve the native visible-mode list. The mockup includes Photo for visual exploration; it does **not** authorize enabling a hidden or unavailable mode.
- Selection must remain stable through switching and disabled/recording states. Do not change capture-mode ownership or bypass guards.

## 7. Recording and remaining time

- Recording status should be unboxed: small status mark and concise type directly over the preview, using existing placement/orientation rules.
- Keep red for confirmed recording and preserve distinct starting/stopping/idle states. Never show a running timer before capture is confirmed.
- Remaining recording time is a small neutral text readout beneath the stock/gauge group.
- Preserve existing armed/daylight-rescue indications, off-ramps and storage estimates. Simplification must not hide a state users need to act on.

## 8. Control color

Add a persisted **Control color** selection in the existing appearance settings:

| Choice | Behavior |
| --- | --- |
| **Follow stock** — default | Daylight stocks use halation orange; tungsten stocks use green |
| **Orange** | Fixed orange, independent of selected stock |
| **Green** | Fixed green, independent of selected stock |

### Palette

- Orange: reuse the existing shared **halation orange**, currently RGB **(0.95, 0.45, 0.12)**. The HTML equivalent is approximately **#f2731f**; native code should reuse the shared token rather than duplicate its rounded hex value.
- Green: **#c3db83**.
- Selection fills: restrained dark olive for green, dark warm neutral for orange. Final native fill opacity should be checked over actual camera footage.

### Resolution

- Follow the selected stock's daylight/tungsten metadata, **not ambient light, camera white balance or time of day**.
- Use the committed selected stock. No sensor polling or camera reconfiguration is needed.
- For no stock or unclassified stock, use the shared orange as a deterministic fallback.
- Unknown persisted preference values fall back to Follow stock.
- Resolve the accent centrally and share it across camera controls and their selection surfaces. Do not infer stock type from display-name strings in production code.

### Apply to

Selected lens/mode states, exposure setting emphasis, measured-exposure pointer, modal selection states and appropriate focus indicators.

### Do not recolor

Stock identity colors, confirmed-recording red, semantic warnings/errors or rendered output. Color must not be the only selected-state or status cue.

## 9. Implementation boundaries

- Build on the current camera/UI fixes once they are ready. This spec is not permission to overwrite their uncommitted changes.
- Reuse existing selection owners, settings conventions, layouts and shared controls. Avoid parallel camera state or duplicated rendering/processing paths.
- Use shared appearance tokens and one persisted preference per independent setting.
- No changes to white-balance locking, exposure bias ownership, lens hardware policy, output pixels, LUTs, metadata, subscription gates or release-mode feature availability.
- The mockup is approved direction, not a pixel-perfect mandate for every native screen size. Preserve its hierarchy while accommodating Dynamic Type and real device constraints.

## 10. Acceptance and verification

### Automated

- Preference defaults, unknown-value fallbacks and persistence are covered.
- Accent resolution covers daylight, tungsten, no/unclassified stock and both fixed overrides.
- Switching stock updates Follow stock but leaves fixed overrides unchanged.
- Lens presentations route through the same existing selection action and preserve the committed lens.
- Available-mode policy and existing swipe rules remain covered.
- Update source-inspection/UI convention tests intentionally when controls move; do not remove assertions merely to obtain green tests.
- Run the repo's full verification gate and signed device build before implementation handoff, using the existing verification cadence.

### Device / visual

- Review Top right and Above shutter on a small supported phone and the owner's device.
- Check all supported orientations, safe areas, Dynamic Type and VoiceOver.
- Verify 44pt minimum native hit targets, no overlapping lens targets and no controls covering the shutter.
- Verify live measured exposure remains measured exposure and sits at the preview bottom.
- Verify the stock chip retains its colors, mm sits beneath the gauge number and push/pull is reachable only within the modal.
- Check color readability over bright/dark footage, recording transitions, lens transitions, front camera and unavailable states.
- Confirm active daylight-rescue states remain visible and actionable where previously supported.
- Verify the installed app identity; builds and HTML interactions alone are not proof of native behavior.

## 11. Reference limitations

The HTML uses a bundled, ungraded sample image, simulated capture timing and two sample stocks. It cannot validate real camera performance, processing output, native accessibility or recording correctness. It intentionally leaves the current app checkout's implementation untouched.

## 12. Implementation handoff

- Preferences: `camera.controlColor` (Follow stock / Orange / Green) and
  `camera.lensControlPosition` (Top right / Above shutter), exposed in Settings → Appearance.
- The shared `cameraControlAccent` environment value resolves from stock metadata.
  Stock identity colors, recording/error semantics and the adjustable-aperture
  capability's existing purple cue are retained.
- Both lens presentations use the existing committed selection and guarded switch
  action. The direct row sorts rear focal lengths ascending with F last, uses 30pt
  faces and 44pt hit targets, and dims while switching is unavailable.
- Lens row, measured meter and transient pinch ruler are non-sizing canvas overlays.
  The bar retains its natural exposure-column height; overlay reservations also
  steer the daylight-rescue control away from them.
- Stock and stacked gauge share one entry point. Push/pull remains within the modal;
  both push and pull use the selected appearance accent, with direction stated by
  their existing words and signed values rather than a second color preference.
- The mode selector obeys the native visible-mode policy. Partially visible
  neighbors do not expose clipped touch targets; swipe and accessibility adjustment
  remain available in a narrow slot.
- Verified locally: `python3 scripts/verify.py verify` passed (lint, repository policy
  tests, 1,631 Swift tests, iOS Debug/Release builds and whitespace check). Native
  control render fixtures were inspected. This is not hardware interaction approval.
- Simulator launch verification was attempted but its tooling timed out; it is not
  counted as a passing gate. Physical UI/gesture, orientation and VoiceOver acceptance
  remain as listed above.
