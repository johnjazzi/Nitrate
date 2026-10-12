# Development handoff — October 12, 2026

## Repository state

Grain work is committed as `9545624` (`feat: modulate film grain amplitude at image edges`), on top of camera baseline `7bf2822`. Camera retry/diagnostics is committed as `000c153`. Its full verification passed 100 tests with 0 failures or skips, generic iOS build, signed device build, and strict codesign. Logs: `.pi/tmp/x422-diagnostics-verify.log`, `.pi/tmp/x422-diagnostics-device.log`, `.pi/tmp/x422-diagnostics-codesign.log`; test summary: `.pi/tmp/test-summary.json`. Do not start another build in this session.

User-owned `docs/development.md` deletion and untracked `docs/prioritization.md` remain untouched. This handoff is untracked pending coordinator review/commit. `.pi/tmp/` evidence is local scratch. No remote push was made.

## Completed: edge-modulated grain

The production grain kernel now increases existing grain amplitude at image transitions using the already-loaded neighboring samples. All four shipped stocks explicitly declare the v3 edge-amplitude recipe at multiplier 3; archived/missing v2 values remain zero. Recipe validation, ABI, archive, catalog, metadata, and GPU behavior coverage were added. No gauge/amount UI was added; that larger ticket is deferred.

Commit `9545624` passed full verification (100 tests, 0 failures/skips), generic iOS compilation, signed device build, and strict codesign. Sol's review is closed with no remaining actionable findings. The isolated 4K benchmark ran one actual Swift Testing benchmark and wrote `.pi/tmp/edge-grain-benchmark-2026-10-12.md`: Apple M2, production RGBA16Float input/BGRA8Unorm output, shipped grain volume; 5 warm-ups and 20 paired samples per setting. Median boost-0 was 2.02594 ms; boost-3 was 2.02871 ms; measured overhead was +0.00277 ms (+0.1368%). Zero pixels away from the transition changed. This is a single-device/run result, not a cross-device performance or film-look calibration claim. Sol's review and the corrected standalone command are in `.pi/tmp/edge-grain-sol-review.md` and `docs/edge-grain-benchmark.md`.

## Camera retry and remaining device acceptance

The camera patch on `7bf2822` tries each advertised ten-bit bi-planar format, validates HEVC Main10 settings with `AVAssetWriter.canApply`, and logs advertised/attempted formats, codecs, and rejection reasons. The diagnostic follow-up added logging at the configuration boundary. Full verification and signed strict-codesign passed as listed above. Final camera commit hash: coordinator to append.

The prior retry build is installed on the phone; the newly signed diagnostics artifact has not been installed. The smoke attempt produced no capability payload because that installed build lacked the added configuration-boundary logging. The phone then locked; a normal relaunch request was denied. The user has been asked to unlock it asynchronously. Device testing is paused until a later session and an unlocked phone. **No physical capture pass has been demonstrated.** Do not claim x422/HEVC Main10 negotiation or Apple Log 2 capture acceptance yet. Resume with one unlocked-phone probe using the new diagnostics artifact; capture the actual format/codec log and recording result. Do not add Pro Video Storage or silently change the Apple Log 2 recording requirement.

Primary camera evidence: `.pi/tmp/x422-capture-rejection-report.md`, `.pi/tmp/x422-diagnostics-verify.log`, `.pi/tmp/x422-diagnostics-device.log`, and `.pi/tmp/x422-diagnostics-codesign.log`.
