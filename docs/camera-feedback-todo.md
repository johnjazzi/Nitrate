# Camera feedback TODO

- [x] **P0 — Recording A/V timing acceptance:** Fixed discarded audio preroll, premature stop with delayed stabilized video, and audio callback starvation on the shared writer queue. All eight Log/Neutral × Off/Standard/Cinematic/Extreme device smokes passed the unchanged 0.12-second checks, measuring first nonempty audio content rather than empty-edit PTS zero. One real Extreme recording also preserved every video PTS and its encoded AAC payload through rendering. Details and limits: `docs/recording-av-timing.md`.

- [ ] **P0 — Aperture error:** Successful f/1.8 and f/1.48 changes were confirmed on the phone. Automatic operation errors now carry their source lens and are rejected during switching or after another lens becomes active; switch start clears the previous aperture-only banner. Await user confirmation of the original lens-switch complaint.
- [x] **P0 — Front recording:** Writer dimensions and display transform now follow the first accepted 4K frame, with stable geometry required for the clip. A fresh front capture passed at 2160×3840, HEVC Main10, identity transform, valid Log tags, decoded YUV preservation, and audio checks. Visual orientation remains a manual check.
- [x] **P1 — Time remaining:** Start capacity refresh automatically on launch/resume, using background reads and the existing five-second polling. Preserve coherent snapshots on failed reads.
- [x] **P1 — Camera labels:** Put the focal-length number above a smaller “mm” label; retain a distinct Front choice.
- [x] **P1 — Stock button:** Stripe colors fill the entire stock tile; its backing uses the primary stock color. Stock stays left and the camera group is centered beside it. The user clarified this is about the tile's color fill, not spanning two control rows. The time indicator is labeled “REC LEFT.”

Completion requires appropriate automated checks and a signed iOS build. Recording and aperture hardware acceptance require direct device evidence; unit tests alone do not establish those behaviors.

Verification: 115 tests passed with zero failures/skips, generic iOS build and signed device build. Evidence: `.pi/tmp/camera-todo-final-verification/` and `.pi/tmp/aperture-setter-ready-phone-probe/`.
