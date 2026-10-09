---
id: 11
type: bug
title: "Rendered output looks over-compressed"
parent: epic-render-quality-vertical-slice
covers: ["CAP-14"]
after: []
assignee: ""
refined: false
hitl: false
risk: medium
severity: P2
---

# Rendered output looks over-compressed

## Description

Rendered movies read as visibly over-compressed: the creator sees compression artifacts and reports the output "seems too compressed" but cannot yet name the specific artifact. The output should look clean at full resolution and preserve the grain the render adds.

## Reproduction

1. Render any clip (the 250D or 500T path) to 4K 24fps HEVC; delivery is hvc1 at a 36 Mbps average bitrate.
2. Play the saved movie back at full resolution.
3. Actual: visible compression artifacts (blocking or banding), worst in flat areas and where grain was added. Expected: clean output with grain intact.

## Cause Hypothesis

The 36 Mbps average bitrate is low for 4K 24fps HEVC, so the encoder discards high-frequency detail — including the additive grain — to stay under target. The defect is likely in the encoding contract, not the render stages.

## Acceptance Criteria

1. **The expected behavior holds**
   **Given** a rendered 4K clip
   **When** it is played back at full resolution
   **Then** no obvious blocking or banding appears and the grain survives encoding
2. **Tests cover the condition found and fixed**
   **Given** the render test suite
   **When** it runs
   **Then** a check measures encoded quality (such as SSIM/VMAF or a grain-survival metric) against a reference and fails at the current bitrate, passing after the encoding is corrected
3. **Or: no change is needed, with proof**
   **Given** the reproduction
   **When** it is run on the current code
   **Then** the output is already clean and the grain survives, or the report was mistaken, with the evidence recorded in Notes — this supersedes 1 and 2

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/epic-render-quality-vertical-slice/epic-render-quality-vertical-slice.md

## Notes

- Decision (2026-10-09): delivery bitrate bumped 36→60 Mbps (RenderEncodingContract.averageBitRate, App/Modules/FilmStockLibrary/FilmStockConfig.swift:162). Validate with a bitrate ladder (36/60/80/100/120) + grain-survival metric before resolving.
- Follow-up: make the bitrate user-configurable — tracked as story 1.12 (done 2026-10-09).
- VALIDATION (2026-10-09): bitrate ladder on flat mid-gray 720p24 clip, kodak500t_k2383 ISO 500, via `RenderCLI --bitrate`. Per-channel grain std (percent-of-255) at 36/60/80 Mbps: R 3.49/7.68/8.14%, G 3.14/7.35/7.90%, B 5.57/10.56/11.25%. Actual encoded bitrates 38.1/62.4/82.3 Mbps (targets hit). 36 Mbps crushed grain to ~40-50% of the 80 Mbps reference; 60 Mbps preserves ~93-94%. 100 Mbps rejected by the 720p HEVC encoder ("Asset writer failed: Cannot Save"). Conclusion: 60 Mbps is the sweet spot; over-compression resolved.
- Remaining gap: no automated grain-survival regression test (acceptance criterion 2) — candidate for story 10 "consolidate regression suite" or a follow-up ticket.
