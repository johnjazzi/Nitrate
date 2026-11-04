# Flash controls — specification

Status: draft for review. No implementation yet.

## 1. What the hardware actually is

Everything below has to survive this section, so it comes first.

- There is **no shutter curtain and no strobe**. The phone has one LED behind the lens, the same LED reported by `hasTorch`, `hasFlash`, `torchLevel` (0…1) and `setTorchModeOnWithLevel:`.
- A "flash" on this device is **that LED held on for a while**, not a microsecond xenon pulse. `AVCapturePhotoSettings.flashMode` lets iOS fire and meter it, but gives no control over **when** inside the exposure it fires or **how long** it stays on.
- The LED takes time to reach output — tens of milliseconds, not microseconds. That number is **unmeasured on this phone** and has to be measured before the duration control can ship (§5).
- Brightness is a hardware request, not a calibrated light. `setTorchModeOnWithLevel:` returns `AVErrorTorchLevelUnavailable` when the phone is too hot, so every level is a *request* that can be refused.
- The LED's colour temperature is fixed and is not daylight. It will not track white balance as the lamp dims.

Consequence, stated plainly: **ours is a continuous-light look, not a flash look.** We can shape where in the exposure the light lands, but we cannot freeze a moving subject the way 1/8000 flash duration does. Anything in the spec that implies a strobe is wrong.

## 2. The two modes are not the same control

### 2.1 Video — one value

Video has no shutter to sync to; every frame is illuminated for the whole frame. The only meaningful control is **how hard the lamp is driven**:

> `VideoFlashLevel` — 0–100 %, continuous, applied for the whole take.

`0` is off and must be indistinguishable from today. Above 0 the lamp is on for the entire recording, including the pre-roll.

The level is **global**: one app-wide setting, not remembered per stock, and it does not travel with push/pull. It is **read once at the start of a take and locked** — changing it mid-take is not offered, and the value that lit the take is the value written to its metadata.

### 2.2 Photo — sync point, power, and duration

A still has an exposure window with two edges. Three controls:

| Control | Values | Meaning |
|---|---|---|
| `PhotoFlashSync` | `off`, `front`, `rear` | Where in the exposure the light lands |
| `PhotoFlashIntensity` | 0–100 % | How hard the LED is driven while lit |
| `PhotoFlashDuration` | 5–100 % of the exposure | For how much of the window it stays lit |

- **Front** (leading curtain): lit from the instant the exposure opens. The lit position is the *first* position of the subject.
- **Rear** (trailing curtain): lit so it *ends* at the exposure closing. The lit position is the *last* position, and any ambient motion trail is drawn *behind* the subject. This is what photographers mean by rear-curtain sync, and it is the one that looks deliberate on a slow shutter. **Not in the first build.** The value stays in the model so it can be added without a migration, but no UI ships for it until the shutter ladder goes past 1/4 s, where it starts to matter.
- **Duration** is what makes the trail: at 100 % the lamp covers the whole exposure and there is no ambient trail at all; at 25 % the subject is lit for a quarter of the window and the remaining three quarters record ambient only.

Only ever one of these at a time. `front` at 100 % is the sane default; `rear` only becomes interesting once the shutter is slower than about 1/30 s, which §3 makes explicit.

## 3. Timing model

```
front,  D = 40%:   |####--------------------------------|      light first, trail after
rear,   D = 40%:   |--------------------------------####|      trail first, light last
front,  D = 100%:  |####################################|      no trail, just a lit exposure
```

The window is the **actual applied exposure duration**, read back from the device after the exposure is locked — not the requested value. If AE moves the shutter, the window moves with it, and the lamp timing follows the readback.

### 3.1 The ramp problem

If the light takes `R` ms to reach output, then:

- For `exposure ≥ 10 × R`, timing is meaningful and the duration control does what it says.
- For `exposure` between `R` and `10 × R`, the light is visibly ramping through the exposure — the top and tail of the window are not at the requested intensity.
- For `exposure < R`, the lamp never reaches output. **The duration control is meaningless.**

So the shutter ladder decides whether this control is honest. At 1/4 s (250 ms) everything works. At 1/500 s it cannot.

**Rule:** below a measured `minimumShapableExposure` (target: the exposure where the LED reaches 90 % of requested output — to be measured), the duration and sync controls are **disabled and say why**, and the photo is taken with the lamp on for the whole exposure at the requested intensity. A control that silently does nothing is worse than a control that is visibly unavailable.

## 4. Interaction with everything else already shipped

- **Exposure / metering.** Auto-exposure meters the scene *including the lamp*. If AE is free while the lamp is on, it will pull ISO and shutter down until the lit subject is correctly exposed and the background is black — the opposite of the intended look, and it will look like the lamp did nothing. Requirement: with the lamp on, exposure must be **locked to the ambient** (or biased down by a fixed amount) so the lamp adds to the subject rather than being metered away.
- **White balance.** Lock WB while the lamp is on. The LED is a different colour from the ambient; with auto WB the grade shifts as the lamp level changes, which reads as flicker across a take.
- **Apple Log 2.** No change to the encode path. The lamp changes what the sensor sees, nothing downstream.
- **Push/pull.** Independent. Push/pull develops the take; flash changes the light that made it. They must not share state, and the metadata must not conflate them.
- **Photo RAW.** Photos are Bayer RAW DNG with `photoQualityPrioritization = .speed`. Driving the torch ourselves means we never set `AVCapturePhotoSettings.flashMode` — the two would fight over the same LED. Custom flash is torch-only, always.
- **Thermal.** Every level is a request that can be refused. A refused level must surface as a warning, never a silent fallback to a dimmer lamp.
- **Video at 60 fps.** LED output is driven by a PWM-ish supply; low levels at short exposures can band. Must be tested at 24 and 60 fps before shipping a level slider.

## 5. What must be measured before this is buildable

1. LED ramp time to 50 % and 90 % output at 25 / 50 / 100 % level. This sets `minimumShapableExposure` and is the whole basis of §3.1.
2. Whether the torch stays on continuously across a RAW still capture, or is interrupted by the capture path.
3. Actual exposure delta at a fixed distance — does 50 % look like a stop, or like nothing? This decides whether the slider is linear-in-percent or mapped to something perceptual.
4. Thermal refusal threshold: how long at 100 % before `AVErrorTorchLevelUnavailable`.
5. Colour temperature of the lamp, so WB presets can be biased for it.

## 6. UI

One new control cell in the existing stock sheet control row, third alongside gauge and push/pull.

- **Video:** pill reads `OFF`, `25%`, `50%`, `100%`. Tap opens a small popover with a level slider and a *Lamp* label — it is a lamp in video, and the word should not pretend otherwise.
- **Photo:** pill reads `OFF` or `40%` — the duration is the number that matters. Tap opens a popover with intensity and duration sliders only; there is no sync selector in the first build, because the only sync it would offer is the one already happening.
- Duration is greyed with a one-line reason when the shutter is too fast (§3.1).
- The gauge's `(i)` sheet gets a short flash section saying the same thing as §1 and §2 — that it is a lamp, and that the duration decides how much of the exposure it covers. No distance guidance: the operator knows what a lamp does.

The control row cannot hold three cells at current widths on the narrowest phone. Either the row becomes two lines, or gauge and flash collapse to icon pills. Decide before building.

## 7. Metadata

Every delivered file records what the light actually did, not what was requested:

- `flash-mode`: `off` / `front` / `rear` / `continuous`
- `flash-intensity-percent`
- `flash-duration-percent` (photo only; omitted for video)
- `flash-exposure-seconds` — the exposure window the timing was computed against
- `flash-refused` — true with the reason when a level was rejected

## 8. Failure modes to handle explicitly

| Condition | Required behaviour |
|---|---|
| Torch refused (thermal) | Warning on screen, take continues without flash, metadata says refused |
| Shutter faster than shaping floor | Duration/sync disabled with reason; lamp on for whole exposure |
| Device has no torch | Control hidden entirely, never shown disabled |
| Lamp on, AE free | Not allowed — exposure locks (§4) |
| Take ends / capture fails | Lamp must return to off. A stuck torch is a battery fire and a dead session |

## 9. Validation plan

- **Pure policy tests** for the timing window: given `sync`, `duration`, and an exposure, the light-on interval is the expected `[start, end]`, clamped to the window, and `rear` is exactly the mirror of `front`.
- **Floor tests**: an exposure below the threshold returns `unshapable`, not a silently clamped interval.
- **Metadata tests**: every field present and correct for each mode, including `flash-refused`.
- **Device tests**: exposure delta at fixed distance per level; torch survives 50 consecutive RAW captures at 100 %; torch is off after a cancelled take; no banding at 24/60 fps at 25 % level.
- **Timing evidence**: a trace recording the requested interval and the actual torch-on/off timestamps, so the claim "the lamp was on for 40 % of the window" is measured, not asserted.

## 10. Decisions

| Question | Decision |
|---|---|
| Video level scope | Global, one app-wide setting. Not per stock, not carried with push/pull. |
| Video level during a take | Read once at start and locked. |
| Rear-sync in the first build | No. Front only; the value stays in the model for later. |
| Distance guidance in the UI | None. No caveat, no explanation of what a lamp does. |

Still open, and blocking: the five measurements in §5. Nothing about the duration control can be implemented honestly until the LED ramp time is known.
