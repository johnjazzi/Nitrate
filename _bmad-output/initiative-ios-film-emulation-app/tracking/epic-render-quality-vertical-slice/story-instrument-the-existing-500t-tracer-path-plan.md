---
title: 'Instrument the existing 500T tracer path'
type: 'feature'
ticket: '1'
created: '2026-10-08'
status: 'in-progress'
baseline_revision: '9ebcdad18ea11b9d7db200a116014880901ded0a'
route: 'full'
route_source: 'auto'
risk: 'high'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '_bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/render-quality.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The renderer can produce a movie, but it provides almost no evidence about its input, resources, GPU stages, frame handling, output, or performance. Several frame and GPU failures are silently skipped, so a nominally successful movie cannot yet be trusted as a baseline for color-science work.

**Approach:** Add an opt-in diagnostic run around the existing pixels-unchanged renderer and expose it through the macOS RenderCLI. Each run writes a self-contained review bundle with a JSON manifest, source/output representative frames, metadata, capabilities, timings, resource identities, counters, and stage-specific failures.

## Boundaries & Constraints

**Always:** Preserve the current rendered look and normal app call site; use the same renderer for CLI and iOS; identify every run and resolved LUT/grain/shader resource; make a missing decoded frame, pixel buffer, GPU result, or writer append observable; include OS/device/target identity so macOS results are never confused with phone authority.

**Never:** Correct color management, effect algorithms, grain behavior, writer color tags, bitrate, queue UX, or capture behavior in this story. Never silently replace an Apple Log fixture with an untagged synthetic movie or claim macOS capabilities represent iPhone support.

**Decision:** Keep the Apple Log fixture outside Git. Version a repository descriptor containing its SHA-256, capture provenance, expected metadata, and configurable local lookup path; a missing or mismatched fixture fails clearly.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Diagnostic success | Readable Apple Log movie, valid 500T stock/resources, writable bundle directory | Rendered movie plus JSON manifest and source/output start-middle-end PNGs with requested/actual times | No error expected |
| Invalid input | Missing file or movie with no video track | No successful manifest; diagnostic identifies input/decode stage | CLI exits nonzero with actionable message |
| Resource failure | Missing/invalid LUT, grain volume, or Metal function | Manifest identifies resolved resources up to failure and the failed initialization/load stage | No output is reported successful |
| Frame-stage failure | Decode image, pool allocation, pass 1, pass 2, GPU completion, or append fails | Failure stage and counters are retained; run is unsuccessful | Rendering stops instead of skipping the frame |
| Extraction failure | Movie renders but one representative PNG cannot be extracted/written | Manifest records requested/actual timestamp and extraction failure | Render remains distinguishable from diagnostic-bundle failure |

</frozen-after-approval>

## Code Map

- `App/Modules/ProcessingPipeline/PipelineRenderer.swift` — shared renderer; instrument `render(sourceURL:config:trimRange:)`, resource loading, `processFrames`, `runPass1`, `runPass2`, and finalization. Preserve its existing render API with a diagnostic overload/options result. Replace silent per-frame continues and unchecked appends with stage-attributed outcomes, without changing shader inputs, output settings, dimensions, or preferred-transform handling.
- `App/Modules/ProcessingPipeline/RenderDiagnostics.swift` — new shared Codable model/writer for run identity, environment/Metal capabilities, media metadata, resource provenance, stage timings/counters, errors, and representative-frame records. Keep reporting independent from UI and CLI printing.
- `CLI/CLI.swift` — extend the existing `<input.mov> <stockId> [iso]` tracer with an explicit diagnostic-bundle option; invoke the shared renderer/reporting path, print bundle/output locations, and return nonzero on unsuccessful runs.
- `App/Modules/RenderQueue/RenderQueueViewModel.swift` — existing rendered-only `dumpFrames` is reference behavior; do not expand queue/UI scope. Reuse its AVAssetImageGenerator concept in the shared diagnostic implementation and leave app behavior unchanged, including its source fallback behavior.
- `Shaders/pipeline.metal` and `Shaders/grain.metal` — existing `pass1_lut_halation_glow` and `pass2_grain` bindings are pixel-pipeline contracts; do not change functions, binding indices, or `GrainUniforms` layout.
- `project.yml` — the existing uncommitted RenderCLI target already shares renderer/config sources and resources. Add source/resource/test inclusion only if required by XcodeGen; preserve the target rather than creating another executable.
- `App/Resources/*` and `Resources/*` — duplicated app/CLI LUT, grain, stock, and shader resource trees. Read and hash the resolved resource; do not consolidate or rewrite assets in this story.

## Tasks & Acceptance

**Execution:**
- [ ] `App/Modules/ProcessingPipeline/RenderDiagnostics.swift` — define deterministic Codable diagnostic contracts, environment/Metal capability capture, AVAsset metadata inspection, resource hashing/provenance, representative-frame extraction, and atomic bundle writing.
- [ ] `App/Modules/ProcessingPipeline/PipelineRenderer.swift` — add the opt-in diagnostic lifecycle, timings/counters, resource resolution records, GPU completion inspection, checked frame/appends, and stage-attributed errors while keeping the normal render API and pixel operations unchanged.
- [ ] `CLI/CLI.swift` — add documented diagnostics arguments, run the shared path, print a concise summary, and use reliable exit status.
- [ ] `project.yml` — wire any new shared/test sources needed by both targets without disturbing existing app resources or signing.
- [ ] Diagnostic tests/fixture checks — verify Codable round-trip, atomic manifest/bundle behavior, media metadata, representative timestamps, failure attribution, and successful CLI bundle structure against the approved fixture strategy.

**Acceptance Criteria:**
- Given the approved Apple Log fixture and 500T configuration, when a diagnostic CLI render completes, then one run directory contains the rendered movie, manifest, and source/output start-middle-end PNG records with actual timestamps.
- Given a successful diagnostic run, when its manifest is inspected, then it identifies input/output media properties, OS/target, Metal device/capabilities, resolved resource hashes, stock/ISO, frame counters, elapsed/per-stage timings, and output byte size.
- Given each seeded missing-resource or frame-stage failure, when rendering runs, then it exits unsuccessfully, names the failing stage, and never describes a partial movie as successful.
- Given diagnostics are disabled, when the app renders the same source/configuration, then the public behavior and shader/writer settings remain unchanged.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Design Notes

The diagnostic result should be a value returned by an opt-in renderer entry point, not global logging. Build the manifest throughout the run, then write it atomically even on a controlled failure so evidence survives. Representative frames are diagnostic artifacts rather than part of the rendered media contract; extraction failure must not masquerade as render success or failure.

## Verification

**Commands:**
- Xcode `BuildProject` — expected: the iOS app and RenderCLI compile with the shared diagnostic types.
- `RenderCLI <fixture.mov> <500t-stock-id> <iso> --diagnostics <bundle-directory>` — expected: exit 0 and a complete review bundle matching the manifest.
- RenderCLI seeded invalid-input/resource scenarios — expected: nonzero exits and stage-specific diagnostic records with no successful partial output.
