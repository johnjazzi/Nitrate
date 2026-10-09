---
id: 3
type: story
title: "Implement color-managed Apple Log to SDR rendering"
parent: epic-render-quality-vertical-slice
covers: [CAP-6, CAP-14]
after: [2]
hitl: false
risk: high
---

# Implement color-managed Apple Log to SDR rendering

## Description

Replaces the arbitrary shader mapping with the versioned decode, 500T transform, and Rec.709 delivery contract from entry 2, including correct movie color properties and isolated stock-transform evidence.

## Acceptance Criteria

Verify: Fixture scopes and tolerant goldens show expected neutrals and highlight roll-off without unexplained clipping, while Photos and metadata inspection agree on SDR Rec.709 delivery.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/epic-render-quality-vertical-slice/epic-render-quality-vertical-slice.md
