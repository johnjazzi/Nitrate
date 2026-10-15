# Recording A/V timing

## Failure and cause

The reported symptoms were a silent opening of roughly three seconds and an earlier
capture smoke failure: audio/video track ends differed by 0.650 seconds despite
reported first-sample skew of zero.

Physical-device comparisons isolated two capture-boundary defects:

1. **Missing opening audio.** Cinematic and Extreme stabilization delivered video
   later than microphone audio. The recorder discarded audio while idle and while
   awaiting its first eligible video frame. By the time that frame established the
   writer's source-time origin, the corresponding microphone samples were gone.
   The writer inserted an empty audio edit before the first real audio segment.
2. **Missing video tail.** Stop immediately finished both inputs. Audio had already
   reached the stop time, but stabilized video representing that same interval had
   not arrived yet.

The old first-sample check did not detect the opening gap: the compressed audio
reader reported PTS zero for the empty edit. On the instrumented device, Cinematic
had a 0.659-second empty opening audio segment and Extreme had a 1.929-second
segment. Extreme's track ends differed by 1.894 seconds. The exact three-second
opening reported by the user was not independently reproduced.

A third loss appeared after fixing those boundaries: flushing preroll and creating
HEVC on the shared video/audio delegate queue caused a 0.115-second gap in
microphone delivery. The iOS SDK's `AVCaptureAudioDataOutput.h` explicitly documents
that sufficiently late samples are dropped when the delegate queue is blocked.
AAC output did not retain that source-time gap as missing timeline space: encoded
audio was shorter than the source timestamps implied. This left Extreme near or
above the unchanged 0.12-second acceptance limit.

## Fix

- Keep a rolling microphone preroll while idle and awaiting video, bounded to five
  source seconds and 512 packets. Do not retain idle video frames.
- Give audio its own serial delegate queue. Copy PCM bytes into owned memory before
  returning, then hand them to the writer queue. Bound outstanding handoffs to 64
  packets; overflow reports failure rather than silently discarding sound or
  allowing unlimited queued buffers.
- When the first eligible video establishes the origin, append eligible preroll
  audio at its original PTS, then signal recording started. A failed flush cannot
  signal start success.
- At stop, freeze the last accepted audio packet's end, reject subsequent audio,
  and continue accepting delayed video until its sample end reaches that endpoint.
  Duplicate stop requests cannot extend it. A generation- and writer-fenced
  five-second timeout fails if video never catches up.
- Defer camera-session shutdown until the recorder's terminal callback, so the
  shutdown itself does not cut off the drain. A foreground resume cancels deferred
  session shutdown.
- Check the first **nonempty audio segment**, not just compressed PTS zero. Keep
  the 0.12-second start/end tolerance. Apply it to normal completed recordings as
  well as the preservation smoke.

Neither track is retimed. The fix does not generate silence, replace sound, or
relax the validation threshold. Existing clips cannot recover microphone samples
that were never recorded.

## Device evidence

Reference device: physical iPhone 18 Pro. Log preview disables the independent
LUT-preview connection; Neutral enables it. Each row is one completed three-second
smoke (timed from the recorder's start callback), with valid 4K HEVC Main10/Apple
Log 2 tags, decoded first-frame YUV preservation, and AAC audio.

| Stabilization | Preview | Audio-content start skew | Track-end difference |
|---|---|---:|---:|
| Extreme | Neutral | 0.003 s | 0.016 s |
| Extreme | Log | 0.003 s | 0.035 s |
| Cinematic | Neutral | 0.005 s | 0.016 s |
| Cinematic | Log | 0.001 s | 0.010 s |
| Standard | Neutral | 0.012 s | 0.018 s |
| Standard | Log | 0.005 s | 0.025 s |
| Off | Neutral | 0.006 s | 0.028 s |
| Off | Log | 0.002 s | 0.022 s |

All eight passed the unchanged 0.12-second checks. All eight also reported zero
maximum source-audio gap. Before the fix, Cinematic failed with both preview modes
(0.653/0.672-second track-end differences), while Off and Standard passed. Preview
was therefore not the cause of that failure.

The retained Extreme/Neutral capture was also rendered through the production
Metal pipeline with stock `kodak5219`. All 123 video-frame PTS values matched the
source exactly, and the encoded AAC payload was byte-identical (SHA-256
`1bacb4e3abf61d51aeb8e4c8a8cd01510b9117ff1a19d3708e9330abe0b0fa8c`). Rendered
track durations remained within tolerance. This verifies one real captured clip
through rendering; it is not a long-recording or perceptual lip-sync study.

## Regression evidence

Executed before the recorder fix: both startup-audio and stop-drain tests failed
on the original implementation. After integration they passed. The empty-audio-edit
probe test also failed against the original compressed-PTS calculation and passed
with segment-aware timing. A separate regression caught audio callbacks touching
writer state directly while the writer queue was blocked.

Additional tests cover idle preroll, time/count bounds, no-audio recordings, flush
failure, cancellation, duplicate stop, already-caught-up video, timeout, stale
callbacks, owned PCM bytes and handoff overflow. Removing the owned-memory copy
and enlarging the handoff cap made the two relevant tests fail; restoring them
returned the suite to green. Review also found stale audio copy/overflow errors
could cancel the next clip. Both interleavings failed before adding an epoch
snapshot under the handoff lock and checking it on the writer queue; the final
suite passes both.

A second matrix on a pinned, signature-verified copy of the final app also passed
all eight combinations: opening skew 0.002–0.020 seconds, end difference
0.004–0.041 seconds, and no source-audio gaps. The app's fix-specific diagnostics
were required in every log: a concurrent task installed an older build during an
earlier repeat, so those results were excluded from final-build evidence. One
cold Extreme launch was canceled before its first frame; it produced no clip
and was not counted as a timing pass. The successful repeat does not establish
reliable cold startup in all conditions.

Debug smoke recordings normally delete their temporary output. Use
`--keep-hevc-log2-smoke` with `--smoke-hevc-log2-capture` to retain a successful
recording for source-versus-render inspection. The debug smoke keeps the display
awake during an automated matrix; a normal launch does not enable that behavior.

## Capture start latency

The record button cannot confirm a take until capture reports it, and that report
waits on the whole start path: the session-queue hop, the custom-exposure settle,
and the first eligible frame reaching the writer. Measured on the physical iPhone
18 Pro (Debug smoke, one take per mode, two or three repeats per row; the clock
starts when `startRecording` is requested and stops when the recorder appends its
first frame and signals started):

| Stabilization | Request → confirmed | First video callback after writer begin | Frames dropped as pre-exposure |
|---|---:|---:|---:|
| Off | 0.27–0.30 s | 4–6 ms | 1 |
| Standard | 0.28–0.32 s | 8 ms | 2 |
| Cinematic | 0.93–0.94 s | 9 ms | 17 |
| Extreme | 2.19–2.23 s | 890–935 ms | 25 |

Stage split at Extreme: session-queue hop ≈0 ms, custom-exposure settle ≈0.18 s,
then ≈2.0 s inside the recorder before the first frame is appended.

**Confirmation is not capture.** Sampling the session's synchronization clock at
the request and comparing it with the recorder's first written frame PTS — both on
the capture clock — gives how much real time a take actually loses at the head:

| Stabilization | Request → confirmed | Real head loss |
|---|---:|---:|
| Extreme | 2.20 s | 0.19–0.22 s |
| Off | 0.29 s | 0.21–0.22 s |

The take's content therefore begins about 0.2 s after the tap in every mode: the
first kept frame is the first one at or after the recording exposure taking
effect, which is what the recorder uses as its start-after point. Stabilization
only changes how long the writer takes to confirm.

Cinematic and extended-cinematic run the pipeline behind the capture clock (~0.7 s
and ~1.0 s), so the frames delivered when a take begins already predate the
exposure change and are correctly discarded — 17 and 25 frames at 24 fps match
those offsets. Extreme additionally stalls frame delivery for about 0.9 s at take
start. Re-writing the same `preferredVideoStabilizationMode` was tested as the
cause and is not it: the mode is already active before the take
(`activeVideoStabilizationMode` reports it at configure, at session start and at
record start), and skipping the redundant write changed nothing.

Because confirmation lags capture, the control acknowledges the tap itself rather
than the take. The REC dot turns red immediately, a haptic fires, and the timer is
back-dated by the head offset above (`CameraSession.recordingHeadOffset()`) so it
reports recorded content rather than time since confirmation — a stopwatch
compared against the file is what exposed that difference. A second tap during the
pending window cancels the start. `CameraViewModel.isStartingRecording` is the
flag behind that state, and `RecordButtonPresentationPolicy` decides the label,
enablement and tap action.

Stop is acknowledged the same way, for the same reason: finalising is not
instant. The face dims, the badge greys and the timer freezes at the stop request
while the recorder drains (`isStoppingRecording`, `recordingStoppedAt`), and a
further tap is ignored rather than queued. The timer renders hundredths
(`mm:ss.cc`) from wall clock, truncated rather than rounded, so it never shows a
hundredth that has not elapsed.

Limits: measured on a warm session with the debug smoke. Cold starts, longer
recordings, and the exact cause of the Extreme stall inside AVFoundation are not
characterized here. The per-mode delays are how long the take takes to register,
not how much content it loses: that is the ~0.2 s head loss, in every mode.
