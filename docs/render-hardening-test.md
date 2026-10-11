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

## Camera reliability checks

1. Record several very short clips in quick succession. Confirm each has a
   distinct file and appears in the queue. Leave one pending or failed, quit,
   and relaunch after temporary files are cleared; its original must still be
   available for rendering or raw fallback.
2. Start a recording immediately after a shutter re-meter, then switch to
   manual ISO and change lenses between takes. Confirm ISO stays fixed during
   each take and the controls continue responding. Stop and restart quickly;
   the duration should advance once and stop advancing after every terminal
   recording callback.
3. Deny camera access, open Settings from the permission message, grant camera
   access, and return. Confirm the camera starts once and the resolved message
   clears. Repeat by backgrounding while configuration is still starting; a
   hidden camera must not start after its delayed callback.
4. Tap an off-center subject with the rear and front cameras in both full and
   framed preview. Confirm focus and exposure target the tapped subject while
   pinch zoom remains available.
5. Use VoiceOver to find the record control and confirm its action changes
   between “Start recording” and “Stop recording”. Invoke the named exposure
   mode action without using the long press.
6. During repeated preview and recording, watch for missing or corrupted
   frames. Device stress is needed to supplement the synthetic Metal fixtures;
   passing unit tests does not establish hardware stability.

The automated reliability tests separately force a render failure after frames
have been processed, and exercise raw-original Photos save success and failure.
A raw-only recovery must remain a failed render and say explicitly whether the
original Apple Log was saved to Photos or remains only in the app. Partial
rendered movies must not survive a failed render.

Run `python3 scripts/verify.py verify` outside the agent sandbox for the complete
automated suite. Full diagnostic logs are in `build/verification/`.
