---
title: 'Embed exact render settings in exported movies'
type: 'feature'
ticket: ''
created: '2026-10-09'
status: 'built'
baseline_revision: '9ebcdad18ea11b9d7db200a116014880901ded0a'
route: 'oneshot'
route_source: 'auto'
risk: 'low'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Exported movie tags expose stock, integer ISO and halation but omit the full effective configuration. This makes comparisons ambiguous; the newly supplied files actually identify 500T F3513DI at selected render ISO 600 and 250D F3513DI at 4900.

**Approach:** Embed a versioned JSON recipe snapshot plus readable key tags in every exported MOV, preserving existing tags. Include exact effective stock/LUT/ISO/grain/halation/glow values, recipe algorithms and color provenance, codec and bitrate target. Clearly distinguish selected render exposure index from camera capture ISO, and target bitrate from actual encoded bitrate. Test both snapshot values and persistence through real MOV writing/reading. Preserve prior dirty edits, white balance, Apple Log 2/LUT behavior and all pixel transformations; saturation feedback is recorded for later calibration rather than guessed into this metadata patch. Do not fabricate capture white balance/shutter/ISO, verified output gamut or missing historical settings.

Given distinct effective configurations, when metadata is generated and a movie is written, then the tags and JSON retain exact values after reopening the MOV. Given unknown output color interpretation, when the export metadata is inspected, then the unverified flag and interpretation remain explicit. Given legacy metadata keys, when a new movie is exported, then those keys remain readable.

</frozen-after-approval>

## Implementation Notes

Small change in existing shared processing files, under 100 estimated changed lines including meaningful tests; oneshot route. Shared RecipeSnapshot already contains complete FilmStockConfig/effective RenderRecipe and encoder target. PipelineRenderer assigns writer.metadata before startWriting. Add a throwing helper in RenderDiagnostics.swift and use it from PipelineRenderer.swift. Put round-trip MOV test in existing RenderContractTests.swift to avoid regenerating the dirty Xcode project. No pixel or bitrate changes required. User already authorized continuing in dirty tree; preserve index and avoid mixed-work commits.

## Plan Change Log

## Review Triage Log

## Verification

- RenderCLI full test suite with existing derived data and ad-hoc signing: tests pass, including persisted MOV metadata.
- Generic iOS app build with indexing disabled: succeeds.
- git diff --check: passes.

Implementation: RenderMovieMetadata.make validates config and emits existing keys plus LUT, stock name, ISO role, grain/glow, recipe version, codec/bitrate target, provenance flag and schema-1 JSON RecipeSnapshot. Writer errors propagate instead of dropping metadata. Synthetic H.264 MOV test exercises tag persistence for both stocks and exact fractional ISO in JSON; this is not a color fixture. Prior pixel/capture behavior unchanged.

Verification: 10/10 tests passed (0 skipped/failed), generic iOS build exited 0, diff whitespace check passed. Result: `/tmp/film-emulation-contract-build/Logs/Test/Test-RenderCLI-2026.10.09_08-47-34--0400.xcresult`. Review found no metadata regressions; two pre-existing capture UI issues deferred. No staging/commit performed to preserve mixed dirty work.

Review triage: medium/defer — ContentView currentDeviceISO defaults to 400 and only updates at AE lock, so auto/unlock/switch readouts are stale; verified all assignments. Medium/defer — lockCurrentExposure sets autoExpose and UI immediately reads ISO/labels locked, so it can remeter before locking; verified helper and caller. Neither capture file is touched by this metadata change.
