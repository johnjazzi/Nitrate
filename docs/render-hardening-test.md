# Render reliability phone check

This integration branch combines the camera-control edits with render
hardening. Use its generated Xcode project to test both changes in one app.

Build and run the FilmEmulation scheme from this branch on a supported iPhone.
Automatic signing uses the team already set in `project.yml`. The unsigned
verification build does not install an app on the phone.

1. Select a stock and record a short clip. Stop recording. The render control
   should animate in orange, purple, and red, with no visible “Queue” label.
   It turns green after the processed movie is saved to Photos.
2. Record two more clips while processing continues. The badge should show
   the number of active plus waiting clips when more than one is outstanding.
   Tap the control to confirm one clip processes at a time. Recording should
   remain available throughout.
3. Tap a completed clip and play it. Confirm duration, orientation, audio, and
   playback in Photos. These are device checks, not color calibration claims.
4. Deny Photos access in iOS Settings and record another clip. A visible error
   should explain the Photos failure. The job should remain failed, the local
   processed movie should remain viewable, and the indicator should not turn
   green. Grant access, then tap Retry; it should save the retained movie.
5. Turn on Reduce Motion in Accessibility. The loading indicator should remain
   visible without rotating, and its status should be readable with VoiceOver.
6. Change the lens and exposure between clips while older clips are processing.
   Confirm the camera controls still respond and each queued clip retains its
   chosen stock and render exposure-index settings. Check the current manual
   controls alongside the loading indicator, counter, and error banner.

The automated reliability tests separately force a render failure after frames
have been processed, and exercise raw-original Photos save success and failure.
A raw-only recovery must remain a failed render and say explicitly whether the
original Apple Log was saved to Photos or remains only in the app. Partial
rendered movies must not survive a failed render.

Run `python3 scripts/verify.py verify` outside the agent sandbox for the complete
automated suite. Full diagnostic logs are in `build/verification/`.
