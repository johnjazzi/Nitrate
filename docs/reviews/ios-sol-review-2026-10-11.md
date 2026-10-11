# iOS integration review

Baseline: `14b2a9031772bbf457215580b0103111662d4f09`, /tmp/nitrate-camera-render-integration. Read-only review of the supplied main...HEAD diff and surrounding current implementations. No source edits, builds, tests, installs, or device-data extraction performed.

No release-blocking failure was demonstrated on a device. The important findings below are confirmed by code paths or an explicit API contract; their physical-device frequency is not measured. Camera findings can predate this integration and remain in the authorized broader review scope.

## Important findings

### I1 — Persisted camera jobs point to purgeable originals

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:309; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:319; /tmp/nitrate-camera-render-integration/App/Modules/RenderQueue/RenderQueueViewModel.swift:63.

**Trigger/consequence:** Record a clip, leave it pending/processing or failed without successful Photos delivery, terminate the app, and let iOS purge its temporary directory. Relaunch recovery retains the job but has lost the only original. Rendering and raw fallback then both fail. “Source remains in the app” at the time of a failure does not mean the source is retained across launches.

**Trace:** Recording writes directly to FileManager.temporaryDirectory. The delegate URL becomes lastRecordedURL and then RenderJob.sourceURL without relocation. JSON persists the URL; no source copy exists in Documents/Application Support. This contradicts the queue's recovery/data-retention intent. Apple explicitly allows temporary-directory purging while an app is not running: [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

**Smallest safe fix:** Record into a dedicated durable app-owned originals directory, or move each successfully finalized recording there before publishing/enqueueing it. Surface directory/move failures and preserve the source on failure. Do not automatically delete originals merely because a render failed.

**Regression verification:** With injectable storage roots, record/finalize a fixture, persist an outstanding job, clear only temporary storage, construct a fresh queue, and prove rendering/fallback still accesses the original bytes. Confirm on-device relaunch recovery.

### I2 — CVMetalTexture wrappers are released before GPU use completes

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/ProcessingPipeline/PipelineRenderer.swift:856, callers :774 and :821.

**Trigger/consequence:** Every rendered video frame uses the helper. It returns only MTLTexture and drops the local CVMetalTexture before either GPU command buffer is committed/completed. This violates Core Video's explicit lifetime requirement and permits invalid backing storage/reuse during GPU access. Corrupt output or GPU failures are plausible consequences; neither was reproduced here.

**Trace:** makeTexture returns CVMetalTextureGetTexture(cvTexture) at :874. runPass1/runPass2 wait for completion only after the helper has returned (:805/:847). Retaining the pixel buffer and the MTLTexture does not satisfy Apple's separate wrapper requirement. [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)) explicitly requires a strong textureOut reference through GPU completion.

**Smallest safe fix:** Return/retain the wrapper with its MTLTexture and use withExtendedLifetime around command submission plus waitUntilCompleted, or retain it in the command buffer completion closure. Preserve the current LUT upload and render math.

**Regression verification:** Existing synthetic render/cleanup tests plus repeated multi-frame renders with Metal validation enabled. Include device stress with simultaneous preview/recording; passing synthetic tests alone cannot demonstrate the former lifetime violation is harmless.

### I3 — Debug extraction delays durable Photos completion and enables duplicate saves

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/RenderQueue/RenderQueueViewModel.swift:174, :180, :198; recovery :65.

**Trigger/consequence:** Kill the app after Photos save returns successfully but before dumpFrames finishes. The queue file still describes a processing job with outputURL. On relaunch it becomes pending; executeJob uses the retained output and calls saveOperation again, duplicating the movie in Photos.

**Trace:** The output URL was persisted at :170. status completed/outputSavedToPhotos true is set in memory at :175, but final persistJobs occurs only after awaited synchronous image generation/PNG extraction on the generic executor. The recovery/save path does not otherwise consult a confirmed delivery marker.

**Smallest safe fix:** Persist completed/delivered state immediately after save success, before optional extraction. Keep diagnostic extraction outside the delivery durability boundary, preferably opt-in. Recovery should honor already persisted confirmed delivery. This reduces the avoidable window; fully atomic cross-store Photos/JSON delivery would require additional identity/reconciliation design and is not claimed here.

**Regression verification:** Gate an injected post-delivery operation, reload JSON while it is suspended, and prove the new queue does not render or save again. Preserve the existing delivery-failure retry-without-rerender test.

### I4 — Delayed shutter metering can override a recording pin or manual exposure

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraSession.swift:542; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:149, :203; CameraSession.swift:551.

**Trigger/consequence:** Start a take during the 100 ms re-meter window. A previously scheduled callback still computes a new ISO and writes custom exposure after recording starts, defeating “exposure is frozen during a take.” Switching to manual ISO can similarly overlap queued camera work because disableShutterPriority is asynchronous while lockManualExposure runs synchronously on MainActor.

**Trace:** refreshShutterPriority checks !movieOutput.isRecording before scheduling; its delayed callback checks only isShutterPriority. pinShutterForRecording is queued, but movieOutput.startRecording and metadata collection run immediately on the caller. setExposure/zoom/focus also directly access activeDevice outside sessionQueue while device selection/configuration and delayed meter writes occur on that queue. Hardware configuration locks protect hardware setters, not the app's unsynchronized activeDevice/state or logical sequencing.

**Smallest safe fix:** Route capture start/stop and device mutations through the existing serial session queue; keep UI state/results on MainActor. Invalidate pending re-meter callbacks using a generation/token when recording starts, manual mode is entered, the lens changes, or the session stops. Check recording and desired mode again in delayed work. Pin exposure and collect metadata in order before starting output; preserve 180° shutter, EV behavior, and WB policy.

**Regression verification:** An injectable scheduler/device seam should prove a delayed meter cannot write after recording/manual/stop boundaries and that pin → metadata → start ordering holds. Device checks must verify ISO remains constant during a take and controls remain responsive while rendering. No measured hitch attribution is made.

### I5 — Usable recordings with an AVFoundation termination error never reach the queue; terminal timers leak

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraSession.swift:606; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:315, :326.

**Trigger/consequence:** AVFoundation ends a take with a nonnil error whose AVErrorRecordingSuccessfullyFinishedKey is true. The movie is playable but is classified as failure; its URL is never published or enqueued. Separately, any output-driven termination (disk limit, interruption, start failure) bypasses the button stop path and leaves the recording timer and space timer running. The next take can overwrite the recordingTimer reference without invalidating the old timer, producing multiple duration increments and premature auto-stop.

**Trace:** The delegate unconditionally reports .failure for error != nil. The installed SDK AVError.h:20 describes the key as an NSNumber indicating whether the recording is playable. handleRecordingFinished only sets isRecording false and handles the result; timer cleanup exists only in stopRecording. See [AVErrorRecordingSuccessfullyFinishedKey](https://developer.apple.com/documentation/avfoundation/averrorrecordingsuccessfullyfinishedkey) and [recording completion delegate](https://developer.apple.com/documentation/avfoundation/avcapturefileoutputrecordingdelegate/fileoutput(_:didfinishrecordingto:from:error:)).

**Smallest safe fix:** Interpret the successful-finish flag and preserve/publish playable finalized files while separately presenting any termination warning. Stop recording/space timers on every terminal delegate path; invalidate an existing timer before starting a replacement. Retain failed originals rather than silently deleting them.

**Regression verification:** Inject nil error, error+true flag, error+false/missing flag. Verify exactly one URL publication for usable files and no publication for unusable files, truthful warnings, zero ticks after terminal completion, and a subsequent recording with exactly one timer.

### I6 — Capture filenames still collide within one second

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:311.

**Trigger/consequence:** Finish a short recording and start another within the same Unix second. Both choose clip_<seconds>.mov; the second recording fails because the first file already exists. A retry after an immediate recording error can hit the same problem.

**Trace:** Capture uses a timestamp only; renderer output already fixed the equivalent problem with randomized unique paths. Installed SDK AVCaptureFileOutput.h:73 explicitly states that recording fails when the destination exists. [startRecording](https://developer.apple.com/documentation/avfoundation/avcapturefileoutput/startrecording(to:recordingdelegate:)) documents the API.

**Smallest safe fix:** Use a UUID for capture filenames in the durable originals directory from I1. Do not overwrite an existing original.

**Regression verification:** Generate many recording destinations using the same injected timestamp, occupy prior paths, and require every destination to be unique; manually exercise rapid stop/start.

### I7 — Camera permission recovery has no foreground entry point

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraView.swift:15; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraViewModel.swift:45, :87; /tmp/nitrate-camera-render-integration/App/App.swift:25.

**Trigger/consequence:** Deny Camera access, follow the banner's Settings instruction, grant access, and return to the same live SwiftUI scene. The code only requests/configures on view appearance; changing scene activation does not recreate the view. There is no foreground permission recheck, so the camera remains unavailable until a new appearance/relaunch. A successful later configure also does not clear the stale denial message.

**Trace:** No scenePhase/application-active handler or session runtime/interruption observers exist. Pending configure completion also unconditionally calls startSession even if onDisappear has requested stop in the meantime.

**Smallest safe fix:** Add an idempotent desired-active lifecycle entry point, recheck authorization on foreground activation, and gate asynchronous configuration completion against that state/generation. Clear a resolved authorization error without erasing unrelated errors. Stop/invalidate appropriate camera work when no longer active; preserve user exposure mode when resuming.

**Regression verification:** Inject authorization and configuration completion: denied → background/settings grant → active starts once; disappear/background before completion must not start a hidden session. Verify on a phone including Settings return. Runtime-error/interruption recovery beyond this confirmed permission defect still needs device checks.

### I8 — Tap-to-focus/exposure uses display coordinates as sensor coordinates

**Location:** /tmp/nitrate-camera-render-integration/App/ContentView.swift:154; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraSession.swift:358, :484.

**Trigger/consequence:** Tap an off-center subject in the portrait/aspect-fill preview. ContentView divides x/y by view size and writes that point directly as the device interest point, ignoring orientation and crop. Focus/exposure targets a different region. The child CameraView already has a correctly converted focus path, but the full-size transparent overlay adds a competing hit target and the wrong path remains independently incorrect.

**Trace:** Geometry normalization is not the preview layer's coordinate transform. FocusManager.swift:26 uses captureDevicePointConverted correctly. Apple states that conversion accounts for the layer's frame and videoGravity and that device points are in the unrotated image: [captureDevicePointConverted](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/capturedevicepointconverted(fromlayerpoint:)).

**Smallest safe fix:** Keep one tap owner where the live preview layer is available; convert once using that layer and send the converted point to both focus/exposure through sessionQueue. Remove the geometry-normalized duplicate path.

**Regression verification:** Check off-center subjects on rear/front lenses, aspect-fill and framed preview on a phone; verify both focus and exposure receive the same layer-converted point. Do not assume a center tap exercises the defect.

### I9 — Two paths configure hardware after a failed configuration lock

**Location:** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraSession.swift:533; /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/FocusManager.swift:28.

**Trigger/consequence:** lockForConfiguration throws during a device availability/permission/configuration failure. Both paths discard that error with try?, then mutate exposure/focus and call unlockForConfiguration anyway. They configure without the required lock, allowing an Objective-C exception rather than a recoverable error.

**Trace:** In pinShutterToFilm the exposureMode assignment and unlock are unconditional after try?. FocusManager has the same sequence. Apple's API requires acquiring the lock before hardware-property setters: [lockForConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration()). Installed AVCaptureDevice.h also documents NSGenericException for unsupported lockless configuration.

**Smallest safe fix:** Use do/try with defer unlock only after successful acquisition; abort/report the failed operation. Preserve WB locking behavior.

**Regression verification:** Force a lock failure through the device seam and prove no setter/unlock executes. Device availability/interruption testing supplements this logical regression.

## Minor confirmed usability defect

**M1 — Record action has no accessible name, and manual/auto switching is gesture-only.** /tmp/nitrate-camera-render-integration/App/Modules/CameraCapture/CameraControlBar.swift:326 draws its idle record button entirely from Shapes, with no accessibilityLabel. Its exposure mode switch at :243 is only a long-press gesture plus a spoken hint, with no accessible action. VoiceOver cannot reliably discover the record action or invoke the advertised mode switch. Add dynamic “Start recording”/“Stop recording” labels and an explicit accessibility action for exposure mode; inspect them with Accessibility Inspector and test VoiceOver. RenderStatusButton's label/value/hint and Reduce Motion treatment are present.

## Credible risks requiring profiling or device evidence

- **Reported 1–2 second animation hitch: cause unproven.** MainActor synchronously constructs PipelineRenderer at RenderQueueViewModel.swift:110 (Metal pipeline compilation, grain file read/upload), loads JSON, and JSON-encodes/atomically writes the full queue at :120. Enqueue and processNext perform successive writes before the worker starts. Direct main-thread configuration locks described in I4 and the PhotosPicker full-Data write at ContentView.swift:204 are other blocking candidates. Startup initialization is mainly a startup issue; it should not be asserted as the cause of a later recurring render hitch. Instrument these boundaries with signposts/Time Profiler plus SwiftUI/Core Animation instruments during record-stop, import, retry, lens and ISO interactions before attributing duration. Move genuinely expensive work off MainActor while preserving ordered persistence and UI publication.
- **Import memory/disk cost:** ContentView.swift:202 loads an entire video into Data, then synchronously writes it on MainActor; long 4K imports can require hundreds of MB or GB. A file-based Transferable import copied on a background I/O queue is a focused improvement; no OOM measurement was taken. Import failure currently lacks a clear visible error.
- **Background/render cancellation:** Queue worker is app-lifetime, with no pause/cancel/background policy; camera runtime/interruption notifications are unhandled. Metal/background availability and timeout behavior need device checks. Existing cancellation tests do not exercise cancellation exactly at EOF/markAsFinished/finishWriting transition boundaries.
- **Sendability:** AudioCopyResultBox and reader/append cancellation lanes have explicit locking, and FrameCounterBox has a single serial owner. PipelineRenderer's unchecked Sendable relies on current callers serializing complete renders; its mutable LUT setup itself is not protected against future simultaneous calls. Current app and CLI call paths are sequential, so this is not reported as a reachable concurrent-render defect. Under project.yml's current Swift 6 settings, nonisolated async renderer/dumpFrames work uses the generic executor; this review does not claim their LUT parsing or GPU waits block MainActor. [Swift SE-0338](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md).
- **Storage policy:** Durable rendered output/imports and automatic full-resolution PNG frame dumps accumulate without a pruning policy. Any cleanup should preserve undelivered output and unsaved originals and be user-directed for irreplaceable media. File-protection behavior while locked and real disk exhaustion need phone checks.

## Inspected behavior and verification limits

Inspected AGENTS.md, docs/development.md, session-statefulness plan, render-hardening checklist, commit narrative, all supplied non-cube changes; full current camera modules (session, view model, preview, focus, exposure state machine, control bar, manual panel, ruler); queue model/persister/job/sheet/status; app/ContentView stock/import callers; stock loader/config/catalogs; renderer, spatial callee, diagnostics/metadata callers; and relevant reliability, persistence, catalog, LUT, output-path and render-contract tests/project configuration.

Positive traces: FIFO jobs retain storage order while terminal display sorts newest first; old pending jobs remain visible; Show all stays reachable in the empty state; process-lifetime session ID and recovery/retry adoption are implemented. Optional delivery fields retain old JSON compatibility. JSON writes are atomic; corrupt JSON is preserved instead of silently overwritten and load/persistence/external/current-result error precedence exists. Stock loading precedes initial restoration; immediate picker preference writes and NSNumber ISO bridging exist. Both catalogs offer exactly 50D/250D/200T/500T K2383, with matching resources. Removed stock IDs fail explicitly rather than substituting a LUT; retained processed output can still be delivered without rendering that removed stock.

Renderer trace: separate audio reader; EOF before backpressure polling; each input marked finished at its EOF; worker joins audio before finalization; append/reader/writer failures propagated; trim-origin writer session retained; failed/cancelled renders delete partial output; raw fallback remains a failed render and reports Photos outcome; processed Photos failure retains output for retry. No additional confirmed trim/EOF regression found.

**Tests existing versus run:** Root reports its last verified baseline had 51 passed, zero skipped, unsigned generic iOS and signed device builds passed. This reviewer did not rerun them. Existing tests meaningfully cover serial worker/delivery, fallback outcomes, retained-output retry, recovery/session filtering, history/error scope, corrupt persistence, catalog/ISO restoration, trim/audio endpoints, silent movies, rejection cleanup and in-flight cancellation. They do not cover the confirmed camera lifecycle/timer/permission/coordinate defects, durable recorded-source recovery, or delivery persistence before diagnostic extraction; the renderer fixtures are 64×64 synthetic media, not 4K camera workloads.

Signing/team U43C6BCZFS and bundle com.filmemulation.app are preserved in project.yml. No changes to WB policy, RGB/red-fastest LUT uploads, custom metadata, or the user-declared color contract are proposed. Builds/unit tests cannot prove device camera behavior, hitch duration, visual calibration, or colorimetric accuracy. After fixes, root should run the required verify pass and signed device build last, then complete the expanded phone checklist.
