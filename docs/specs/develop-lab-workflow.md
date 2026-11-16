# Develop / Lab Workflow

**Status:** implemented; owner-approved phone UI, pending release verification
**Scope:** imported photo/video development workflow and its result presentation
**Native workflow owner:** `DevelopPreview` + `DevelopVideoModel` + `RenderQueueViewModel`
**Approved mockup:** `.hermes/cache/scratch/nitrate-develop-lab-v1.html`

This draft describes the intended Develop/Lab experience while preserving the app's existing import, preview, render, queue, persistence, and delivery semantics.

## Development white balance

- **History** stays at the bottom-left of Lab in every state; the review's narrower **Develop** action stays centered. Opening History uses the existing parent sheet and does not clear the staged recipe.
- History uses a native vertical context menu on long press and inline preview on tap; the former 2×2 action overlay is removed. Photo sharing and source-retention gates remain unchanged; video actions still open Photos, with retained-original Re-develop available through the existing bulk review route.
- Photo/Video chooser faces remain grey with white labels, subtle orange/purple icons and borders; the shared stock/gauge picker has a local grey surface and centered short rows.
- A compact **WB** control sits beside Push/Pull. Its popover contains the current value, a live slider, and **Use stock** / **Use original** reset. Dismissal retains the setting; the slider does not permanently consume review height. Accessibility sizes stack the shared controls.
- RAW starts at **Stock**. A manual override requests 2000–12000 K from the existing RAW decoder, before grading, with zero tint. The exposure meter remains as-shot.
- Video starts at **Original** (exact bypass). A −100…+100 relative warmth control applies a reciprocal-temperature shift of up to ±34 mired around the selected stock's reference, via the shared `plate_prepare` / Bradford adaptation stage in linear Apple Wide Gamut before halation, exposure and LUT. This reference is not measured source capture Kelvin.
- `ContentView` owns the review binding; `DevelopPreviewRecipe` snapshots it for preview invalidation. `DevelopVideoModel` freezes it into `RenderJob.developmentWhiteBalance` through the existing queue. Legacy absent fields resolve to neutral. Retry/reload preserve it; Re-develop restores it; an explicit neutral update resets it, while omitted queue edits preserve it.
- Preview and video export dispatch the same `DevelopWhiteBalanceStage`; RAW preview/export resolve the same decoder temperature. Source leases, originals delivery and receipt poster permissions remain unchanged.
- Applied adjustments are tagged separately as `com.filmemulation.development-photo-kelvin` or `com.filmemulation.development-video-warmth`; receipt extraction preserves those keys. The old `white-balance-kelvin` tag remains the stock recipe value, not capture provenance.
- No tint control or capture WB lock changes in this scope. Automated numerical checks do not constitute visual/colorimetric calibration; phone review remains owner-driven.

## 1. Proposed user flow

1. User enters **Develop** from the camera.
2. User chooses **Photo** or **Video**.
3. User selects one or more assets in the existing Photos picker.
4. The app stages and inspects the selected assets using the existing file-lease workflow.
5. The first selected asset is shown first:
   - a photo shows the first selected photo;
   - a video shows its first available frame, not a frame at one second.
6. The preview opens with the existing **Stock + Print** picker already visible beneath it. The user chooses or changes:
   - film stock from the existing stock-chip row;
   - print gauge from the existing gauge ladder;
   - push/pull from the existing Auto/manual control.
7. The preview updates using the same Develop renderer and recipe that will be queued. The picker is not hidden behind a second tap or a new modal in the primary review state.
8. User taps **Develop** / **Lab** action.
9. The app submits the frozen recipe to the existing render queue.
10. While rendering, the result surface shows the selected contact's black presentation frame and queue state.
11. After rendering, the same single contact remains visible:
    - rendered image centered inside a 100% black frame;
    - metadata printed on the black frame, outside the image area;
    - delivery status and failure state remain available without replacing the contact.
12. From results, user can open Queue, open Photos, develop more, or re-develop retained originals through the existing paths.

The approved visible mode/action name is **Develop**, with **LAB** as the heading. Internal identifiers and native workflow owners are unchanged.

## 2. Current native workflow — research findings

### Entry and parent ownership

`ContentView` owns the camera's Develop mode and creates one `DevelopVideoModel` backed by the shared `RenderQueueViewModel`. The camera hides its live camera layer while Develop is active, but the parent still owns camera chrome, orientation, stock selection, gauge, and push/pull state.

The current Develop panel is `DevelopPreview`:

- chooser state presents Photo and Video `PhotosPicker` controls;
- staged assets are inspected before review;
- review state shows a paged preview for each staged source;
- stock, gauge, and push/pull are live recipe controls;
- the develop action calls `model.develop(...)`;
- results are shown through `DevelopResultsPager`.

Do not create a second import or render state machine in a new Lab view.

### Asset staging

`DevelopVideoModel` stages photos and videos through app-owned leases:

- `stagePhotos(transfers:)` transfers and inspects each selected photo;
- `stageVideos(transfers:)` transfers and inspects each selected video;
- cancellation and generation fences protect against late picker/inspection results;
- leases remain held until the durable queue accepts the source;
- skipped files are retained in the staging error summary.

The ordered source list is:

```swift
bulk.photos.map(Self.source) + bulk.videos.map(Self.source)
```

For a mixed selection, the current model places photos before videos. Do not silently change that ordering while changing the presentation.

### Current source preview

`DevelopSourcePage` renders the active source using `DevelopFramePreviewRenderer` and a `DevelopPreviewRecipe` containing:

- source URL;
- photo/video type;
- crop zoom;
- selected stock;
- selected gauge;
- resolved push/pull.

The current renderer reads the first available video frames through an `AVAssetReader` time range beginning at zero. This is the correct semantic basis for the requested first-frame preview.

There is a separate fallback helper, `DevelopPreviewLoader`, that requests a video image at one second for result/fallback decoding. That is not the desired first-frame rule for the new workflow. The implementation should make the first-frame rule explicit and consistent rather than relying on the one-second fallback.

### Recipe controls

The review state currently exposes:

- stock menu sourced from `stockOptions`;
- `GaugeControl` bound to `gauge`;
- `PushPullControl` bound to automatic/manual state and stops;
- resolved recipe preview;
- exposure estimate, captured offset, and source capture rating where available.

The render action submits the same values shown on screen:

```swift
model.develop(
    stock: stock,
    iso: stock.defaultISO,
    gauge: gauge,
    pushPull: resolvedPushPull,
    whiteBalance: whiteBalance
)
```

The new UI must preserve this contract. Do not introduce a second stock, gauge, ISO, or push/pull owner in Lab.

### Approved review composition

The review surface keeps the source preview and the recipe controls visible together:

1. source thumbnails / pager position;
2. black preview frame with the selected source image;
3. the existing Stock + Print picker, already expanded below the preview;
4. Develop action.

The picker uses the existing `CompactStockPicker` visual and behavioral model, not a simplified replacement:

- stock chips remain visible;
- gauge uses the existing `GaugeControl` ladder and available `PrintGauge` cases;
- push/pull uses the existing `PushPullControl`, including Auto and the manual stops;
- the parent continues to own selection state and persistence;
- changing a value updates the preview recipe without leaving the review state.

The picker may collapse only as a deliberate space/accessibility adaptation. Its default review state is open.

### Queue submission and persistence

`DevelopVideoModel.submit(...)` delegates to `RenderQueueViewModel`:

- existing retained jobs use `redevelopJobs(...)`;
- imported photos use `enqueuePhoto(...)`;
- imported videos use `enqueueImportedVideo(...)`;
- source metadata and development-source retention are stored on `RenderJob`;
- accepted leases transfer ownership to the queue;
- failed or skipped sources remain explainable.

A Lab result view must observe queue jobs and status. It must not enqueue directly, mutate `RenderJob` fields directly, or invent a parallel progress model.

### Current result presentation

`DevelopResultsPager` pages over the accepted job IDs. Each `DevelopResultPage` currently:

- shows a progress overlay for pending/processing jobs;
- decodes the rendered output URL after completion;
- falls back to `receipt.thumbnailJPEG` if the output cannot be decoded;
- shows delivery status;
- exposes retry/details for failed jobs.

The proposed Lab contact should replace the visual container, not these semantics.

## 3. Lab contact presentation

### Black frame requirement

The presentation frame is **100% black**: RGB black / `.black`, not a translucent material, dark gray, or camera-surface color.

The black frame is the print/contact-paper boundary around the image. It must remain black in all states:

- loading;
- rendering;
- completed;
- failed;
- missing output;
- Dynamic Type expansion.

The rendered image is centered inside the frame with a stable inset. Do not crop metadata into the image itself.

### Single-contact composition

Each result page presents one contact at a time, matching the existing `DevelopResultsPager` paging model. Do not turn the result into a grid of final outputs.

Composition:

1. black outer frame fills the result presentation area;
2. rendered image is centered within the frame;
3. metadata is printed on the black border/frame, outside the image bounds;
4. status/progress occupies a reserved area of the frame without changing image geometry;
5. controls sit below or at the edge of the frame, not over the image unless unavoidable.

The result must remain visually recognizable as the same selected contact from review through render completion. The rendered output replaces the preview image; the outer black frame and metadata placement remain stable.

### Metadata on the frame

Metadata belongs on the black frame, not over the image. Minimum fields:

- stock name;
- gauge;
- ISO;
- captured date.

Approved frame-edge arrangement:

- **left border:** stock name, set vertically;
- **right border:** print gauge and ISO, set vertically;
- **bottom-right border:** captured date;
- no metadata is painted over the image;
- use the existing Barlow/monospaced presentation conventions;
- allow truncation or scaling before wrapping into the image area.

The authoritative values are already present in the current model:

- stock: selected render recipe / `stockId` and receipt metadata;
- gauge: `RenderJob.printGauge` / receipt metadata;
- ISO: source capture ISO where available, otherwise selected render ISO according to the existing metadata policy;
- date: `DevelopSource.capturedAt` during review and `RenderReceipt.recordedAt` for completed queue results.

Do not display a stock fallback as if it were source capture ISO. The existing `QueueReceiptMetadataView` distinction between source/capture and selected render values remains authoritative.

### Photo and video media cues

- Photos use the rendered image normally.
- Videos retain the narrow alternating black/white frame-strip cue where the contact needs a media-type indication.
- The strip is a cue only; status remains separately accessible.
- The black outer frame must not be confused with the video strip. The outer frame is always solid black.

## 4. First-frame behavior

The desired rule is **first available frame** for video review.

Implementation requirements:

- use the existing `DevelopFramePreviewRenderer` / `AVAssetReader` path;
- start reading from time zero;
- use the first decoded frame available from the source track;
- apply the existing preferred-track transform;
- do not seek to one second for the review preview;
- do not generate a new video thumbnail solely for the Lab contact.

For completed result contacts, prefer the rendered output image. If a fallback is required, keep the existing receipt thumbnail fallback but document that it is a persisted receipt thumbnail, not a newly extracted source frame.

## 5. Multi-selection behavior

The current app supports selecting multiple photos/videos. Preserve that capability:

- the first selected source is the initial review page;
- the user can page through every staged source before submitting;
- stock/gauge/push-pull changes apply to the active recipe as currently modeled;
- submission queues accepted sources in workflow order;
- results page through accepted job IDs in the same order.

The first-source preview is an initial focus decision, not a restriction to one asset.

## 6. Re-develop behavior

Re-develop must use the current workflow rather than reopening a fresh picker:

1. Queue invokes the existing `onRedevelop(job)` closure.
2. The app calls `DevelopVideoModel.adoptExistingJobs(_:)` for retained originals.
3. The prior stock, gauge, and push/pull are restored where present.
4. The retained source is shown in the same first-frame/photo review surface.
5. The user may change stock, gauge, or push/pull.
6. Submission calls the existing queue re-development path.

`hasRedevelopableSource` remains the gate. Missing, active, discarded, original-only, or empty sources remain unavailable for re-development.

## 7. Delivery and Photos behavior

Do not change existing delivery semantics:

- imported assets do not export duplicate originals to Photos;
- camera originals follow existing delivery preferences;
- output save state is represented by current queue fields;
- Photos opens generally through `PhotosLibraryOpener`;
- the app does not read saved output back from Photos;
- local retained output remains the source for in-app result preview.

The Lab contact may expose Open Photos, but it must call the existing opener and preserve its failure alert.

## 8. Open design decisions

1. Visible label: Develop, Dark room, or Lab.
2. Whether the black frame uses a fixed inset or a format-aware inset for portrait/landscape output.
3. Whether a video frame strip sits on the right edge, top edge, or as a small corner mark inside the black frame.
4. Whether the rendered result keeps a small exposure/status readout below the frame or folds it into the frame metadata.
5. Whether the result surface allows swipe paging while rendering or only after each page becomes available.

These decisions must not change the underlying queue or Develop model.

## 9. Implementation boundaries

Reuse:

- `DevelopPreview` and `DevelopVideoModel` for import/staging/recipe ownership;
- `DevelopFramePreviewRenderer` for first-frame development preview;
- `DevelopResultsPager` / queue job identity for result lifecycle;
- `RenderJob`, `RenderReceipt`, and `QueueReceiptMetadataView` for metadata;
- existing stock, gauge, and push/pull controls;
- existing Photos and local-output preview paths.

Do not:

- add a new import service;
- add a second render queue;
- decode Photos output for display;
- use a one-second source frame for the new review flow;
- place metadata over the image;
- use a gray/material outer frame when the requirement is solid black;
- change processing math, stock identity colors, delivery behavior, or source-retention policy.

## 10. Acceptance criteria

- [ ] Develop opens the existing Photo/Video picker flow.
- [ ] Selected assets are staged through existing leases and inspection.
- [ ] First selected photo or first available video frame is shown first.
- [ ] The existing Stock + Print picker is already open beneath the preview.
- [ ] Stock chips, the existing gauge ladder, and the existing Auto/manual push-pull control are reused.
- [ ] Stock, gauge, and push/pull controls use existing owners and update the preview recipe.
- [ ] Develop submits through `DevelopVideoModel` and `RenderQueueViewModel`.
- [ ] Results preserve one-contact-at-a-time paging.
- [ ] The result presentation has a solid black outer frame in every state.
- [ ] Rendered image is centered inside the black frame.
- [ ] Stock is on the left frame border, gauge + ISO on the right frame border, and date at bottom-right.
- [ ] Progress, failure, retry, delivery state, and local preview behavior remain available.
- [ ] Re-develop restores existing recipe values and retained-source semantics.
- [ ] No new render/import/delivery state machine is introduced.
