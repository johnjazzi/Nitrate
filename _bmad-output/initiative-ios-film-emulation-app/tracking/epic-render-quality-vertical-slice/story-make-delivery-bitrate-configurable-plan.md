---
id: 12
type: story
title: "Make delivery bitrate configurable"
parent: epic-render-quality-vertical-slice
covers: [CAP-14]
after: []
assignee: ""
refined: false
hitl: false
risk: low
---

# Make delivery bitrate configurable

## Description

The delivery bitrate becomes a single user-facing setting instead of a hardcoded constant, so the render and capture paths encode at a chosen target rather than a fixed one.

## Acceptance Criteria

Verify: changing the bitrate setting in the app and in RenderCLI changes the encoded output's bitrate and its recorded metadata, and the render test suite still passes.

## References

- parent — _bmad-output/initiative-ios-film-emulation-app/epic-render-quality-vertical-slice/epic-render-quality-vertical-slice.md

## Notes

- Today there are two fixed bitrate constants, both 60 Mbps: `RenderEncodingContract.averageBitRate = 60_000_000` (App/Modules/FilmStockLibrary/FilmStockConfig.swift:162) and `AVVideoAverageBitRateKey: 60_000_000` (App/Modules/CameraCapture/CameraSession.swift:119, camera capture).
- Open question: should the setting be a single value shared by render and capture, or two independent values?
