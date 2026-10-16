# Physical-device smoke test

October 15, 2026. Installed build: **Release**, `0.1.0 (1)`, signed Apple Development, bundle `app.nitrate`, minimum iOS 27.

## Why this cannot be done anywhere but the phone

Automated tests and my own verification ran on the Mac. Several of the fixes only *exist* in a Release build, and the rest depend on real hardware. So "physical-device confirmation" means these specific things, and each is listed with the check that settles it:

| Only true on hardware | Why a Mac cannot see it |
|---|---|
| Camera format negotiation | No Apple Log 2 capture format exists off-device; the simulator has no sensor |
| Real microphone PCM | Audio only arrives from a live mic; the Mac tests use a fake writer |
| Release-only code paths | `#if DEBUG` branches and Debug builds behave differently — a Debug smoke test proves nothing about Release |
| Focus / ISO hardware readback | Requires a real lens to lock focus and a real sensor to change ISO |
| Photos delivery | Needs the real photo library and its permission prompts |
| StoreKit entitlement | Needs a real device's App Store account state |
| Thermal, disk and long-run behaviour | Only measurable on the device |

The build on your phone is **Release**, so what you see is what a tester gets — minus the DEBUG button and fault-injection controls, which do not exist in Release.

## Before you start

- Phone unlocked, on iOS 27+, and this is a real Apple Log 2 device (iPhone 17 Pro or later).
- Free up a few GB. 4K Log takes are large and several checks write real files.
- Optional: run this in a terminal so failures are diagnosable — it prints the app's own diagnostics while you use it:

```sh
xcrun devicectl device process launch --console --terminate-existing \
  --device 00008160-000648E83460000A app.nitrate
```

`--console` never exits on its own. Press Ctrl-C when you are done. If you skip it, note the on-screen message instead.

## The checks

Record what you see for each. "Pass" means the stated behaviour, not "it did not crash".

### 1. Microphone denied → a clean video-only take (Release audio fix)

This is the check that matters most; the old build failed it.

1. iOS Settings → Nitrate → turn **Microphone off**.
2. Open Nitrate, record ~10 seconds, stop.
3. Expect: the take is treated as a **normal success** — it renders and saves, with no "did not pass validation" warning.

A "kept original / did not pass validation" message here means the fix is wrong, because a deliberately video-only take is legitimate.

### 2. Microphone re-enabled → audio comes back (re-attach fix)

1. Still in the app, go to iOS Settings → Nitrate → turn **Microphone on**.
2. Return to Nitrate (do not force-quit).
3. Record ~10 seconds, stop, then play the saved clip from Photos.
4. Expect: **you can hear audio.**

Silent audio here means the session never re-attached the mic, which is the exact defect this fixed.

### 3. Take with no stock selected survives a relaunch

1. In Nitrate, make sure the stock sheet closes without you choosing Render — tap **Done**.
2. Record a take with no stock chosen, then **force-quit** the app (swipe up).
3. Reopen it, tap the status LCD to open **Storage & Queue**.
4. Expect: your take is listed under **Awaiting stock**, with **Choose stock** and **Save original** available. Choose a stock and confirm it renders.

A missing take here means a capture was stranded.

### 4. Crash-window rescue (capture journal)

1. Start a recording and **force-quit the app while it is still recording**.
2. Reopen Nitrate, open **Storage & Queue**.
3. Expect: the interrupted take appears as an **Original recording** row (original-only, never rendered), with its reason shown. Use **Save original** if you want it in Photos.

### 5. Render queue survives backgrounding

1. Record and start a render.
2. While it is rendering, background the app, then reopen it.
3. Expect: the job continues or resumes, and nothing is lost or duplicated. Confirm in Photos that the clip appears **once**.

### 6. Manual focus stays manual (focus fix)

1. Open the manual controls, turn **MF** on, and set a focus position.
2. **Tap the preview** (this re-meters exposure).
3. Expect: MF stays lit and focus does **not** snap to autofocus.
4. Now switch lenses while MF is on.
5. Expect: the panel matches reality — MF stays on if the new lens can lock focus, and turns off if it cannot. It must never say MF while the lens is autofocusing.

### 7. ISO does not drift during a take (ISO fix)

1. Start a recording.
2. Try to change ISO while it is recording.
3. Expect: the change is refused, and the displayed ISO keeps matching what the camera is actually using. It must not show a value the hardware never took.

### 8. Original Log delivery preference

1. Settings → Export → enable saving the original Log alongside the render.
2. Record, render, then check Photos.
3. Expect: **both** the rendered clip and the original Log are present, and the original is unchanged.

### 9. General capture sanity

- Front and rear lenses, both landscape holds, and portrait.
- Playback orientation and audio sync on a clip longer than a minute.
- Start, stop, and cancel a recording.
- Lock the phone mid-session and return.
- Watch for heat and note roughly how long a render takes.

## If something is blocked

- **"Recording access is unavailable"** — the access gate found no verified channel and the local 7-day evaluation has expired. On this dev-signed build the channel resolves to the trial. Reinstall the app to reset the anchor, or use the Settings screen's Restore.
- **"Camera is not ready to record"** — the format negotiation failed; capture the console output.
- Anything else: note the exact on-screen text, what you did immediately before, and whether the app was foreground or background.

## What to report back

For each failing check: the check number, what you expected, what happened, the on-screen message, and whether the console printed anything. Screenshots or a short screen recording are ideal for the layout checks.

## Not covered here

- Corrupt-queue quarantine: covered by automated tests; not practically reachable by hand.
- Long-run drift, thermal limits and StoreKit sandbox purchase/expiry/refund: still open, and StoreKit needs real sandbox transactions.
- Aesthetic judgement of the film look: yours alone.
