# Development Photo exposure increment

The owner authorized independent ISO/shutter controls, RAW color validation and exposing Photo in the development build. P0a capture/Video restoration passed on physical iPhone; P0b and real color normalization remain unfinished. Production and TestFlight keep Photo hidden. Initial exposed Photo is explicitly experimental, stores durable local DNGs, does not claim developed JPEG/Photos delivery or calibrated color, and never automatically reviews a capture.

## Runtime / UI boundary

`PhotoExposureSnapshot.swift` is the agreed Foundation-only value type. Preserve its member names. The runtime worker owns `CameraSession.swift` and these methods, available under `#if DEBUG`; every operation is serialized on sessionQueue and callbacks hop to MainActor:

```swift
func setDevelopmentPhotoMode(_ enabled: Bool,
    onUpdate: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
func setDevelopmentPhotoISO(_ value: Float) // selecting a value pins ISO
func setDevelopmentPhotoDuration(_ seconds: Double) // selecting a value pins duration
func setDevelopmentPhotoISOLocked(_ locked: Bool) // pin the measured value, independently
func setDevelopmentPhotoShutterLocked(_ locked: Bool)
func setDevelopmentPhotoEV(_ value: Float)
func captureDevelopmentPhoto(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void)
func startDebugPhotoExposureSmoke(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void)
```

The Photo graph remains active between shots; entering/exiting is transactional and original Video graph/exposure/WB must restore using the P0a barriers. Owner UI correction: preserve the existing ISO well and put the Photo-only shutter ruler in the manual-controls overlay, visible only when Shutter Control is enabled. Shutter Lock and ISO Lock remain independent; both locked means manual exposure, both unlocked remains auto. Remove the always-visible bottom shutter/EV row and avoid metering-driven layout shifts. Capture feedback must remain visible without a captured-photo review. No idle Photo mode may masquerade as an in-flight sensor transaction. Restrict the first development slice to the demonstrated rear-wide path; do not advertise unsupported lens/zoom changes. Backgrounding cancels new requests and preserves in-flight delegate ownership, then restores/reconfigures safely. Neutral native-aspect preview is required; disable the monitoring LUT in Photo without changing normal Video preview behavior.

UI worker owns CameraViewModel, ContentView, CameraControlBar, CameraModeSelection/Carousel and Photo shutter views/tests. Use the exact runtime signatures. `#if DEBUG` plus exact development bundle identity enables P; production/Release stays hidden. Existing ISO presentation/range/Float/Lock gestures remain unchanged; route Photo intents through these methods, never through video's fixed-shutter loop. Stop video-only exposure loops in P. State selection changes only after configuration completion. Preserve separate Video/Photo exposure and stock selection. Shutter taps write a DNG and show truthful local-capture feedback. P hides REC timing, rescue FPS and recording stabilization. A compact Photo shutter ruler exposes independent Float/Lock and actual supported endpoints with detents/haptics. Do not implement editor, gallery, queue or pretend Photos saving.

The parent owns project.yml, fixture allowlists, Xcode builds, physical tests and integration. Workers use source-only sparse worktrees, focused tests only when explicitly allowed, otherwise lint; no device installs, dependency changes, full Xcode runs or deletion of caches/artifacts.

## Validation

- Policy tests cover four Float/Lock states, finite/range checks, EV changes through only the floating value, locked-value preservation, limits and settling; both-locked is meter-only. Native tests plus actual DNG EXIF establish separate layers of evidence.
- Existing P0a smoke stays intact. New `startDebugPhotoExposureSmoke` owns a serial four-state experiment, durable per-shot evidence, timeout and lock/EV checks, restores Video, and returns its evidence directory. The VM exposes it with `--smoke-photo-exposure-p0b` in Debug. Real hardware tests compare pins with measured EXIF; unsupported endpoints are failures, not fabricated passes.
- Color worker owns only new decode/adapter source, photo-only Metal and tests. Use declared extended-linear-sRGB to AppleWG/Log2, actual cubes and explicit output contracts from implementation-plan.md. Preserve Video shaders/bytes. Default reference exposure gain is explicitly uncalibrated; known gray/chart exposure fixtures are still needed to validate normalization. Never infer calibration from arbitrary captured scenes or synthetic parity.
