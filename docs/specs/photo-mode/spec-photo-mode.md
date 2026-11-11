---
id: SPEC-photo-mode
status: implementation-feasibility-gates
created: 2026-10-25
companions:
  - capture-and-processing.md
  - delivery-and-validation.md
  - implementation-plan.md
sources: []
---

# Nitrate Photo mode

**Scope accepted; implementation starts with P0/P1 capture and color feasibility.** Those technical gates must pass before broad UI, queue or delivery work. Continue the accepted scope after they pass; publication and release still require explicit approval. The owner accepted the scope and explicitly approved the 12 MP budget and 5207/5219 looks. This file and its three companions define the build contract. Output codec remains a proposal while JPEG versus HEIF is discussed; hardware/color feasibility is unverified. The append-only `.memlog.md` records decisions. See `implementation-plan.md` for the stage-by-stage LUT transform, proposed files, dependencies and tests.

## Why

Bring Nitrate's pick-a-stock-and-shoot experience to still photography. Capture minimally processed sensor data, apply a reproducible film recipe, and deliver the finished photograph to Photos without adding an editor or a local photo library. The original product brief included photos, but the shipped video path does not implement them.

## Capabilities

- **CAP-1 — Enter Photo mode**
  - **intent:** Select Photo from the existing D–V–P shooting-mode vocabulary.
  - **success:** After release gating is enabled, P selects Photo with the selected item centered and its lowercase `photo` title visible. Entry commits only after configuration succeeds; failure leaves the previous working mode selected. Recording/finalizing blocks mode changes.
- **CAP-2 — Capture a RAW still**
  - **intent:** Capture one Bayer RAW photograph using supported hardware and current shooting controls.
  - **success:** A shutter request produces a readable app-owned DNG with actual dimensions, orientation and exposure recorded. Unsupported lenses cannot accept a capture. Capture feedback is immediate, while durable acceptance is reported separately.
- **CAP-3 — Choose a film look before shooting**
  - **intent:** Choose a compatible stock and print gauge, then shoot without post-capture decisions.
  - **success:** Each accepted shot snapshots the full recipe and gauge. Later picker changes cannot change it. An unset or unsupported stock disables capture and offers stock selection. Shooting preview stays neutral.
- **CAP-4 — Develop the still**
  - **intent:** Receive a color-managed film rendering with spatial halation, glow and still grain.
  - **success:** A real DNG renders through the declared RAW-to-working-space transform and a compatible stock into a readable, correctly tagged JPEG. Retry uses the same recipe and grain seed. Color and visual acceptance require the device checks in the validation companion.
- **CAP-5 — Deliver to Photos**
  - **intent:** Automatically receive the rendered photo and, optionally, the original RAW file.
  - **success:** Save only the JPEG by default. With the independent Photo original-save setting enabled, save JPEG and DNG as separate assets. Confirm each save only after Photos reports success; request add-only access, never library read access.
- **CAP-6 — Recover unfinished work**
  - **intent:** Recover a shot after rendering, persistence, permission or delivery failure.
  - **success:** A persisted Photo job or unacknowledged capture journal makes the original discoverable after relaunch. Retry preserves immutable inputs and confirmed saves. No undelivered original is automatically removed.
- **CAP-7 — Continue shooting safely**
  - **intent:** Take subsequent photos while prior accepted photos wait for processing.
  - **success:** Allow only one sensor capture transaction at once. Once its DNG and job are durable, permit the next shot subject to storage/backpressure. Photo and video renders never execute concurrently on the shared processing budget.
- **CAP-8 — Preserve Video and Develop**
  - **intent:** Switch back without changing the established video or import contract.
  - **success:** Video restores its valid Log 2 format, exposure/frame-rate policy, stock and controls. Develop still accepts only supported Apple Log 2 video. Old queue JSON loads unchanged; photo failures cannot strand video jobs.

## Constraints

- Preserve neutral shooting preview. Do not show the applied look or an automatic captured-photo review inside Nitrate; view delivered results in Photos. Existing bundled stock sample art is allowed.
- Preserve add-only Photos permission. No asset enumeration, album management, exact-asset lookup or read access for thumbnails.
- Preserve the permanent exclusion of editors, post-capture adjustment tools, trimming, timelines and projects.
- Still capture has a separate capability, exposure and color contract. Do not pass a DNG through movie validation or label decoded linear RGB as Apple Log 2 without an actual transform.
- Do not change video white-balance locking, RGB/red-fastest LUT upload, movie metadata or fixed film-shutter behavior as incidental Photo work.
- Preserve accepted media until its requested deliveries and terminal state are durable. Completed history retains only compact metadata and a small local thumbnail, not full-resolution files.
- Keep Photo hidden in production until capture, color, delivery, recovery and Video/Develop regression gates pass. No model-name support promises; determine capability per active device/format/output.

## Non-goals

- Photo import or expanding Develop to accept stills, camera-roll browsing, batch processing, ProRAW, processed-only fallback, bursts, Live Photos, flash, HDR delivery or depth effects in the first slice.
- Post-capture stock swapping, white balance/exposure sliders, crop/reframe tools, side-by-side previews or a clean-capture lab.
- Delivering the old Portra/Gold/Cinestill/B&W wish list as part of the first slice. Those names in old planning files do not constitute assets or calibrated recipes.
- Expanding the app's minimum OS or supported-device range solely through Photo mode.

## Success signal

On an eligible physical phone, select Photo, pick a stock, take repeated portrait and landscape shots, and see film-rendered JPEGs in Photos. Confirm optional RAW delivery, recovery after failed saves/relaunch, bounded resources, and successful return to both Video and Develop. No implementation or performance claim is established by this spec review.

## Defaults and review decisions

The scope and 12 MP / stock decisions are accepted. JPEG remains a compatibility-first proposal, not a requirement imposed by Photos. Implementation and physical-device gates are still pending:

| Decision | Proposed first slice |
|---|---|
| Capture | Bayer RAW only; unavailable cameras are explained, never silently converted to ProRAW/JPEG capture. |
| Resolution and framing | Approved 12 MP-class budget; proposed concrete cap 12,192,768 pixels (includes 4032×3024), subject to actual Bayer capability. Use native still aspect, no aspect picker or extra crop beyond the selected supported zoom. Preserve the whole usable RAW extent. |
| Exposure | Keep the existing ISO presentation, range, Float/Lock behavior unchanged. Add a Photo-only shutter ruler (placement remains a proposal) with independent Float/Lock state. Each control spans the active RAW format’s full supported minimum-to-maximum duration/ISO range; do not impose arbitrary endpoints or a video-FPS ceiling. Start Photo in Auto; pins remain Photo-session-only. |
| Output | Proposed SDR JPEG, embedded sRGB profile, encoder quality 0.95. Photos also supports HEIF; no codec change is implied by that support. No HDR or untagged output. |
| Originals | Independent `Save original RAW` preference, default Off. Recoverability does not depend on this preference. |
| Stocks | Approved 5207 and 5219 looks; create still-specific recipe variants only after the RAW-to-Apple-Wide-Gamut/Log 2 bridge and both looks pass acceptance. No claim of still color equivalence from existing video LUTs alone. |
| Workflow | Stock selected before capture; automatic processing and delivery, no confirmation/editor screen. Remember Photo stock and gauge separately from Video. |
| Scheduling | One sensor request in flight; serial shared GPU scheduling; persisted photo queue with its own schema. |
| Unsupported Photo entry | Leave P visible but disabled with an accessible explanation once the feature is released; keep Video/Develop usable. Hide P entirely before release gating. |

## Open questions

1. Retain proposed compatibility-first JPEG/sRGB; no codec switch is authorized. The approved 12 MP budget and 5207/5219 looks are not open questions.
2. The actual Bayer format/resolution/lens matrix and decoder behavior need physical-device evidence. Failure of those gates requires a revised proposal, not an undocumented fallback.

All other implementation acceptance criteria are defined in the companions. These review questions do not authorize coding or publication.
