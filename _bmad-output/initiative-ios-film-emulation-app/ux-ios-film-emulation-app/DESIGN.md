---
status: final
created: '2025-07-16'
updated: '2025-07-16'
colors:
  background: '#000000'
  surface: '#1A1A1A'
  surface-elevated: '#2A2A2A'
  text-primary: '#FFFFFF'
  text-secondary: 'rgba(255,255,255,0.6)'
  accent: '#3B82F6'
  accent-locked: '#2563EB'
  record: '#FF3B30'
  record-recording: '#FF0000'
  progress: '#3B82F6'
typography:
  primary: 'SF Pro'
  monospace: 'SF Mono'
  sizes:
    xs: 11
    sm: 13
    base: 15
    lg: 17
    xl: 22
  weights:
    regular: 400
    medium: 500
    semibold: 600
rounded:
  sm: 8
  md: 12
  lg: 20
  full: 9999
spacing:
  xs: 4
  sm: 8
  md: 12
  lg: 16
  xl: 24
  safe-area-top: 'env(safe-area-inset-top)'
  safe-area-bottom: 'env(safe-area-inset-bottom)'
components:
  record-button:
    size: 80
    inner: 72
    ring: 4
  stock-strip:
    height: 44
    pill-radius: 20
  toolbar:
    height: 48
  render-pill:
    height: 32
  readout:
    height: 28
---

# DESIGN.md — iOS Film Emulation App

## Brand & Style

A stripped-down video camera for film enthusiasts. Minimal, functional, tactile. Inspired by mood.camera's restraint — the preview is the product. Dark mode only. No ornamentation. Every element earns its place or is hidden. The brand voice is quiet confidence: the app disappears and the image speaks.

Design principles: **maximum preview** · **reveal on demand** · **tactile feedback** · **dark always**.

## Colors

| Token | Value | Usage |
|-------|-------|-------|
| `background` | `#000000` | Full-screen preview background, camera chrome backdrop |
| `surface` | `rgba(0,0,0,0.45)` | Floating chrome backgrounds — stock pill, toolbar panel, readout pills, render pill |
| `surface-elevated` | `#2A2A2A` | Settings sheet, modals, active/hover states |
| `text-primary` | `#FFFFFF` | Stock names, readout values, toolbar labels, timer |
| `text-secondary` | `rgba(255,255,255,0.6)` | Secondary labels, free space text, queue count |
| `accent` | `#3B82F6` | Interactive elements, progress ring, selected state |
| `accent-locked` | `#2563EB` | Locked shutter or ISO indicator |
| `record-idle` | `#FFFFFF` | Shutter button ring (idle) |
| `record` | `#FF0000` | Recording indicator — timer, dot, button ring |

- All surfaces are dark. Chrome floats on the preview with subtle glass-morphism (dark, low-opacity backgrounds with backdrop blur). No solid bars — the preview fills the entire phone. Elements feel like they're painted on glass, not boxed in.
- Text is white at varying opacities. Never pure black text.
- Accent blue is the only non-monochrome color outside of record red.

## Typography

**SF Pro** throughout. SF Mono for technical readouts (shutter speed fractions, ISO numbers).

| Scale | Size | Weight | Usage |
|-------|------|--------|-------|
| `xs` | 11 | Medium | Free space indicator, queue count |
| `sm` | 13 | Medium | Readout labels ("SHUTTER", "ISO"), toolbar labels |
| `base` | 15 | Regular | Stock name in strip, settings items |
| `lg` | 17 | Semibold | Readout values |
| `xl` | 22 | Semibold | Clip timer during recording |

- All text is system-dynamic (no custom fonts).
- Line height: 1.2 for readouts, 1.4 for body text.
- Tabular figures for timer and readout values.

## Layout & Spacing

The preview is full-bleed, edge to edge behind the safe area. Chrome overlays the preview.

**Layout:** Full-bleed preview fills the entire phone. All chrome floats on top with glass-morphism (dark translucent backgrounds + backdrop blur). Nothing is boxed in — elements feel painted on glass.

| Element | Position | Style |
|---------|----------|-------|
| Status bar | Top 16pt, full width | Barely visible — 70% opacity white text, no background |
| Stock pill | Top ~54pt, centered | 36pt pill, `surface` background, 20pt blur, subtle border |
| Toolbar | Below status, 8pt inset | 44pt floating panel, `surface` background, 20pt blur, rounded 14pt |
| Readouts | Top right, below status | Horizontal pill group, `surface` background, locked = blue tint |
| Recording timer | Top center, below status | Red dot + monospace timer, no background |
| Shutter button | Bottom 48pt, centered | 74pt white ring, 62pt translucent inner |
| Render pill | Bottom trailing, above shutter | 32pt pill, `surface` background, progress ring |

- All floating elements have 20pt backdrop blur.
- Minimum 8pt touch target padding on all interactive elements.
- Toolbar slides open with spring animation (300ms) when stock pill is tapped.

## Elevation & Depth

- No shadows. Depth is conveyed through backdrop blur and opacity.
- Chrome backgrounds use `surface` (rgba(0,0,0,0.45)) with 20pt backdrop blur — feels like frosted glass on the preview.
- `surface-elevated`: 24pt backdrop blur on settings sheet.
- Shutter button: white ring, translucent inner circle. No background — it floats directly on the preview.

## Shapes

| Element | Radius |
|---------|--------|
| Record button | `full` (circle) |
| Stock strip pill | `full` (capsule) |
| Render pill | `full` (capsule) |
| Readout backgrounds | `sm` (8pt) |
| Toolbar items | `sm` (8pt) |
| Settings sheet | `lg` (20pt top corners) |

Everything is rounded. No sharp corners anywhere in the UI.

## Components

### Record Button
- 80pt outer circle, 4pt ring. Inner 72pt solid circle.
- Idle: ring `record`, inner `surface` with 60% opacity.
- Recording: ring `record-recording`, inner `record-recording` with 80% opacity. Subtle pulse animation (scale 1.0 → 1.05, 800ms ease-in-out loop).
- Tap: haptic feedback (`.medium` impact). 100ms scale-down to 0.95 on press.

### Stock Strip
- 44pt tall capsule pill. Background: `surface` with 12pt blur.
- Shows current stock name in `base` weight, centered. Left/right chevrons hint at swipe.
- Horizontal swipe gesture switches between 250D ↔ 500T. Haptic click on switch.
- **Tap** the pill → toolbar slides down from top. Haptic `.light`. Pill gets `accent` border (1pt) while toolbar is open.

### Toolbar
- 48pt tall horizontal bar, full width. Slides down with spring animation.
- Contains, left to right: lens selector, flash toggle, portrait toggle, EV slider, spacer, gear.
- Each item: 44pt touch target minimum. Icon + optional label in `sm` size.
- Background: `surface` with 12pt blur.
- Dismisses on tap outside or second tap on stock pill.

### EV Slider
- Horizontal slider, 120pt wide. Track: `text-secondary` at 30% opacity. Thumb: `accent` circle, 20pt.
- Snaps to 0.0 with subtle detent. Range: -2.0 to +2.0 in 0.1 increments.
- Label above: current EV value in `sm` SF Mono.

### Readouts (Shutter / ISO)
- Two stacked horizontal pills, 28pt tall. Background: `surface` with 12pt blur.
- Locked state: background shifts to `accent-locked` at 20% opacity, value text becomes `accent-locked`.
- Tappable to toggle lock. Unlocked values auto-update per AD-5.
- Shutter format: `1/48` in SF Mono `lg`. ISO format: `800` in SF Mono `lg`.
- Toggleable on/off globally via a visibility toggle (tap-hold on preview or a small eye icon near the stock strip).

### Render Pill
- Bottom-trailing corner, above safe area. 32pt tall capsule.
- Shows: small progress ring (12pt, `progress`) + queue count number in `xs` weight.
- Appears silently when render starts. Haptic `.light` if user taps it to expand queue detail.
- Expanded state: shows stock name, progress bar, "2 in queue" text. Tapping again collapses.

### Lens Selector
- Horizontal row of lens options: 13mm (ultra-wide), 24mm (wide), Tele, Front.
- Active lens: `accent` background, `text-primary` label. Inactive: `surface` background, `text-secondary` label.
- Tap to switch. Haptic on change. Smooth zoom transition on preview.

### Settings Sheet
- Presented as a bottom sheet (`.page` presentation detent on iOS 17+).
- Sections: Trial Status (days remaining, buy button), Purchase ($5/yr, $10 lifetime), Keep Original (toggle), About (version, credits).
- Background: `surface-elevated` with 24pt blur.

## Do's and Don'ts

- **Do** keep the preview dominant. Chrome appears only when needed.
- **Do** use haptics for every interactive element. The app should feel physical.
- **Don't** add any element that doesn't serve the capture → render flow.
- **Don't** use light backgrounds anywhere. Dark always.
- **Don't** animate unnecessarily. Spring for toolbar reveal, fade for render pill, nothing else.
- **Don't** interrupt recording with dialogs or overlays. Space warning appears as a subtle text pulse.