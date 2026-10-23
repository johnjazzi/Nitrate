# Camera design: next simplification pass

Status: requested after the stock-outline pulse and compact DEBUG work. This is the design brief, not a claim that the changes are implemented.

## Preserve

Keep the image debugger, including the pinned frozen image, effect re-rendering, zoom and pan. Finish and verify the gentle stock-outline pulses and compact collapsible DEBUG sections before changing the camera design.

## Palette comparison

Compare two treatments before committing to a palette:

1. Use a very dark green for the app background, darker than the current LCD green.
2. Keep the dark app background and reuse the LCD surface color for the exposure well and the surfaces behind buttons.

The owner has not selected between these treatments. Keep the live camera image and film transform unchanged; these are chrome colors, not a new image grade.

## Configurable record-button appearance

Provide a persisted choice between the current skeuomorphic button and a modern button. Keep the current design available rather than replacing it outright.

The modern button has:

- A black idle face, red outline and red REC text.
- A red recording face with a white square stop symbol instead of REC.
- A smooth transition between idle and recording appearances, with a non-moving Reduce Motion treatment.

Use the existing capture state machine and retain starting, recording and finalization safety gates; appearance must not falsely claim a take started or change when the button can stop a take. The default appearance is not yet selected.

## Align the lower controls to the frame

Move the selectors inward so the outside edges of the exposure selector and LCD/stock selector line up with the corresponding sides of the existing viewfinder. Do not widen the frame to meet the controls. Preserve the image rectangle, minimum touch targets, whole-well exposure hold and stock-outline behavior, and access to recording and queue controls.

## Validation

Exercise both record styles through idle, starting, recording and stopping; verify the setting survives relaunch. Compare control/frame edges in portrait and both landscape holds, without shifting the frame when status or DEBUG/FAULT controls change. Inspect both palette candidates before selecting one. Run the existing full verification and signed device build, and install the combined artifact for hands-on approval.
