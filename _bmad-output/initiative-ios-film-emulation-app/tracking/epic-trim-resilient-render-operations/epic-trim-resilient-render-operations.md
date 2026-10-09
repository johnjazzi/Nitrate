---
type: epic
title: "Make trimming and queued rendering resilient"
parent: initiative-ios-film-emulation-app
covers: [CAP-5, CAP-11]
after: [epic-render-quality-vertical-slice]
assignee: ""
risk: high
---

# Make trimming and queued rendering resilient

## Description

Deliver non-destructive trim, persistent exactly-once queue behavior, progress/error UX, and recovery around the accepted renderer.

## Outcome

Users can keep recording while ordered trim-aware renders survive interruptions without corrupting or duplicating work.

## Done when

1. Trimmed A/V duration is correct and the source remains byte-for-byte unchanged.
2. Queue states survive relaunch and process each job once in order.
3. Render trigger, progress, recovery, and completion are understandable in the app.

## Boundaries

Render queue, persistence, trim selection, and operation UX. Rendering internals remain owned by epic 1.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/initiative-ios-film-emulation-app.md
- spec — _bmad-output/initiative-ios-film-emulation-app/spec-ios-film-emulation-app/spec-ios-film-emulation-app.md

## Notes

- Waits on epic-render-quality-vertical-slice because: queue and trim operations require its validated renderer/failure contract.
