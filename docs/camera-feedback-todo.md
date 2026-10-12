# Camera feedback TODO

- [ ] **P0 — Aperture error:** Successful f/1.8 and f/1.48 changes were confirmed on the phone. Fixed the stale banner that remained after successful selection; final verification and user confirmation of the original failure remain pending. All 32 support queries passed; the original rejection was not reproduced.
- [x] **P0 — Front recording:** Writer dimensions and display transform now follow the first accepted 4K frame, with stable geometry required for the clip. A fresh front capture passed at 2160×3840, HEVC Main10, identity transform, valid Log tags, decoded YUV preservation, and audio checks. Visual orientation remains a manual check.
- [x] **P1 — Time remaining:** Start capacity refresh automatically on launch/resume, using background reads and the existing five-second polling. Preserve coherent snapshots on failed reads.
- [x] **P1 — Camera labels:** Put the focal-length number above a smaller “mm” label; retain a distinct Front choice.
- [ ] **P1 — Stock button:** Expand the stock button to the requested full height while retaining camera alignment and centered record control. Exact height scope needs clarification.

Completion requires appropriate automated checks and a signed iOS build. Recording and aperture hardware acceptance require direct device evidence; unit tests alone do not establish those behaviors.

Verification: 115 tests passed with zero failures/skips, generic iOS build and signed device build. Evidence: `.pi/tmp/camera-todo-final-verification/` and `.pi/tmp/aperture-setter-ready-phone-probe/`.
