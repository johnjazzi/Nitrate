# Tracking Index — iOS Film Emulation App

Single entry point for the ticket tree. Every epic, its stories, and the
supporting contracts are linked from here.

- Initiative: [initiative-ios-film-emulation-app](initiative-ios-film-emulation-app.md)
- Epic store: [tickets.toml](tickets.toml) (epic-level declarations)
- Backlog triage: [deferred-work.md](deferred-work.md)
- Last session: [session-log-2026-10-09.md](session-log-2026-10-09.md)

## How the tree is laid out

Each epic is a folder under `tracking/`. A folder holds:

- `tickets.toml` — the ordered `[[entry]]` list of its stories and bugs.
- `<type>-<slug>.md` — the leaf file for a ticket (frontmatter ties it to an id).
- `<type>-<slug>-plan.md` — the build plan for a ticket.

Epic-level dependencies are declared in [tickets.toml](tickets.toml). A ticket
whose `after` names an unfinished ticket stays blocked.

Query the tree with:

```bash
python3 _bmad/method/scripts/tickets.py --project-root . status <epic-folder>
python3 _bmad/method/scripts/tickets.py --project-root . find <epic-folder> <ref>
```

## Epics

1. [Accept the 500T render-quality vertical slice](tracking/epic-render-quality-vertical-slice/epic-render-quality-vertical-slice.md)
   — covers CAP-6, CAP-7, CAP-14, CAP-15. No prerequisite.
2. [Make Apple Log capture trustworthy across supported iPhones](tracking/epic-trustworthy-camera-capture/epic-trustworthy-camera-capture.md)
   — covers CAP-2, CAP-3, CAP-12, CAP-13. No prerequisite.
3. [Make trimming and queued rendering resilient](tracking/epic-trim-resilient-render-operations/epic-trim-resilient-render-operations.md)
   — covers CAP-5, CAP-11. Waits on epic 1.
4. [Add and accept the 250D stock](tracking/epic-250d-stock-calibration/epic-250d-stock-calibration.md)
   — covers CAP-6, CAP-7, CAP-14. Waits on epic 1.
5. [Unlock and ship the complete v1](tracking/epic-purchase-release-readiness/epic-purchase-release-readiness.md)
   — covers CAP-9. Waits on epics 2, 3 and 4.

Epics 1 and 2 are independent and can proceed in parallel. Epic 5 is last
because commerce unlocks the finished product rather than a feature subset.

## Epic 1 — the only epic broken into tickets

This is the active epic. The state shown for each ticket is the `state` field
from `tickets.py`, which resolves to `planned` when a ticket has neither a leaf
file nor a plan. (The raw `status` field is empty for those.) Current counts:
1 in-progress, 2 in review (`built`), 3 done, 6 planned.

Build order:

1. **Instrument the existing 500T tracer path** — `in-progress`. No
   prerequisite. [plan](tracking/epic-render-quality-vertical-slice/story-instrument-the-existing-500t-tracer-path-plan.md)
2. **Version the 500T transform and effect contract** — `review`. After 1.
   Plan records `status: built`, which the tracker resolves to a review state.
   [plan](tracking/epic-render-quality-vertical-slice/story-version-the-500t-transform-and-effect-contract-plan.md)
3. **Implement color-managed Apple Log to SDR rendering** — `done`. After 2.
   [story](tracking/epic-render-quality-vertical-slice/story-implement-color-managed-apple-log-to-sdr-rendering.md)
   · [plan](tracking/epic-render-quality-vertical-slice/story-implement-color-managed-apple-log-to-sdr-rendering-plan.md)
4. **Implement spatial halation and highlight glow** — `review`. After 3.
   Plan records `status: built`, which the tracker resolves to a review state.
   [plan](tracking/epic-render-quality-vertical-slice/story-implement-spatial-halation-and-highlight-glow-plan.md)
5. **Add versioned per-shot exposure-index selection** — `planned`. After 4.
6. **Implement temporally stable 500T grain** — `planned`. After 5.
7. **Harden movie writing and render failure semantics** — `planned`. After 6.
8. **Run the iPhone 18 render-quality checkpoint** — `planned`. After 7.
9. **Refactor the accepted render slice** — `planned`. After 1–8.
10. **Consolidate the render regression suite** — `planned`. After 9.
11. **Rendered output looks over-compressed** — `done`. No prerequisite. Bug.
    [bug](tracking/epic-render-quality-vertical-slice/bug-rendered-output-looks-over-compressed.md)
    · [plan](tracking/epic-render-quality-vertical-slice/bug-rendered-output-looks-over-compressed-plan.md)
12. **Make delivery bitrate configurable** — `done`. No prerequisite.
    [story](tracking/epic-render-quality-vertical-slice/story-make-delivery-bitrate-configurable-plan.md)

Longest remaining chain: 4 → 5 → 6 → 7 → 8 → 9 → 10.

Ticket 1 carries an open `unknown`: the repository has no redistributable
Apple Log fixture, so a fixture must be created or recorded without treating a
device-only capture as an automated golden.

## Epics 2–5 have no tickets yet

Their epic files exist and are linked above, but their folders hold no
`tickets.toml`, so `tickets.py` reports zero tickets for each. They need
slicing into stories before work starts. Epic 2 is unblocked, so it is the one
that can be broken down without waiting.

## Supporting contracts

- Spec: [spec-ios-film-emulation-app](spec-ios-film-emulation-app/spec-ios-film-emulation-app.md)
- Render quality: [render-quality.md](spec-ios-film-emulation-app/render-quality.md)
- Film stocks: [film-stocks.md](spec-ios-film-emulation-app/film-stocks.md)
- Architecture: [architecture-ios-film-emulation-app](architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md)
- Brief: [brief-ios-film-emulation-app](brief-ios-film-emulation-app/brief-ios-film-emulation-app.md)
- UX design: [DESIGN.md](ux-ios-film-emulation-app/DESIGN.md)
- UX behavior: [EXPERIENCE.md](ux-ios-film-emulation-app/EXPERIENCE.md)
- UX review rubric: [review-rubric.md](ux-ios-film-emulation-app/review-rubric.md)
- Plan (render settings in movies): [plan-embed-render-settings-in-movies.md](plan-embed-render-settings-in-movies.md)

## Known issue in the tree

`tickets.py` reports one problem at initiative level:

```text
plan-embed-render-settings-in-movies.md: ticket '' names no entry or leaf
file in initiative-ios-film-emulation-app; skipped
```

That plan's frontmatter has an empty `ticket`, so it joins nothing and is
skipped. It is linked above as a standalone plan. Giving it a `ticket` value
would attach it to a real ticket.
