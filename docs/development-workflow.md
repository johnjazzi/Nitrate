# Shared Develop workflow

## Scope

Photo import, video import and re-development of retained originals use the same
Develop surface. This change does not change camera capture, camera white-balance
locking, LUT contents or delivery colour contracts. This is the 0.8.0 minor
release candidate on `feat/unified-development`, based on the completed 0.7.1 release.

## Minimal presentation

- Visible labels use at most two words. No explanatory paragraphs on the main screens.
- The still fills the available canvas; no nested vertical scrolling or fixed 210-point thumbnail.
- Stock, gauge, push/pull and primary actions use larger type and 48–80 point touch targets.
- Show compact Estimate/Captured/Rated readouts. Import, preview and render failures show a brief inline reason; full diagnostics and file metadata remain in Details.
- Page position is numeric. Results use three equal-width icons in one horizontal row, with small captions below.
- History uses compact flat rows: a larger aspect-fit thumbnail beside a small status and horizontal Photos/Details/Re-develop actions. Preview and Share live in the row More menu; filters and Storage live in History options. Keep the visible title, short section headings, native pull-down handle and No preview fallback. Thumbnail margins stay neutral, not link-tinted. Preserve readable VoiceOver names and full metadata.
- Keep the camera carousel and top-bar clearance unchanged.

## Interaction contract

1. **Choose files.** Start with Photo and Video entry points. One selected file and
   a batch enter the same workflow; neither starts rendering from the picker.
2. **Load.** Show actual transfer/inspection progress, cancellation and clear file
   refusals. Do not lose accepted queue jobs when a selection is cancelled.
3. **Review.** Show a large aspect-fit preview of the input through the selected
   stock and development settings. Videos use a representative still, not playback.
   Batches can be swiped. Show file position and identity, not an internal working
   filename where better metadata exists.
4. **Adjust.** Offer the same stock, gauge and fixed-stop push/pull controls for
   photos, videos and re-development. Preview stock colour and push/pull only;
   grain, halation, glow and diffusion run during final development, not preview.
   Gauge changes do not reload or regrade the still.
   Settings apply to the staged batch. Rendering takes the settings on screen,
   not a later read of mutable camera preferences.
5. **Develop.** Explicitly submit through the existing durable serial render queue.
   Show actual queued/rendering/saving progress and an animation; do not manufacture
   a percentage or completion before delivery is confirmed.
6. **Results.** Show the actual delivered photo or video poster. Swipe between
   multiple results and tap to enlarge, with zoom and a clear dismissal. Partial
   failure remains visible and retryable without hiding successful outputs.
7. **Three main actions:**
   - **Develop more** returns to the initial Photo/Video choice without modifying
     accepted jobs or already saved Photos items.
   - **Re-develop** loads the retained original(s) back into review/settings,
     without starting another render. Missing originals are explained, never
     replaced with the rendered output or silently skipped as a successful render.
   - **Open Photos** hands off to the Photos app. It must not promise that iOS
     selects specific newly saved assets. Look in Recently Saved when needed.

Queue entry points obey the same contract: single and multiple Re-develop actions
load originals for review, rather than applying whichever settings happen to be
selected in the camera and immediately requeueing them. The first prior recipe
seeds the shared controls; the user can change it before submission.

## Exposure presentation

- Show a **center-weighted file exposure estimate** relative to 18% scene-linear
  luminance, measured before push/pull and the stock LUT in a declared colour basis.
  State that it is an estimate, not a calibrated incident-light reading or EV100.
- Keep recorded capture exposure/ISO/shutter/aperture and any saved meter offset
  separate. Missing metadata is unavailable, not zero and not the current camera
  reading or the chosen stock's default ISO.
- A preview control change does not rewrite the source measurement or original
  capture rating. Automatic push/pull must not silently consume an approximate
  file reading as if it were the captured camera meter.
- A video still is not a full-take exposure analysis. Full export may measure
  highlight protection over more frames than the interactive preview.

## File and render ownership

Use the existing `DevelopVideoModel`, import file leases, RAW decoder, film stages,
queue and receipts. Do not add a second render queue or a separate look approximation.
Use bounded-resolution genuine decoding and the shipped LUT/contrast/push-pull for previews; an embedded
JPEG is not valid input to an Apple Log 2 LUT. Apply orientation and white balance
once, preserve RAW baseline exposure, and cancel or fence stale preview results.
Cache colour resources and decoded inputs; hold only the same original while updating
its colour instead of blanking the image. Picker transfers settle on cancellation
and time out after 120 seconds; preview requests have a 20-second deadline, with retry.
Provider stalls cannot leave the UI spinning indefinitely. These limits are not
evidence that a particular external Photos/iCloud asset has been diagnosed.

Originals are never edited or replaced by previews. Files not accepted by the queue
remain owned by staging leases and must be released on cancellation. A failed queue
acceptance retains the source for retry. Re-development uses queue-owned originals
without an import lease and must not deduplicate into a no-op completed job.

New Develop video originals need scoped durable retention for Re-develop to work
after delivery; do not change legacy camera/import cleanup indiscriminately. Keep
only a bounded delivered still poster for result enlargement instead of retaining
large rendered movies just for a preview. Explicit queue removal/discard must still
clean owned retained files. Existing-job recipes, import flags, capture policy,
photo crop/seed and delivery preferences survive re-development.

## Acceptance checks

- Single photo, single video and multi-file selection reach the same review stage.
- Late transfer/inspection/preview results cannot overwrite a newer selection.
- Cancel/Develop more release unqueued copies, not accepted or queue-owned media.
- Stock/push-pull produce nonblank colour previews; gauge and effect values leave preview pixels unchanged; push/pull changes pixels
  in the expected direction while the source exposure estimate stays stable.
- A spatial gradient survives rendering; colour tests are not claims of calibration.
- Queue submission freezes the shown recipe, rejects duplicate active renders and
  preserves sources on persistence/acceptance failure.
- Single and batch photo/video re-development returns to review before rendering;
  a second explicit Develop actually produces another result, including video.
- Retained Develop video originals and result posters survive reload; legacy
  imported-video privacy/cleanup behaviour remains unchanged.
- Completed output stills support paging and enlargement; mixed failures and absent
  files have explicit recovery paths. Saved labels reflect confirmed save state.
- Native UI respects top-bar clearance, existing D/V/P carousel placement, Dynamic
  Type and VoiceOver. Builds and source-contract tests are not gesture acceptance.
- Full `verify.py verify` and final signed `verify.py device` pass after integration.
  Physical haptics/gesture feel and real footage aesthetics remain owner acceptance.
