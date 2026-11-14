# Contact-sheet History

**Status:** design / implementation handoff
**Scope:** compact History surface layered over the Minimal camera UI
**Primary reference:** `.hermes/cache/scratch/nitrate-minimal-ui-v7.html`
**Native owners:** `QueueSheetView`, `QueueReceiptCard`, `RenderQueueViewModel`, `RenderJob`

This document specifies the compact contact-sheet history surface only. It does not authorize replacing the existing Develop workflow, queue persistence, rendering, Photos delivery, or metadata model.

## Approved interaction decisions

- Use one shared History component in compact and full native sheet states, as with the stock/gauge selector. Expansion shows more rows of the same contact sheet plus full queue details; it does not add a large selected-receipt preview above the grid.
- Compact mode shows a small active-work strip. Expanded mode exposes existing processing, queued, awaiting-stock, retry, stock-assignment, and access/persistence controls.
- Tap opens the 2×2 actions panel. Hold and the Preview action use the same local preview: the actual retained photo, or the first frame of the retained rendered video. Do not autoplay video.
- Keep persisted receipt thumbnails as the grid posters. Reading the local video's first frame occurs only when its preview is opened; it is not a second thumbnail store or a replacement receipt pipeline. No Photos read-back.
- Hidden receipts use the same action tile changing from Hide to Show. Restoring visibility changes no queue job or media state.
- Apply the same History component to Minimal and Classic, respecting the existing shared appearance environment. Do not rename Develop, Dark room, or Lab in this PR.

These explicit choices supersede the tentative gesture and full-video-playback alternatives below. Native media ownership and availability checks remain authoritative.

## 1. Goal

Replace the current conventional History list/grid presentation with a compact, camera-native contact sheet that opens over the Minimal camera UI.

The surface should feel like a quiet layer over the camera, not a separate records-management screen:

- low chrome;
- compact geometry;
- Barlow typography and Minimal palette;
- queue thumbnails doing most of the visual work;
- controls represented by icons and wells;
- no duplicate status text or storage copy in the compact surface.

The existing queue remains the source of truth. The contact sheet is a presentation and interaction layer over `RenderQueueViewModel.jobs`.

## 2. Entry and placement

### Camera entry

- The camera keeps one large queue/history icon in its existing queue control position.
- Tapping it presents the History surface using the existing queue-sheet presentation path.
- Do not add a second textual `QUEUE` label.
- Do not show `FREE SPACE` in the camera or contact-sheet header. Capacity remains owned by the camera's existing bounded readout.

### Surface placement

- Present the compact History surface as a bottom sheet or in-camera overlay over the Minimal camera composition.
- Initial presentation is compact, approximately one-third of the screen height, with a visible drag indicator.
- The camera remains the visual parent; the sheet must not become a separate desktop-like page.
- Preserve the current large expansion path for users who need full queue details.

## 3. Header

The compact header contains:

- `HISTORY` label on the left;
- an icon-only visible/hidden history toggle;
- a Photos action on the right.

The toggle and Photos action sit beside each other in the same header row. Do not put the history toggle on a separate row.

### Photos action

- Use the existing `openPhotos` closure and `PhotosLibraryOpener.open()` path.
- Use the existing accessibility identifier `QueueReceiptPresentation.photosActionID + ".general"` where applicable.
- The action opens Photos generally; it does not promise to locate a specific saved video.
- Preserve the current failure alert behavior (`photosOpenFailed` and `PhotosLibraryOpener.failureMessage`).
- Icon-first presentation is preferred; a short `PHOTOS` caption may remain if it fits the Minimal header without becoming a conventional button bar.

### History visibility toggle

Use one toggle, not two tab buttons:

- on state: eye icon, showing normal visible history;
- off state: eye-slash icon, showing items hidden by the user;
- expose `aria`/VoiceOver state as “Show visible history” / “Show hidden history” or equivalent;
- the icon state must not be the only accessibility cue;
- the toggle changes the presentation filter only. It never deletes jobs, originals, thumbnails, render outputs, or Photos records.

Hidden history is presentation state and must persist across sheet dismissal and app relaunch. Persist hidden IDs in the app's queue-owned persistence or a clearly scoped companion store. Do not use view-local `@State` as the final persistence mechanism.

## 4. Contact-sheet layout

### Grid

- Minimum three columns on supported phone widths.
- Use a normalized 4:3 poster cell for every receipt.
- Keep gutters tight and consistent with Minimal camera spacing.
- All history is shown by default, except IDs explicitly hidden by the user.
- Do not split the default view into `Latest` and `Earlier` sections unless the grouping is visually necessary; the contact sheet should read as one history surface.
- Newest-first display order is acceptable for presentation, but do not change the queue's FIFO/render order.

### Receipt cell

Each cell contains:

1. queue thumbnail/poster;
2. small index or status mark if needed;
3. one compact metadata line below the image;
4. a narrow video frame-strip treatment for video jobs.

The thumbnail must use the persisted `RenderReceipt.thumbnailJPEG` when available. `QueueReceiptViews.poster` already follows this rule and should be reused rather than creating another thumbnail pipeline.

For missing or unavailable media:

- retain the cell in history;
- show the existing neutral “No preview” treatment;
- preserve status and metadata access;
- do not fabricate a frame from Photos or re-read a deleted output.

### Video indicator

Video cells use a narrow alternating black/white frame-strip edge, matching the existing `FrameStripBorder` direction in `QueueReceiptViews.swift`.

- It is a media-type cue, not a success/failure cue.
- Keep semantic status separate from the strip.
- Do not rely on the strip alone for VoiceOver.

### Metadata outside the image

Receipt metadata stays outside the poster frame. At minimum the compact line should be able to show:

- receipt title / stock name;
- ISO or media type when space allows;
- recorded date/time or a compact date.

The full metadata surface remains `QueueReceiptMetadataView`. Its existing fields are authoritative, including stock, selected render ISO, print gauge, push/pull, recipe version, delivery status, recorded timestamp, codec, resolution, frame rate, file size, color space, and cleanup state.

## 5. Receipt interaction

### Tap

Tapping a receipt opens an icon-led controls modal. The modal is a compact 2×2 grid of wells:

| Position | Action | Existing native path |
|---|---|---|
| top-left | Re-develop | `onRedevelop(job)` / shared Develop workflow |
| top-right | Metadata | `metadataJob = job` → `QueueReceiptMetadataView(job:)` |
| bottom-left | Preview | existing local preview path (`playbackJob`) |
| bottom-right | Hide | presentation-only hidden-ID update |

Use SF Symbols or the app's established icon language. Avoid conventional full-width text buttons. Short captions may sit under icons for clarity, but the icon and well are the primary affordance.

Close is a small corner `xmark`, not a fifth grid tile.

The modal must:

- identify the selected receipt;
- preserve the queue sheet behind it;
- avoid changing queue status merely by opening it;
- maintain at least 44pt effective hit targets;
- dismiss without losing the selected receipt or changing its render recipe.

### Long press / preview shortcut

A long press may open the receipt preview directly, subject to the final gesture decision. If retained:

- use the persisted queue thumbnail for the compact preview surface;
- do not extract a new video frame just for this interaction;
- keep the existing full preview behavior available through the Preview action.

The current native full preview behavior is authoritative:

- photos use `PhotoPreviewSheet` with the retained local rendered output;
- videos use `VideoPreviewSheet` with the retained local rendered output;
- the app only opens Photos generally through `PhotosLibraryOpener`; it does not read saved media back from Photos.

The queue-thumbnail preview is a compact visual preview, not a replacement for the native rendered-output playback path.

### Hide

Hide removes the receipt from the normal contact-sheet presentation and persists its ID as hidden.

Hide must not:

- call `RenderQueueViewModel.remove`;
- delete the original;
- delete the retained output;
- alter `RenderJob.status`;
- remove the item from the full queue/history data source;
- change Photos delivery state.

When the eye toggle is switched to hidden-history mode, hidden receipts become visible and can be restored. The restore action may be the same Hide tile changing to Show, or a matching context action; specify and test the final choice before implementation.

## 6. Existing queue behavior to preserve

`QueueSheetView` currently owns these behaviors and they remain authoritative:

- `viewModel.outstandingJobs` for awaiting-stock, processing, and pending work;
- `viewModel.historyJobs` for persisted history;
- `viewModel.currentSessionResults` for the current-session filter;
- `latestRender` presentation handling;
- stock assignment for `.awaitingStock` jobs;
- retry for failed jobs;
- queue persistence and recovery;
- access-paused rendering notices;
- Photos open failure handling;
- metadata, preview, and sharing sheets.

The contact sheet should reuse `QueueReceiptCard` and its existing closures rather than creating a second receipt model. Extend `QueueReceiptCard` only where the compact presentation needs a different layout or action surface.

Current source locations:

- `App/Modules/RenderQueue/QueueSheetView.swift`
- `App/Modules/RenderQueue/QueueReceiptViews.swift`
- `App/Modules/RenderQueue/QueueReceiptPresentation.swift`
- `App/Modules/RenderQueue/RenderQueueViewModel.swift`
- `App/Modules/RenderQueue/RenderJob.swift`
- `App/Modules/RenderQueue/RenderReceipt.swift`
- `App/Modules/RenderQueue/RenderReceiptService.swift`

## 7. Develop workflow: current native behavior to reference, not replace

The contact sheet must hand off to the existing Develop workflow. Do not invent a second Develop state machine inside the queue sheet.

### Existing Develop entry points

`QueueSheetView` already supplies:

- `onRedevelop: (RenderJob) -> Void` for one finished job;
- `onBulkRedevelop: (Set<UUID>) -> Void` for multi-selection;
- `canReviewOriginal(_:)`, which requires a retained, non-empty source and a completed or failed job;
- `QueueReceiptCard.redevelopmentAction`, currently backed by `arrow.counterclockwise`.

The compact Re-develop tile should invoke the same `onRedevelop(job)` closure.

### Existing Develop stages

`DevelopPreview` and `DevelopVideoModel` define the current workflow:

1. **Chooser** — select video or photo through `PhotosPicker`.
2. **Loading/staging** — transfer into an app-owned lease, inspect the file, and retain the lease until the queue accepts it.
3. **Review** — show the source preview; choose stock; adjust print gauge and push/pull; preview the current recipe.
4. **Develop** — submit the selected source and frozen recipe to `RenderQueueViewModel`.
5. **Rendering/results** — show queued/rendering/result states; open Queue when needed.
6. **Re-develop** — adopt retained queue originals back into review, restore prior stock/gauge/push-pull where available, then submit a new render.

The current review UI already displays metadata outside the preview frame through `DevelopContactMetadata`:

- stock;
- gauge;
- source ISO;
- captured date.

That existing component is the reference for any future Develop visual refinement. Do not duplicate or reinterpret those values in the contact sheet.

### Re-development semantics

`DevelopVideoModel.adoptExistingJobs(_:)` is the current handoff for retained originals. It rejects jobs that are still active, original-only, discarded, or missing their source. For an accepted job it carries forward:

- source URL and original filename;
- source capture ISO;
- recorded/captured date;
- captured offset/push-pull information;
- photo crop zoom where applicable.

`DevelopPreview.redevelop()` restores the prior stock, print gauge, and push/pull recipe when available, then stages the retained originals for review. The contact sheet must call this path rather than directly mutating `RenderJob` or enqueueing a replacement job.

### Imported versus camera media

Preserve the current distinctions in `RenderJob` and `DevelopVideoModel`:

- imported photo/video sources are already owned by the operator and must not be duplicated into Photos as “original” delivery;
- camera originals may follow the existing delivery preferences;
- `retainsDevelopmentSource` controls whether the original remains available for later re-development;
- `hasRedevelopableSource` checks that the source file still exists and is non-empty.

### Develop naming

The visible name remains unresolved between **Develop**, **Dark room**, and **Lab**. This contact-sheet spec uses **Re-develop** for the action because that matches the existing native API and current user direction. Do not rename internal identifiers or existing accessibility IDs as part of the contact-sheet implementation.

## 8. State and persistence requirements

Persist only presentation state introduced by this feature:

- hidden receipt IDs;
- optionally the last compact/full History presentation preference if product approval adds one.

Do not persist:

- a duplicate copy of `RenderJob`;
- a second thumbnail store;
- a second Photos-delivery flag;
- modal selection as queue state;
- temporary gesture state.

Hidden IDs must be reconciled when jobs are permanently removed or invalidated. A stale hidden ID must not affect newly created jobs, even if UUID collision is theoretically impossible; cleanup keeps the store bounded.

## 9. Accessibility and interaction

- Every receipt has an accessible label based on `job.receiptTitle` and its recorded/created date.
- Video/photo type, status, hidden state, and action availability are spoken.
- Icon-only controls have explicit labels and hints.
- The eye toggle announces its current mode and action.
- Photos announces that it opens Photos generally.
- Re-develop announces that it returns a retained original to Develop.
- Metadata announces the receipt title.
- Preview distinguishes local rendered preview from Photos.
- Hide announces that the receipt will be removed from the visible history presentation but retained in the queue.
- Effective tap targets remain at least 44pt even when visual icons are smaller.

## 10. Acceptance criteria

### Visual

- [ ] History opens over the Minimal camera UI rather than as a separate desktop-style page.
- [ ] Compact surface has at least three columns on supported phone widths.
- [ ] All non-hidden history is visible by default.
- [ ] Photos and the eye toggle occupy the same header row, side by side.
- [ ] Video cells have the narrow alternating frame-strip cue.
- [ ] Metadata is outside the poster frame.
- [ ] Controls modal is icon-led and arranged as a square 2×2 grid.
- [ ] Re-develop, Metadata, Preview, and Hide are present and visually distinct.

### Behavior

- [ ] Tap opens the controls modal for the selected receipt.
- [ ] Re-develop calls the existing `onRedevelop(job)` path.
- [ ] Metadata presents `QueueReceiptMetadataView` for the same job.
- [ ] Preview preserves the existing local rendered-output preview behavior.
- [ ] Hide removes only the selected receipt from the visible presentation.
- [ ] Hidden IDs persist across sheet dismissal and relaunch.
- [ ] The eye toggle reveals hidden receipts and supports restoration.
- [ ] Photos calls the existing general Photos opener and preserves its failure alert.
- [ ] Queue status, render recipes, originals, outputs, and Photos state are unchanged by presentation actions.

### Verification

- Add focused presentation/state tests for three-column layout policy, hidden-ID persistence/reveal, action routing, and video strip presence.
- Preserve existing queue, metadata, preview, Photos, and Develop tests.
- Run `git diff --check`, `python3 scripts/verify.py lint`, focused tests, and the normal project verification cadence before handoff.
- Do not claim Develop behavior is implemented unless the existing native Develop workflow is exercised through `DevelopVideoModel` and `DevelopPreview`.

## 11. Explicit non-goals

- No new renderer or thumbnail extractor.
- No replacement of `DevelopVideoModel`.
- No new queue persistence format for jobs.
- No Photos-library read-back.
- No change to capture, stock, gauge, push/pull, delivery, or subscription semantics.
- No final decision on the visible Develop/Dark room/Lab label.
