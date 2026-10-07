---
status: final
created: '2025-07-16'
updated: '2025-07-16'
design: DESIGN.md
sources:
  - ../spec-ios-film-emulation-app/spec-ios-film-emulation-app.md
  - ../architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md
---

# EXPERIENCE.md — iOS Film Emulation App

## Foundation

- **Form-factor:** iOS mobile (iPhone). Portrait orientation only for v1.
- **UI system:** SwiftUI native components. No third-party design system.
- **Visual identity:** `DESIGN.md` — dark mode always, minimal chrome, maximum preview, tactile haptics.
- **Deployment target:** iOS 17+. iPhone 13 Pro or newer.

## Information Architecture

```
Camera (single screen)
├── Preview (full-bleed, always visible)
├── Record Button (always visible)
├── Stock Strip (always visible) → tap toggles Toolbar
├── Toolbar (hidden by default, drops from top)
│   ├── Lens Selector (13mm / 24mm / Tele / Front)
│   ├── Flash Toggle
│   ├── Portrait Toggle
│   └── EV Slider
├── Gear → Settings Sheet
│   ├── Trial Status
│   ├── Purchase (5/yr or 10/lifetime)
│   ├── Keep Original Toggle
│   └── About
├── Readouts (hidden by default)
│   ├── Shutter Speed (tappable lock)
│   ├── ISO (tappable lock)
│   └── Clip Timer (visible only during recording)
├── Free Space (hidden by default)
└── Render Pill (appears after recording, bottom corner)
    └── Expanded (tap) → progress + queue detail
```

## Voice and Tone

Microcopy is minimal and functional. No personality, no jokes, no marketing. The app is a tool — it speaks in labels and values. Examples:

- Stock names: "250D", "500T"
- Shutter: "1/48"
- ISO: "800"
- EV: "+0.0"
- Timer: "02:34"
- Render: "Rendering 250D..." / "2 in queue"
- Settings: "7 days remaining" / "$10 lifetime"
- Permissions: "Camera access needed to record video"

## Component Patterns

### Stock Selector
- **Behavior:** Horizontal swipe on the stock strip pill switches between 250D ↔ 500T. Haptic click on switch. Carousel wraps — swiping right on 500T goes to 250D.
- **Default:** Last used stock, persisted across sessions.
- **Toolbar trigger:** Tap the stock pill to reveal/hide the toolbar. Toolbar auto-hides on: recording start, tap outside, or second tap on pill.

### Record Flow
1. User frames shot. Preview is clean camera feed.
2. **Tap record** → haptic `.heavy`. Timer appears at top-center, counts up. Record button pulses red. Toolbar auto-hides if open.
3. **Tap stop** → haptic `.heavy`. Timer disappears. Render job is enqueued automatically with current stock + ISO settings.
4. **Render pill** appears silently in bottom-trailing corner. Progress ring animates. Queue count increments if multiple jobs pending.
5. Camera is immediately ready for next recording.

### Render Queue
- Serial queue — one job renders at a time. Others wait.
- Pill shows: progress ring (determinate during active render, hidden when idle) + queue count number.
- **Tap pill** → expands to show: current stock name, progress bar (%), "N in queue" text. Tap again to collapse.
- Queue persists across app backgrounding (Codable JSON).
- Failed render: pill shows ⚠ icon. Tap to see error + retry option.
- Completed renders save to camera roll via Photos framework. Original Apple Log file also saved.

### Exposure Controls
- **Shutter/ISO readouts** — hidden by default. Toggle visibility via long-press on preview or a small eye icon near stock strip. When visible, appear as stacked pills top-left.
- **Lock:** tap a readout to lock/unlock. Locked = `{colors.accent-locked}`. Unlocked value auto-updates per AD-5 exposure state machine.
- **EV slider** — in toolbar. Adjusts target EV (-2.0 to +2.0). Changes apply immediately to exposure calculation.
- **Shutter constraints:** displayed values are clamped to 1/24–1/100. If exposure demands faster than 1/100, shutter reads "1/100" and an overexposure indicator (small + icon) appears.

### Lens Selection
- In toolbar. Tap lens to switch. Haptic on change.
- Options: 13mm (ultra-wide), 24mm (wide), Tele, Front.
- Switching to Front camera disables portrait mode (if active).
- Preview transitions smoothly between lenses.

### Focus
- **Tap anywhere on preview** to set focus point. Standard iOS focus square animation (yellow, scales down).
- Exposure is set at the focus point (subject to ExposureMode).
- **Portrait mode:** toggle in toolbar. Enables depth capture on supported devices. Visual indicator: subtle "PORTRAIT" badge at top of preview.

### Permissions
- **First launch:** standard iOS permission dialogs in order: Camera → Microphone → Photos.
- If denied: in-app explanation text + "Open Settings" button. Never re-prompt aggressively.
- Camera denied = app shows permission-required screen. Cannot proceed.

### Settings Sheet
- **Gear icon** in toolbar → presents `.page` sheet.
- **Trial section:** "X days remaining in trial" + "Unlock Now" button.
- **Purchase:** Two options — "$5 / year" and "$10 lifetime". Selected option highlighted.
- **Keep Original:** Toggle switch. On = original Apple Log `.mov` saved alongside processed output.
- **About:** App version, build number, credits.

## State Patterns

| State | Visual |
|-------|--------|
| **Cold start** | Camera preview hidden. Permission dialog sequence in progress (Camera → Microphone → Photos). |
| **Idle** | Clean preview, stock strip, record button. Readouts hidden. Toolbar hidden. |
| **Toolbar open** | Stock strip has blue border. Toolbar visible at top. |
| **Recording** | Timer visible top-center. Record button pulsing red. Toolbar auto-hidden. |
| **Recording blocked** | Record button dimmed. Reason shown (low space / no permission). |
| **Low space (< 1GB)** | Free space text pulses amber (if visible). Recording allowed. |
| **No space (< 500MB)** | Record button disabled. "Storage full" text. |
| **Rendering** | Render pill visible with progress ring. Camera usable. |
| **Render failed** | Pill shows ⚠. Tap for details + retry. |
| **Queue idle** | No pill visible. |
| **Permissions denied** | Full-screen message with "Open Settings" button. |

## Interaction Primitives

| Gesture | Context | Action |
|---------|---------|--------|
| **Tap** | Record button | Start / stop recording |
| **Tap** | Preview | Set focus point |
| **Tap** | Stock pill | Toggle toolbar |
| **Tap** | Shutter/ISO readout | Toggle lock |
| **Tap** | Render pill | Expand / collapse queue detail |
| **Tap** | Lens option | Switch lens |
| **Tap** | Flash / Portrait toggle | Toggle on/off |
| **Tap** | Gear | Open settings |
| **Swipe (horizontal)** | Stock strip | Switch film stock (250D ↔ 500T) |
| **Drag** | EV slider | Adjust exposure value |
| **Long press** | Preview (or eye icon) | Toggle readout visibility |

All interactive elements trigger haptic feedback:
- Record start/stop: `.heavy`
- Stock switch: `.light`
- Lock toggle: `.medium`
- Toolbar toggle: `.light`
- Render pill appear: `.light`
- Lens switch: `.light`
- EV slider: none during drag, `.light` on release

## Accessibility Floor

- All interactive elements ≥ 44pt touch target.
- Readout values are VoiceOver-readable: "Shutter speed, one forty-eighth, unlocked."
- Record button: "Record video" / "Stop recording."
- Stock selector: "Film stock, Kodak 250D. Swipe left or right to change."
- Render pill: "Rendering 250D, 45 percent complete. One in queue."
- Color is never the sole differentiator: locked state also shifts opacity + VoiceOver label.
- Reduced motion: toolbar appears without spring animation. Record button pulse disabled.
- Dynamic Type: readout values scale to `larger` accessibility size before truncating.

## Key Flows

### Flow 1: First Launch → First Render
**Protagonist:** Alex, film enthusiast, just downloaded the app.

1. App launches to black screen. Camera permission dialog appears. Alex taps "Allow."
2. Microphone permission dialog. Alex taps "Allow."
3. Photos permission dialog. Alex taps "Allow."
4. Camera preview fills the screen. Stock strip shows "500T" (default). Record button visible.
5. Alex swipes stock strip left → "250D". Haptic click confirms switch.
6. Alex taps stock pill. Toolbar drops down. Alex adjusts EV to +0.3.
7. Alex taps stock pill again. Toolbar hides. Clean preview.
8. Alex frames a scene. Taps record. Heavy haptic. Timer starts counting.
9. After 30 seconds, Alex taps stop. Heavy haptic. Timer disappears.
10. Render pill silently appears in bottom corner: progress ring + "1".
11. Alex taps pill. Expanded: "Rendering 250D... 23%."
12. Render completes. Pill disappears. Processed video is in camera roll.
13. **Climax:** Alex opens Photos, plays the processed clip. It looks like 250D film.

> **Failure path:** If camera permission is denied at step 2, Alex sees the permission-required screen with "Open Settings" button. Cannot proceed until permission is granted.

### Flow 2: Manual Exposure
**Protagonist:** Sam, cinematographer, wants precise control.

1. Sam long-presses preview. Shutter and ISO readouts appear top-left.
2. Shutter shows "1/48" (default). ISO shows "800" (auto).
3. Sam taps shutter to lock it at 1/48. Readout turns blue.
4. Sam points camera at a bright window. ISO drops to 200 automatically (auto-exposing to target EV).
5. Sam locks ISO. Both readouts blue. EV indicator shows +0.7 (overexposed for current light).
6. Sam adjusts EV slider in toolbar to 0.0. Exposure changes. Indicators balance.
7. Sam records. Manual exposure holds throughout.
8. **Climax:** Sam gets exactly the exposure they wanted without touching a desktop app.

### Flow 3: Shooting While Rendering
**Protagonist:** Taylor, content creator, capturing b-roll.

1. Taylor records a 2-minute clip with 500T. Render starts. Pill shows progress ring.
2. Taylor swipes to 250D, frames a new shot. Records a 30-second clip.
3. Render pill updates: "2" in queue. First render continues.
4. Taylor records a third clip. Pill shows "3."
5. First render completes silently. Pill shows "2." Second render begins.
6. **Climax:** Taylor has captured 3 clips in 5 minutes. All three are rendering in the background. No waiting, no desktop, no file management.