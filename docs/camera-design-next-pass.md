# Camera design: next simplification pass

Status: implemented on the isolated design integration branch, not included in release PR #25. Native tests/builds are recorded per commit; appearance and interaction remain subject to hands-on review.

## Preserve

Keep the image debugger, including the pinned frozen image, effect re-rendering, zoom and pan. Finish and verify the gentle stock-outline pulses and compact collapsible DEBUG sections before changing the camera design.

## Palette comparison

Compare two treatments before committing to a palette:

1. Use a very dark green for the app background, darker than the current LCD green.
2. Keep the dark app background and reuse the LCD surface color for the exposure well and the surfaces behind buttons.

The owner subsequently requested removing the green LCD. The LCD now uses the exposure well’s neutral raised material; the overall app background and camera image remain unchanged.

## Configurable record-button appearance

Provide a persisted choice between the current skeuomorphic button and a modern button. Keep the current design available rather than replacing it outright.

The modern button has:

- A black idle face, red outline and red REC text.
- A red recording face with a white square stop symbol instead of REC.
- A smooth transition between idle and recording appearances, with a non-moving Reduce Motion treatment.

Use the existing capture state machine and retain starting, recording and finalization safety gates; appearance must not falsely claim a take started or change when the button can stop a take. Classic remains the default for existing behavior; Settings → Preview → Record button selects Modern.

## Align the lower controls to the frame

Move the selectors inward relative to the existing viewfinder. The follow-up request adds 4pt of breathing room inside its sides. Both columns are 84pt wide; the stock face retains its 44pt target and the exposure ruler has 48pt of width. Vertical height and the viewfinder rectangle are unchanged. Where exact inset cannot fit, preserve the non-overlapping minimum row width. Do not widen the frame to meet the controls. Preserve the image rectangle, minimum touch targets, whole-well exposure hold and stock-outline behavior, and access to recording and queue controls.

## Validation

Exercise both record styles through idle, starting, recording and stopping; verify the setting survives relaunch. Compare control/frame edges in portrait and both landscape holds, without shifting the frame when status or DEBUG/FAULT controls change. Inspect both palette candidates before selecting one. Run the existing full verification and signed device build, and install the combined artifact for hands-on approval.
