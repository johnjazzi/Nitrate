import AVFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

/// Selectable capture lenses. Maps a UI-facing name to an AVCaptureDevice type
/// + position. "Normal" is the rear wide (1x) camera.
enum CameraLens: String, CaseIterable, Identifiable, Sendable {
    case ultraWide = "Ultrawide"
    case wide = "Normal"
    case telephoto = "Tele"
    case front = "Front"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .front: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }

    var systemImage: String {
        switch self {
        case .ultraWide: return "camera.viewfinder"
        case .wide: return "camera.fill"
        case .telephoto: return "camera.circle"
        case .front: return "camera.rotate"
        }
    }

    /// Compact x-factor shown on the lens pills in the control bar.
    var zoomLabel: String {
        switch self {
        case .ultraWide: return ".5x"
        case .wide: return "1x"
        case .telephoto: return "4x"
        case .front: return "Front"
        }
    }

    /// Equivalent full-frame focal length for the zoom label (display only).
    var focalLengthMM: Int {
        switch self {
        case .ultraWide: return 13
        case .wide: return 24
        case .telephoto: return 96
        case .front: return 24
        }
    }
}

/// Narrow bridge for requests that cross main only to read device orientation.
/// The reference may only submit queue-confined recording/debug work; it never
/// reads or mutates the session's state on the main actor.
private struct CameraOrientationSessionReference: @unchecked Sendable {
    weak var session: CameraSession?
}

/// AD-3: Manages the AVCaptureSession — Apple Log, HEVC H.265, 4K, 24fps, clean preview.
/// Runs on a dedicated serial queue. Never posts to main thread directly.
///
/// `@unchecked Sendable` states the confinement this type already relies on:
/// every mutable stored property is written only inside `sessionQueue` blocks,
/// with two exceptions that are guarded by `recordingStateLock`
/// (`publicRecordingState`, `recordedStartHeadOffset`), so capturing `self` in
/// the queue's `@Sendable` blocks hands the reference to one serial executor
/// rather than sharing it between two. The `private(set)` lens/device/exposure
/// snapshots are also read on the main actor; those are word-sized value types
/// written on `sessionQueue` only, so a reader observes a value from before or
/// after a write. `let` dependencies (queues, capture objects) are immutable
/// after `init`.
final class CameraSession: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    fileprivate let sessionQueue = DispatchQueue(label: "camera.session")
    private let sampleBufferQueue = DispatchQueue(label: "camera.sample-buffer-writer")
    private let audioSampleBufferQueue = DispatchQueue(label: "camera.audio-capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    // Attached only during initial configuration. Normal/Log switches only gate
    // this connection; neither the writer nor the capture device is reconfigured.
    private let previewOutput = AVCaptureVideoDataOutput()
    private let previewTap = CameraPreviewTap()
    private var previewOwner: UUID?
    private var previewFormatReady = false
    private var previewSuspended = true
#if DEBUG
    /// Debug single-frame tap: an independent second video output with its own
    /// delegate, so the recorder's `videoOutput` and delegate stay untouched. Its
    /// connection is disabled except while a debug frame is requested, so the
    /// recording path is unaffected in steady state.
    private let debugFrameOutput = AVCaptureVideoDataOutput()
    private let debugFrameQueue = DispatchQueue(label: "camera.debug-frame")
    private let debugFrameTap = CameraDebugFrameTap()
#endif
    private lazy var sampleBufferRecorder = CameraSampleBufferRecorder(queue: sampleBufferQueue)
    private var acceptedPixelFormats: Set<UInt32> = []
    private var acceptedVideoSettings: [String: Any] = [:]
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var microphoneAdded = false
    private var isConfigured = false
    private var recordingActive = false
    private var recordingFinishing = false
    /// Session shutdown must not discard video still delayed by stabilization.
    /// Cleared if the camera resumes before that recorder reaches its terminal callback.
    private var stopSessionAfterRecording = false
    /// Fixed white-balance temperature (Kelvin) requested by the selected stock.
    /// Applied on the next configureDevice or immediately via setWhiteBalance.
    private var whiteBalanceTemperature: Float?

    /// True while 180° shutter priority is active (shutter locked to 1/48s,
    /// ISO auto-meters). Cleared by manual exposure, which pins both.
    private(set) var isShutterPriority = false
    /// Nil means "hold the current iris value". An explicit stop is the only
    /// thing that moves the aperture; the metering paths never auto-drive it.
    /// Access is serialized on sessionQueue; UI reads are refreshed by
    /// CameraViewModel after each aperture operation.
    private var selectedLensAperture: Float?
    private var manualExposureISO: Float = 400
    /// The committed manual-focus lens position (0–1) while MF is selected, or
    /// nil when the device auto-focuses. Queue-confined. A preview tap re-meters
    /// exposure but must not silently autofocus while this is set, and a committed
    /// lens switch reapplies or drops it (L09).
    private var committedManualFocusLensPosition: Float?
    private var recordingAperturePin: CameraAperturePolicy.RecordingPin?
    private var apertureCameraRevision: UInt64 = 0
    private var zoomLifecycle = CameraZoomRampLifecycle()
    private var zoomObserver: (@MainActor @Sendable (CameraZoomSnapshot?) -> Void)?
    private var zoomSamplingGeneration: UInt64 = 0
    // Queue-confined. Preserve the user's preference when a lens/format cannot
    // fulfill it; only the recording connection falls back to Off.
    private var preferredStabilization = CameraStabilizationMode(
        persistedValue: UserDefaults.standard.string(forKey: CameraStabilizationPolicy.preferenceKey))

    /// Currently selected lens (rear wide/ultrawide/tele, or front).
    private(set) var activeLens: CameraLens = {
#if DEBUG
        if CommandLine.arguments.contains("--smoke-front-hevc-log2-capture") {
            return .front
        }
#endif
        return .wide
    }()
    /// Current device (accessible for view model queries)
    private(set) var activeDevice: AVCaptureDevice?

    private var onRecordingFinished: (@MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void)?
    private var onCameraError: (@MainActor @Sendable (Error, CameraLens) -> Void)?
    private var meterGeneration = CameraMeteringGeneration()
    /// The exposure currently pinned by the shutter-priority path, used to
    /// decide whether a re-meter is worth taking at all. Cleared whenever the
    /// pin is released (manual ISO, auto exposure, lens switch, session stop).
    private var pinnedExposure: ExposureStabilizer.Pin?
    private var isShutterMeteringPending = false
    private var recordingStartPending = false
    /// Set once so device-orientation notifications (needed for a live
    /// `UIDevice.current.orientation`) are started exactly once per session.
    private var deviceOrientationNotificationsStarted = false
    // Session-queue confined and replaced with the active camera. AVFoundation
    // accounts for rear/front sensor mounting; interface orientation is irrelevant.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var captureRotationState = CameraCaptureRotationPolicy()
    private var recordingGeneration: UInt64 = 0
    private var recorderCompletionBridge = CameraRecorderCompletionBridge()
    private var pendingStartCompletion: (@MainActor @Sendable (Error?) -> Void)?
    private let recordingStateLock = NSLock()
    private var publicRecordingState = false
    /// Wall-clock delay from the take request to the moment the recording
    /// exposure took effect. The take's first frame lands at that instant, so the
    /// REC timer is back-dated by this: the writer can confirm seconds later, and
    /// a timer started at confirmation understates the recorded content.
    private var recordedStartHeadOffset: TimeInterval = 0

    /// Capture frame-rate mode. Session-only and never persisted: the cold-launch
    /// value is `.standard24`. Queue-confined — written only on `sessionQueue`;
    /// read on the main actor for display, where a word-sized value is observed
    /// from before or after a write.
    private(set) var frameRate: CameraFrameRate = .standard24
    /// True while a mode change is queued or running. Record, lens and further
    /// mode actions are refused while it is set so a transition cannot race a
    /// take or another switch.
    private var frameRateTransitionPending = false
    /// Bumped on every session-boundary reset. A transition completion that lands
    /// after a reset is recognised as stale, so a backgrounded transition cannot
    /// restore the armed mode on the next foreground session.
    private var frameRateTransitionGeneration: UInt64 = 0
    /// A session-boundary reset waiting for the active take to drain.
    private var pendingFrameRateReset = false

    /// Head offset for the take that most recently started.
    func recordingHeadOffset() -> TimeInterval {
        recordingStateLock.lock()
        defer { recordingStateLock.unlock() }
        return recordedStartHeadOffset
    }
#if DEBUG
    private var debugSmokeURL: URL?
    private var debugSmokeTimedOut = false
    /// References and mutations are confined to sessionQueue.
    private final class DebugPhotoRun: @unchecked Sendable {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let color: AVCaptureColorSpace
        let minimumFrame: CMTime
        let maximumFrame: CMTime
        let maximumExposure: CMTime
        let exposureMode: AVCaptureDevice.ExposureMode
        let iso: Float
        let duration: CMTime
        let bias: Float
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let gains: AVCaptureDevice.WhiteBalanceGains
        let zoom: CGFloat
        let inputs: [AVCaptureInput]
        let outputs: [AVCaptureOutput]
        let preset: AVCaptureSession.Preset
        let videoSettings: [String: Any]
        let shutterPriority: Bool
        let directory: URL
        let completion: @MainActor @Sendable (Result<URL, Error>) -> Void
        var shouldRestart: Bool
        var interrupted = false
        var graphChanged = false
        var evidence: [String: String]
        var restorationBarrier: PhotoCompletionBarrier
        var restorationStarted = false
        var restorationFailure: String?
        var captureFailure: String?

        init(owner: CameraSession, device: AVCaptureDevice, directory: URL,
             completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
            self.device = device
            format = device.activeFormat
            color = device.activeColorSpace
            minimumFrame = device.activeVideoMinFrameDuration
            maximumFrame = device.activeVideoMaxFrameDuration
            maximumExposure = device.activeMaxExposureDuration
            exposureMode = device.exposureMode
            iso = device.iso
            duration = device.exposureDuration
            bias = device.exposureTargetBias
            whiteBalanceMode = device.whiteBalanceMode
            gains = device.deviceWhiteBalanceGains
            zoom = device.videoZoomFactor
            inputs = owner.session.inputs
            outputs = owner.session.outputs
            preset = owner.session.sessionPreset
            videoSettings = owner.videoOutput.videoSettings
            shutterPriority = owner.isShutterPriority
            shouldRestart = owner.session.isRunning
            self.directory = directory
            self.completion = completion
            var required: Set<PhotoCompletionStep> = [.graphConfigured, .biasApplied]
            if exposureMode == .custom || exposureMode == .locked { required.insert(.exposureApplied) }
            if whiteBalanceMode == .locked { required.insert(.whiteBalanceApplied) }
            restorationBarrier = PhotoCompletionBarrier(waitingFor: required)
            evidence = ["status": "prepared", "lens": owner.activeLens.rawValue,
                        "deviceType": device.deviceType.rawValue,
                        "videoFormat": CameraSession.captureFormatSubtypeDescription(device.activeFormat),
                        "videoColorSpace": String(device.activeColorSpace.rawValue),
                        "videoMinFrameSeconds": String(device.activeVideoMinFrameDuration.seconds),
                        "videoMaxFrameSeconds": String(device.activeVideoMaxFrameDuration.seconds),
                        "videoMaxExposureSeconds": String(device.activeMaxExposureDuration.seconds),
                        "videoExposureMode": String(device.exposureMode.rawValue),
                        "videoISO": String(device.iso), "videoExposureSeconds": String(device.exposureDuration.seconds),
                        "videoBias": String(device.exposureTargetBias),
                        "videoWBMode": String(device.whiteBalanceMode.rawValue),
                        "videoWBGains": "\(gains.redGain),\(gains.greenGain),\(gains.blueGain)",
                        "videoZoom": String(Double(device.videoZoomFactor)), "videoPreset": owner.session.sessionPreset.rawValue,
                        "inputTypes": inputs.map { String(describing: type(of: $0)) }.joined(separator: ","),
                        "outputTypes": outputs.map { String(describing: type(of: $0)) }.joined(separator: ","),
                        "os": ProcessInfo.processInfo.operatingSystemVersionString,
                        "videoAudioProof": "notRun"]
        }
    }
    private var debugPhotoRun: DebugPhotoRun?
    private var debugPhotoCapture: CameraPhotoCapture?
    private var developmentPhotoController: DevelopmentPhotoController?
    private var developmentPhotoSnapshot: DebugPhotoRun?
    private var developmentPhotoExitCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?
    private var developmentPhotoExitWaiters: [@MainActor @Sendable (Result<Void, Error>) -> Void] = []
    private var developmentPhotoUpdate: (@MainActor @Sendable (PhotoExposureSnapshot) -> Void)?
    private var developmentPhotoLensSwitchPending = false
    private var photoLensOwnership = PhotoLensSwitchOwnership()
    private var retainedPhotoOutput: AVCapturePhotoOutput?
    private var sharedIdleEnabled = false
    private var sharedGraph = SharedCameraGraphOwnership()
    private var sharedProfileObserver: (@MainActor @Sendable (Bool, Bool, Bool) -> Void)?
    private var sharedPhotoIntent: DevelopmentPhotoController.Intent?
    private var sharedVideoManualISO: Float?
    private var sharedVideoAperture: Float?
    private var sharedVideoZoom: Double = 1
    private var videoStartExposureInFlight = false
    private var sharedVideoBiasResetInFlight = false
    private struct SharedVideoRequest: Sendable {
        let epoch: UInt64
        let url: URL
        let completion: @MainActor @Sendable (Error?) -> Void
    }
    private var sharedVideoRequest: SharedVideoRequest?
    private var sharedLaunchScheduledEpoch: UInt64?

    /// Enabled only for the development Photo feature. Production Video retains
    /// its original Log2 lifecycle when the feature is unavailable.
    func enableSharedIdlePreview(
        onUpdate: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void,
        onProfile: @escaping @MainActor @Sendable (Bool, Bool, Bool) -> Void) {
        sessionQueue.async {
            guard DevelopmentPhotoFeature.isAvailable(isDebugBuild: true,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "") else { return }
            self.sharedIdleEnabled = true
            self.developmentPhotoUpdate = onUpdate
            self.sharedProfileObserver = onProfile
        }
    }

    func setVideoRecordingZoomIntent(_ zoom: Double) {
        sessionQueue.async { if zoom.isFinite { self.sharedVideoZoom = min(max(zoom, 1), 4) } }
    }

    func setVideoRecordingApertureIntent(_ aperture: Float?) {
        sessionQueue.async { self.sharedVideoAperture = aperture }
    }

    private func publishSharedProfile() {
        let video = sharedGraph.actual == .video && session.isRunning
        let busy = sharedGraph.isBusy || sharedGraph.actual != sharedGraph.desired
        let observer = sharedProfileObserver
        // A stopped graph is not a configured camera. Reporting the raw
        // `isConfigured` after a background transition left the view model
        // believing the camera was ready, so the foreground path skipped
        // configure/start and never reinstalled the idle graph.
        let configured = isConfigured && sharedGraph.actual != .stopped
        DispatchQueue.main.async { observer?(video, busy, configured) }
    }

    /// Only this queue advances profile ownership. Cancellation/background change
    /// the destination; entered Photo setters, RAW callbacks and video writers
    /// keep their lease until they have actually drained.
    private func driveSharedGraph() {
        guard sharedIdleEnabled, !sharedGraph.isBusy, !photoLensOwnership.isPending,
              !recordingActive, !recordingStartPending, !recordingFinishing,
              !videoStartExposureInFlight, !sharedVideoBiasResetInFlight,
              recorderCompletionBridge.activeEpoch == nil else { return }
        if sharedGraph.desired == .video, sharedGraph.actual == .video {
            launchSharedVideoRequest()
            return
        }
        if sharedGraph.desired == .idle, sharedGraph.actual == .idle,
           isConfigured, developmentPhotoController != nil {
            if !session.isRunning { session.startRunning() }
            publishSharedProfile()
            return
        }
        guard let lease = sharedGraph.begin(sharedGraph.desired) else { return }
        publishSharedProfile()
        if let controller = developmentPhotoController {
            sharedPhotoIntent = controller.intentSnapshot
            controller.stop { [weak self] in
                guard let self, self.sharedGraph.owns(lease) else { return }
                self.developmentPhotoController = nil
                self.finishSharedGraphTransition(lease)
            }
        } else {
            finishSharedGraphTransition(lease)
        }
    }

    private func finishSharedGraphTransition(_ lease: SharedCameraGraphOwnership.Lease) {
        guard sharedGraph.owns(lease) else { return }
        // A cancellation during the controller drain never installs the stale
        // destination. Finish the entered lease, then reconcile the new intent.
        guard lease.target == sharedGraph.desired else {
            sharedGraph.finish(lease, actual: sharedGraph.actual)
            driveSharedGraph()
            return
        }
        do {
            switch lease.target {
            case .stopped:
                suspendPreview(true)
                if session.isRunning { session.stopRunning() }
            case .idle:
                try installSharedIdleOnQueue()
            case .video:
                try installSharedVideoOnQueue()
            }
            sharedGraph.finish(lease, actual: lease.target)
            // The video renderer can attach only to the committed Log graph.
            if lease.target == .video { suspendPreview(false) }
            publishSharedProfile()
            if lease.target == .video { launchSharedVideoRequest() }
        } catch {
            // start()/restoreIntent() can throw after entering a device setter.
            // Keep the graph lease and running session until its ACK drains.
            if let controller = developmentPhotoController {
                controller.stop { [weak self] in
                    self?.finishFailedSharedGraphTransition(lease, error: error)
                }
            } else { finishFailedSharedGraphTransition(lease, error: error) }
        }
    }

    private func finishFailedSharedGraphTransition(_ lease: SharedCameraGraphOwnership.Lease, error: Error) {
        guard sharedGraph.owns(lease) else { return }
        developmentPhotoController = nil
        developmentPhotoSnapshot = nil
        isConfigured = false
        sharedGraph.finish(lease, actual: .stopped)
        if sharedGraph.desired == lease.target {
            sharedGraph.request(lease.target == .video ? .idle : .stopped)
        }
        let request = sharedVideoRequest
        sharedVideoRequest = nil
        sharedLaunchScheduledEpoch = nil
        if session.isRunning { session.stopRunning() }
        publishSharedProfile()
        if let request { DispatchQueue.main.async { request.completion(error) } }
        reportDevelopmentPhotoError(lease.target == .idle
            ? CameraError.captureRecoveryRequired(error.localizedDescription) : error)
        if sharedGraph.desired != .stopped { driveSharedGraph() }
    }

    private func installSharedIdleOnQueue() throws {
        guard let device = activeDevice, let update = developmentPhotoUpdate else { throw CameraError.noCameraAvailable }
        cancelZoomOnQueue()
        invalidateMetering()
        isShutterPriority = false
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevelopmentPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output: AVCapturePhotoOutput
        if let retained = retainedPhotoOutput, session.outputs.contains(where: { $0 === retained }) {
            output = retained
            try configureNativePhotoDevice(device)
        } else {
            let run = DebugPhotoRun(owner: self, device: device, directory: directory) { _ in }
            developmentPhotoSnapshot = run
            output = try configureDebugPhotoGraph(run)
            retainedPhotoOutput = output
        }
        selectedLensAperture = sharedPhotoIntent?.aperture
        try startDevelopmentPhotoController(device: device, output: output, directory: directory, update: update)
        apertureCameraRevision &+= 1
        zoomLifecycle.cameraChanged()
        publishZoom()
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else { throw CameraError.noCameraAvailable }
        isConfigured = true
    }

    private func installSharedVideoOnQueue() throws {
        guard let device = activeDevice else { throw CameraError.noCameraAvailable }
        suspendPreview(true)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .inputPriority
        guard session.canAddOutput(videoOutput) else { session.commitConfiguration(); throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)
        // Reuse the existing optional microphone policy and recorder delegates.
        if microphoneAdded, session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        else {
            if let microphoneInput { session.removeInput(microphoneInput) }
            microphoneInput = nil; microphoneAdded = false
            addMicrophoneInputLocked()
        }
        attachPreviewOutput()
        session.commitConfiguration()
        // The final acknowledged start setter applies the selected iris. Do not
        // launch an unacknowledged custom exposure while the graph lease drains.
        selectedLensAperture = nil
        try configureDevice(device)
        selectedLensAperture = sharedVideoAperture
        try device.lockForConfiguration()
        if let bounds = zoomBounds(for: device) {
            device.videoZoomFactor = CGFloat(min(max(sharedVideoZoom, bounds.minimumDevice), bounds.maximumDevice))
        }
        device.unlockForConfiguration()
        session.startRunning()
        guard session.isRunning else { throw CameraError.noCameraAvailable }
        isConfigured = true
        suspendPreview(false)
        developmentPhotoSnapshot = nil
        publishZoom()
    }

    private func launchSharedVideoRequest() {
        guard let request = sharedVideoRequest,
              sharedGraph.actual == .video, !sharedGraph.isBusy,
              sharedGraph.acceptsVideoRequest(request.epoch),
              sharedLaunchScheduledEpoch != request.epoch else { return }
        guard let device = activeDevice else {
            sharedVideoRequest = nil
            sharedGraph.request(.idle)
            DispatchQueue.main.async { request.completion(CameraError.noCameraAvailable) }
            driveSharedGraph()
            return
        }
        sharedLaunchScheduledEpoch = request.epoch
        // A no-op bias setter may never ACK on device (post-Stop physical trace).
        // No ownership was entered when hardware is already at the requested bias.
        if abs(device.exposureTargetBias) <= 0.001 {
            acquireSharedVideoExposure(request)
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            sharedVideoBiasResetInFlight = true
            device.setExposureTargetBias(0) { [weak self] _ in
                guard let session = self else { return }
                session.sessionQueue.async { [weak session] in
                    guard let session else { return }
                    session.sharedVideoBiasResetInFlight = false
                    guard session.sharedGraph.acceptsVideoRequest(request.epoch),
                          session.sharedVideoRequest?.epoch == request.epoch else {
                        session.sharedLaunchScheduledEpoch = nil
                        session.driveSharedGraph()
                        return
                    }
                    session.acquireSharedVideoExposure(request)
                }
            }
        } catch {
            sharedLaunchScheduledEpoch = nil
            sharedVideoRequest = nil
            sharedGraph.request(.idle)
            DispatchQueue.main.async { request.completion(error) }
            driveSharedGraph()
        }
    }

    private func acquireSharedVideoExposure(_ request: SharedVideoRequest) {
        // Match the existing shutter-priority meter's 100 ms acquisition window
        // only AFTER Photo's hardware bias has acknowledged zero. Video EV is
        // applied once in sharedRecordingISO, never again by the device meter.
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.sharedGraph.acceptsVideoRequest(request.epoch),
                  self.sharedVideoRequest?.epoch == request.epoch else { return }
            self.sharedVideoRequest = nil
            self.sharedLaunchScheduledEpoch = nil
            let reference = CameraOrientationSessionReference(session: self)
            Self.withPhysicalOrientation { orientation in
                reference.session?.startRecording(to: request.url, deliveryOrientation: orientation,
                    sharedRequestEpoch: request.epoch, completion: request.completion)
            }
        }
    }

    /// A deferred Video intent must still be visible: the operator is watching
    /// the shared idle camera, so the ISO/EV they just chose is mirrored onto it
    /// at once. Record re-applies the same value on the Log graph, so the preview
    /// never disagrees with the take, and the control stops feeling dead.
    /// Hand the shared exposure controls (ISO, compensation) to the Photo
    /// controller while Photo owns the shared idle device.
    ///
    /// Deliberately *not* mirrored: the shutter. Video's 180° film standard is a
    /// video rule, and the Photo controller is the same object the Photo shutter
    /// rail writes to — re-imposing 1/48s here (which an EV change, an ISO change
    /// and the AE lock all used to do) silently re-pinned the rail under the
    /// operator, so raising the compensation could never shorten the shutter and
    /// the frame stayed pinned at the film standard. The controller keeps its own
    /// shutter lock, whatever that is: held if the rail holds it, free if not.
    private func mirrorSharedExposureIntent(iso: Float?) {
        guard let controller = developmentPhotoController,
              developmentPhotoExitCompletion == nil,
              !sharedDeviceTransitionInFlight else { return }
        let current = controller.intentSnapshot
        do {
            try controller.restoreIntent(.init(iso: iso, duration: current.duration,
                                               ev: exposureBiasEV, aperture: current.aperture))
        } catch { reportDevelopmentPhotoError(error) }
    }

    private func sharedRecordingISO(for device: AVCaptureDevice) -> Float {
        if let sharedVideoManualISO { return sharedVideoManualISO }
        // Keep Video's existing EV/ISO metering policy, independent of Photo's
        // lock and compensation intent. The final start setter owns its ACK.
        switch ExposureStabilizer.decide(meteredISO: device.iso, ev: exposureBiasEV, current: nil,
            minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO) {
        case .apply(let iso): return iso
        case .hold: return device.iso
        }
    }

    private func returnToSharedIdleIfNeeded() {
        guard sharedIdleEnabled else { return }
        if sharedGraph.desired == .video { sharedGraph.request(.idle) }
        driveSharedGraph()
    }

    /// Phase timestamps for the current start request, so the request-to-running
    /// latency can be attributed to a specific stage instead of guessed at.
    private struct StartPhases {
        var requestedAt: Date?
        var queuedAt: Date?
        var exposureAppliedAt: Date?
        var recorderBeganAt: Date?
        /// Capture-clock time when the take was requested. Sample-buffer PTS use
        /// the same clock, so subtracting this from the recorder's first written
        /// frame gives how much real time the take actually loses at the head —
        /// which is not the same thing as how long the writer takes to confirm.
        var captureClockAtRequest: CMTime?

        /// One line attributing the request-to-running latency to each stage.
        func printLatency(error: Error?) {
            guard let requestedAt else { return }
            func offset(_ date: Date?) -> String {
                guard let date else { return "-" }
                return String(format: "%.0f", date.timeIntervalSince(requestedAt) * 1000)
            }
            let clock = captureClockAtRequest.map { String(format: "%.6f", $0.seconds) } ?? "-"
            print("Recording start latency: total=\(offset(Date()))ms queue=\(offset(queuedAt))ms " +
                  "exposure=\(offset(exposureAppliedAt))ms recorderBegin=\(offset(recorderBeganAt))ms " +
                  "requestClock=\(clock) error=\(error == nil ? "none" : "present")")
        }
    }
    private var startPhases = StartPhases()
#endif

    private struct PreviewConnectionReference: @unchecked Sendable {
        let connection: AVCaptureConnection
    }

    func setPhotoPreviewConnection(_ connection: AVCaptureConnection, enabled: Bool) {
        let reference = PreviewConnectionReference(connection: connection)
        sessionQueue.async {
            guard !self.sharedDeviceTransitionInFlight else { return }
            reference.connection.isEnabled = enabled
        }
    }

    // MARK: - Preview-only read-only sink

    func setPreviewTap(owner: UUID, tap: @escaping @Sendable (CameraPreviewFrame?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.previewOutput.connection(with: .video)?.isEnabled = false
            self.previewTap.setEnabled(false)
            self.previewOwner = owner
            self.previewTap.set(owner: owner, tap: tap)
#if DEBUG
            guard self.developmentPhotoSnapshot == nil else { return }
#endif
            self.session.beginConfiguration()
            self.attachPreviewOutput()
            self.session.commitConfiguration()
            self.updatePreviewConnection()
        }
    }

    func removePreviewTap(owner: UUID) {
        sessionQueue.async { [weak self] in
            guard let self, self.previewOwner == owner else { return }
            self.previewOutput.connection(with: .video)?.isEnabled = false
            self.previewTap.remove(owner: owner)
            self.previewOwner = nil
        }
    }

    /// Only invoked inside the initial configuration, after the recording output
    /// has been attached. Rejection is nonfatal: original Log capture still works.
    private func attachPreviewOutput() {
        guard !session.outputs.contains(where: { $0 === previewOutput }) else { return }
        guard session.canAddOutput(previewOutput) else {
            print("Camera preview: independent output unavailable — showing Log")
            return
        }
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.automaticallyConfiguresOutputBufferDimensions = false
        previewOutput.deliversPreviewSizedOutputBuffers = true
        previewOutput.setSampleBufferDelegate(previewTap, queue: previewTap.queue)
        session.addOutput(previewOutput)
        previewOutput.connection(with: .video)?.isEnabled = false
    }

    /// Advertised formats are valid only after attachment and must be refreshed
    /// after every active lens/format change, including a successful rollback.
    /// Never fall back to 8-bit, nor change the device to satisfy this output.
    private func refreshPreviewFormat() {
        previewFormatReady = false
        guard session.outputs.contains(where: { $0 === previewOutput }),
              let connection = previewOutput.connection(with: .video) else { return }
        connection.isEnabled = false
        let advertised = previewOutput.availableVideoPixelFormatTypes.map {
            UInt32(truncating: $0 as NSNumber)
        }
        guard let format = CameraSampleValidationPolicy.preferredTenBitPixelFormats(from: advertised).first else {
            print("Camera preview: no advertised ten-bit source — showing Log")
            return
        }
        // Preview-sized output is incompatible with explicit width/height keys.
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: format)]
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        guard connection.isVideoRotationAngleSupported(0) else { return }
        connection.videoRotationAngle = 0
        previewFormatReady = true
    }

    private func updatePreviewConnection() {
        let enabled = !defersVideoDeviceWrites && previewOwner != nil && !previewSuspended && isConfigured && session.isRunning
            && previewFormatReady && previewOutput.connection(with: .video) != nil
        // Synchronize delivery invalidation before enabling the connection. The
        // session clock excludes buffered frames from an old lens/start/owner.
        let startAfter = session.synchronizationClock.map { CMClockGetTime($0) } ?? .invalid
        previewTap.setEnabled(enabled, startAfter: startAfter)
        previewOutput.connection(with: .video)?.isEnabled = enabled
    }

    private func suspendPreview(_ suspended: Bool) {
        previewSuspended = suspended
        updatePreviewConnection()
    }

    private var sharedDeviceTransitionInFlight: Bool {
#if DEBUG
        sharedIdleEnabled && (sharedGraph.isBusy || photoLensOwnership.isPending || sharedGraph.actual != sharedGraph.desired)
#else
        false
#endif
    }

    private var defersVideoDeviceWrites: Bool {
#if DEBUG
        return sharedIdleEnabled && (sharedGraph.actual != .video || sharedGraph.desired != .video || sharedGraph.isBusy)
#else
        return false
#endif
    }

    /// Whether the shared idle profile's *exposure* writes must be handed to
    /// Photo's controller instead of the device.
    ///
    /// Deliberately narrower than `defersVideoDeviceWrites`, which is about the
    /// video writers (preview connection, microphone, sensor format, the 180° pin)
    /// and is true for the whole shared idle profile. The exposure applier is the
    /// Photo controller only while one exists: in Video's idle the graph sits on
    /// the very same idle profile with `developmentPhotoController == nil`, and
    /// deferring there handed the intent to a controller that is `nil`, so the ISO
    /// and EV controls moved the readout and left the device untouched. Video ISO
    /// did nothing at all in exactly that state.
    private var defersVideoExposureWrites: Bool {
#if DEBUG
        if sharedDeviceTransitionInFlight { return true }
        return developmentPhotoController != nil
#else
        return false
#endif
    }

    /// Opt-in exposure trace (`--trace-photo-exposure`), sharing the photo trace
    /// file so one pull from the device says which side owned an exposure write:
    /// Photo's controller, or Video's own device writers.
    private func traceVideoExposure(_ event: String) {
        guard CommandLine.arguments.contains("--trace-photo-exposure") else { return }
        let device = activeDevice
        let line = "Video exposure trace: t=\(ProcessInfo.processInfo.systemUptime) event=\(event) "
            + "expMode=\(device?.exposureMode.rawValue ?? -1) ISO=\(device?.iso ?? -1) "
            + "duration=\(device?.exposureDuration.seconds ?? -1) bias=\(device?.exposureTargetBias ?? -1) "
            + "deferred=\(defersVideoExposureWrites) controller=\(developmentPhotoController != nil) "
            + "recordedISO=\(sharedVideoManualISO.map { String($0) } ?? "none")"
        print(line)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-exposure-trace.txt")
        if let data = (line + "\n").data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let file = try? FileHandle(forWritingTo: url) {
                defer { try? file.close() }
                _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
            }
        }
    }

    // MARK: - Setup

    /// Configure the session without blocking the caller's thread.
    ///
    /// Session configuration touches camera hardware and can take hundreds of
    /// milliseconds (longer on first launch or after the app resumes). Calling
    /// this from the main thread with `sessionQueue.sync` froze app launch and
    /// lens switching until the run loop was allowed to spin. `completion` runs
    /// on the main queue with `nil` on success, or the failure to report.
    func configure(completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            let error = self?.performConfigure()
            if let error {
                print("Camera session configuration failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Shared synchronous configure body. MUST be called on `sessionQueue`.
    private func performConfigure() -> Error? {
        // A pending reset is retried even when the session was already configured.
        applyDeferredFrameRateReset()
        guard !isConfigured else { return nil }
        var configError: Error?

        session.beginConfiguration()

        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(
            activeLens.deviceType,
            for: .video,
            position: activeLens.position
        ) else {
            session.commitConfiguration()
            return CameraError.noCameraAvailable
        }

        do {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: sampleBufferQueue)
            audioOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: audioSampleBufferQueue)
            addMicrophoneInputLocked()
            try addDevice(device)
        } catch { configError = error }
        session.commitConfiguration()
        guard configError == nil else { return configError }
        do {
            try configureDevice(device)
            isConfigured = true
            logApertureCapability(for: device, lens: activeLens)
        } catch { return error }

        return nil
    }

    /// Add the microphone input from any thread (idempotent). Audio is optional:
    /// a denied/missing microphone just records video-only. Re-adds the movie
    /// output so it creates the audio connection (mirrors `addDevice`).
    /// Async so the caller (main thread) never blocks on camera/audio hardware;
    /// runs after any pending configure()/start() on sessionQueue.
    func addMicrophoneInput() {
        sessionQueue.async { [weak self] in
            guard let self, !self.microphoneAdded else { return }
            // Permission can land while Photo owns the graph. Attach the optional
            // microphone at Record, never renegotiate the idle sensor format.
            guard !self.defersVideoDeviceWrites else { return }
            guard !self.isRecordingOrPending else {
                self.reportCameraError(CameraError.exposureChangeDuringRecording)
                return
            }
            self.session.beginConfiguration()
            self.addMicrophoneInputLocked()
            if self.microphoneAdded, self.videoOutput.connection(with: .video) != nil {
                self.session.commitConfiguration()
                do {
                    if let device = self.activeDevice {
                        try self.configureDevice(device, applyDefaultExposure: false)
                    }
                }
                catch {
                    self.isConfigured = false
                    self.reportCameraError(error)
                }
            } else {
                self.session.commitConfiguration()
            }
        }
    }

    /// Add the microphone input within an active session configuration.
    ///
    /// Audio is only reported as configured when the audio *output* actually
    /// attaches: a take with `microphoneAdded == true` but no audio output could
    /// never deliver PCM, and the recorder would then fail a healthy video-only
    /// capture as a "configured microphone produced no audio" defect. When the
    /// output cannot attach, the input is rolled back so the session is left
    /// cleanly video-only.
    private func addMicrophoneInputLocked() {
        guard !microphoneAdded,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        switch CameraMicrophoneAttachmentPolicy.plan(audioOutputCanAttach: session.canAddOutput(audioOutput)) {
        case .rollbackInput:
            // Leave the session video-only rather than half-configured. Audio
            // will be re-attempted by the next addMicrophoneInput() call.
            session.removeInput(input)
        case .configureAudio:
            audioOutput.setSampleBufferDelegate(sampleBufferRecorder, queue: audioSampleBufferQueue)
            session.addOutput(audioOutput)
            microphoneInput = input
            microphoneAdded = true
        }
    }

    private func addDevice(_ device: AVCaptureDevice) throws {
        // Remove the existing video input FIRST. A session (with a movie output
        // attached) can't accept a second video input, so canAddInput() would
        // fail on every lens switch while the old input is still present.
        if let existing = videoDeviceInput {
            session.removeInput(existing)
            videoDeviceInput = nil
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
        videoDeviceInput = input

        // Re-add the video data output after input swaps to refresh the connection.
        session.removeOutput(videoOutput)
        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)
    }

    /// Samples remain sensor-coded at 3840x2160; the MOV track matrix rotates
    /// display to the orientation the device was held in at recording start
    /// (see `CameraSampleValidationPolicy.deliveryGeometry`). Front-camera movies
    /// are intentionally unmirrored.
    private func configureRawLandscapeRecordingConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        if #available(iOS 17.0, *) {
            let supportsRawLandscapeAngle = connection.isVideoRotationAngleSupported(0)
            if supportsRawLandscapeAngle { connection.videoRotationAngle = 0 }
#if DEBUG
            print("Camera data-output orientation: requested=0°, supported=\(supportsRawLandscapeAngle), " +
                  "applied=\(connection.videoRotationAngle)°")
#endif
        }
    }

    /// Coordinator updates arrive on main. Remember the last angle associated
    /// with a real four-way hold, so pointing the phone flat doesn't unexpectedly
    /// flip the next take. Cache writes stay on the session queue.
    private func configureCaptureRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        captureRotationState = CameraCaptureRotationPolicy()
#if DEBUG
        logOrientationDiagnostics(for: device, coordinator: coordinator)
#endif
        let deviceID = device.uniqueID
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                  options: [.initial, .new]) { [weak self] _, change in
            guard let angle = change.newValue, angle.isFinite else { return }
            Self.withPhysicalOrientation { [weak self] orientation in
                guard orientation.isPhysicalHold else { return }
                self?.sessionQueue.async { [weak self] in
                    guard let self, self.rotationCoordinator?.device?.uniqueID == deviceID else { return }
                    _ = self.captureRotationState.snapshot(for: orientation, liveAngle: angle)
                }
            }
        }
    }

    private func captureRotationAngle(for orientation: CameraSampleValidationPolicy.DeliveryOrientation) -> CGFloat? {
        captureRotationState.snapshot(for: orientation,
            liveAngle: rotationCoordinator?.videoRotationAngleForHorizonLevelCapture)
    }

#if DEBUG
    /// Device-only evidence for the per-camera rotation contract. The front
    /// camera's native sensor orientation differs from the rear's, so every
    /// hard-coded angle must be checked against the platform's own value.
    private func logOrientationDiagnostics(for device: AVCaptureDevice,
                                           coordinator: AVCaptureDevice.RotationCoordinator) {
        func describe(_ connection: AVCaptureConnection?) -> String {
            guard let connection else { return "none" }
            let supported = [0.0, 90.0, 180.0, 270.0].filter { connection.isVideoRotationAngleSupported($0) }
            return "applied=\(connection.videoRotationAngle), mirrored=\(connection.isVideoMirrored), " +
                "autoMirror=\(connection.automaticallyAdjustsVideoMirroring), supported=\(supported)"
        }
        let portraitAngle: String
        if #available(iOS 27.0, *) {
            portraitAngle = "\(coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait))"
        } else {
            portraitAngle = "unavailable"
        }
        let format = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        print("Camera orientation diagnostics: position=\(device.position.rawValue), " +
              "format=\(dimensions.width)x\(dimensions.height), " +
              "coordinatorCapture=\(coordinator.videoRotationAngleForHorizonLevelCapture), " +
              "coordinatorPreview=\(coordinator.videoRotationAngleForHorizonLevelPreview), " +
              "relativeToPortrait=\(portraitAngle), records[\(describe(videoOutput.connection(with: .video)))], " +
              "previewSource[\(describe(previewOutput.connection(with: .video)))]")
    }
#endif

    /// Transfer only the Sendable orientation value across the main boundary,
    /// not the queue-confined session object.
    private static func withPhysicalOrientation(
        _ completion: @escaping @Sendable (CameraSampleValidationPolicy.DeliveryOrientation) -> Void
    ) {
        DispatchQueue.main.async {
            let orientation = MainActor.assumeIsolated { captureDeliveryOrientation() }
            completion(orientation)
        }
    }

    /// Only called from the main-thread recording/debug entry points. Never
    /// synchronously wait for main from sessionQueue (main may wait for session).
    @MainActor
    private static func captureDeliveryOrientation() -> CameraSampleValidationPolicy.DeliveryOrientation {
#if canImport(UIKit)
        return CameraSampleValidationPolicy.DeliveryOrientation(
            deviceOrientationRawValue: UIDevice.current.orientation.rawValue)
#else
        return .unknown
#endif
    }

    /// Start the accelerometer-backed orientation readings once so
    /// `UIDevice.current.orientation` reports the physical hold instead of
    /// `unknown`. The session keeps them alive for the app's lifetime, so there
    /// is no matching `endGeneratingDeviceOrientationNotifications`.
    private func beginDeviceOrientationNotificationsIfNeeded() {
#if canImport(UIKit)
        guard !deviceOrientationNotificationsStarted else { return }
        deviceOrientationNotificationsStarted = true
        DispatchQueue.main.async {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
#endif
    }

    private func configureDevice(_ device: AVCaptureDevice, applyDefaultExposure: Bool = true) throws {
        cancelZoomOnQueue()
        acceptedPixelFormats = []
        acceptedVideoSettings = [:]
        guard #available(iOS 26.0, *) else { throw CameraError.appleLog2NotSupported }
        // Select for the mode in force. `.standard24` is unchanged; `.daylight60`
        // requires a 60 fps range and is refused rather than downgraded.
        let mode = frameRate
        let orderedFormats = Self.appleLog2CaptureFormats(in: device.formats, mode: mode)
        guard !orderedFormats.isEmpty else {
            throw mode == .daylight60
                ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                : CameraError.appleLog2NotSupported
        }

        var failures: [String] = []
        for format in orderedFormats {
            do {
                try applyCaptureFormat(format, to: device, mode: mode)
            } catch {
                failures.append("\(Self.captureFormatSubtypeDescription(format)): \(error.localizedDescription)")
                continue
            }

            if let rejection = configureDataOutputForActiveFormat(activeFormat: format) {
                failures.append("\(Self.captureFormatSubtypeDescription(format)): \(rejection)")
                print("Camera capture candidate rejected: \(Self.captureFormatSubtypeDescription(format)): \(rejection)")
            } else {
                break
            }
        }
        guard !acceptedPixelFormats.isEmpty, !acceptedVideoSettings.isEmpty else {
            let detail = failures.isEmpty ? "no eligible formats" : failures.joined(separator: "; ")
            throw CameraError.writerUnavailable(detail)
        }

        try device.lockForConfiguration()
        do {
            defer { device.unlockForConfiguration() }
            applyWhiteBalanceLock(device)
            if applyDefaultExposure, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
        activeDevice = device
        zoomLifecycle.cameraChanged()
        if let bounds = zoomBounds(for: device), Double(device.videoZoomFactor) > bounds.maximumDevice {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(bounds.maximumDevice)
            device.unlockForConfiguration()
        }
        publishZoom()
        configureCaptureRotation(for: device)
        apertureCameraRevision &+= 1
        if #available(iOS 27.0, *), selectedLensAperture != nil {
            let capability = Self.apertureCapability(for: device)
            selectedLensAperture = capability.isVariable
                ? CameraAperturePolicy.reconcile(selectedLensAperture, with: capability) : nil
            if selectedLensAperture != nil {
                try applySelectedAperture(on: device, mode: isShutterPriority ? .shutterPriority : .manual)
            }
        }
        configureRawLandscapeRecordingConnection()
        applyRecordingStabilization()
        refreshPreviewFormat()
        updatePreviewConnection()
    }

    // MARK: - Recording stabilization

    /// Extreme means Apple's extended cinematic mode, not a proprietary algorithm.
    private static func avStabilizationMode(_ mode: CameraStabilizationMode) -> AVCaptureVideoStabilizationMode {
        switch mode {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .extreme: return .cinematicExtended
        }
    }

    private func stabilizationCapability() -> CameraStabilizationPolicy.Capability {
        guard let device = activeDevice, let connection = videoOutput.connection(with: .video) else {
            return .unavailable
        }
        let modes = Set(CameraStabilizationMode.allCases.filter {
            $0 != .off && device.activeFormat.isVideoStabilizationModeSupported(Self.avStabilizationMode($0))
        })
        return .init(connectionSupported: connection.isVideoStabilizationSupported, formatModes: modes)
    }

    /// Only sessionQueue may write the data-output connection. No capture-format,
    /// exposure, white-balance, metadata or preview-layer changes are made here.
    private func applyRecordingStabilization() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let mode = stabilizationCapability().effectiveMode(for: preferredStabilization)
#if DEBUG
        // Cinematic and extended-cinematic keep the pipeline ~0.7-1.0 s behind
        // the capture clock, so the first frames of a take are already stale.
        print("Stabilization apply: mode=\(mode.rawValue) activeBefore=\(connection.activeVideoStabilizationMode.rawValue) preferredBefore=\(connection.preferredVideoStabilizationMode.rawValue) supported=\(connection.isVideoStabilizationSupported)")
#endif
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = Self.avStabilizationMode(mode)
        }
    }

    private func stabilizationSnapshot() -> CameraStabilizationSnapshot {
        let ready = isConfigured && session.isRunning
        return CameraStabilizationSnapshot(
            preferred: preferredStabilization,
            capability: ready ? stabilizationCapability() : .unavailable,
            activeRawValue: ready ? videoOutput.connection(with: .video)?.activeVideoStabilizationMode.rawValue : nil,
            cameraRevision: apertureCameraRevision,
            changesAllowed: ready && CameraStabilizationPolicy.canChange(
                recording: recordingActive, starting: recordingStartPending, finishing: recordingFinishing))
    }

    func readStabilizationSnapshot(
        completion: @escaping @MainActor @Sendable (CameraStabilizationSnapshot) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.stabilizationSnapshot()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    func setRecordingStabilization(
        _ mode: CameraStabilizationMode,
        completion: @escaping @MainActor @Sendable (CameraStabilizationSnapshot) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isConfigured, self.session.isRunning,
               CameraStabilizationPolicy.canChange(recording: self.recordingActive,
                starting: self.recordingStartPending, finishing: self.recordingFinishing) {
                self.preferredStabilization = mode
                UserDefaults.standard.set(mode.rawValue, forKey: CameraStabilizationPolicy.preferenceKey)
                self.applyRecordingStabilization()
            }
            let snapshot = self.stabilizationSnapshot()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    /// Re-assert the mode's fixed min/max frame duration. Caller must already
    /// hold the device configuration lock. Verifies the target lies inside
    /// `activeFormat.videoSupportedFrameRateRanges` and throws a distinct error
    /// rather than clamping silently, so a rate the format cannot deliver is
    /// never written.
    private func reassertFrameDuration(on device: AVCaptureDevice, mode: CameraFrameRate) throws {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(mode.fps) && $0.maxFrameRate >= Double(mode.fps)
        }
        guard supported else {
            throw mode == .daylight60
                ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                : CameraError.appleLog2NotSupported
        }
        device.activeVideoMinFrameDuration = mode.frameDuration
        device.activeVideoMaxFrameDuration = mode.frameDuration
    }

    private func applyCaptureFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice,
                                    mode: CameraFrameRate) throws {
        guard #available(iOS 26.0, *) else { throw CameraError.appleLog2NotSupported }
        guard format.supportedColorSpaces.contains(.appleLog2) else {
            throw CameraError.appleLog2NotSupported
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // AVFoundation re-applies whatever custom exposure is installed from
        // inside the frame-duration setters below. The shared idle camera holds
        // the operator's Photo/video exposure intent, and that shutter or ISO is
        // routinely invalid for the incoming Log format and frame duration, so
        // AVFoundation raises NSInvalidArgumentException out of a plain property
        // setter. Swift cannot catch that, so it aborts the process (Device crash
        // report 2026-10-27 21:46: reassertFrameDuration ->
        // _setExposureModeCustomWithLensAperture). Release the custom exposure
        // before the format change; the caller re-establishes its own mode.
        if device.exposureMode != .continuousAutoExposure,
           device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.activeFormat = format
        device.activeColorSpace = .appleLog2
        try reassertFrameDuration(on: device, mode: mode)
    }

    private static func appleLog2CaptureFormats(in formats: [AVCaptureDevice.Format],
                                                mode: CameraFrameRate = .standard24) -> [AVCaptureDevice.Format] {
        guard #available(iOS 26.0, *) else { return [] }
        let candidates = formats.map { format in
            guard CMFormatDescriptionGetMediaType(format.formatDescription) == kCMMediaType_Video else {
                return CameraCaptureFormatPolicy.Candidate(width: 0, height: 0,
                    supportsAppleLog2: false, supports24FPS: false)
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports24FPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 24 && $0.maxFrameRate >= 24
            }
            let supports60FPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 60 && $0.maxFrameRate >= 60
            }
            return CameraCaptureFormatPolicy.Candidate(
                width: dimensions.width, height: dimensions.height,
                supportsAppleLog2: format.supportedColorSpaces.contains(.appleLog2),
                supports24FPS: supports24FPS,
                isTenBitBiPlanar420: {
                    let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    return subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                }(),
                isTenBitBiPlanar422: {
                    let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    return subtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
                        || subtype == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                }(),
                supports60FPS: supports60FPS
            )
        }
        let indexes = mode == .daylight60
            ? CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes(in: candidates)
            : CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: candidates)
        return indexes.map { formats[$0] }
    }

    private static func appleLog2CaptureFormat(in formats: [AVCaptureDevice.Format],
                                               mode: CameraFrameRate = .standard24) -> AVCaptureDevice.Format? {
        appleLog2CaptureFormats(in: formats, mode: mode).first
    }

    /// Whether the device has an eligible 4K Apple Log 2 10-bit format for
    /// `mode`. `.daylight60` requires a range that includes 60; a device without
    /// one is refused rather than silently downgraded to 24.
    private static func captureFormatAvailable(for device: AVCaptureDevice, mode: CameraFrameRate) -> Bool {
        appleLog2CaptureFormat(in: device.formats, mode: mode) != nil
    }

    private static func captureFormatSubtypeDescription(_ format: AVCaptureDevice.Format?) -> String {
        guard let format else { return "no active video format" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let chars: [UInt8] = [
            UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)
        ]
        let printable = chars.allSatisfy { (32...126).contains($0) }
            ? String(bytes: chars, encoding: .ascii) ?? String(format: "0x%08X", subtype)
            : String(format: "0x%08X", subtype)
        return "\(dimensions.width)x\(dimensions.height), subtype \(printable)"
    }

    /// Set the fixed white-balance temperature (Kelvin) for the selected film
    /// stock. Daylight stocks use 5600K; tungsten stocks use 3200K. Locking the
    /// sensor to a fixed temperature (instead of continuous auto WB) keeps the
    /// Apple Log → LUT transform on a consistent white point per stock.
    func setWhiteBalance(temperatureKelvin: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.whiteBalanceTemperature = temperatureKelvin
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                self.applyWhiteBalanceLock(device)
                device.unlockForConfiguration()
            } catch {
                // Non-fatal: leave current white balance if the lock fails.
            }
        }
    }

    /// Lock the device to `whiteBalanceTemperature` if one is set. Caller must
    /// hold the device configuration lock (configureDevice or setWhiteBalance).
    private func applyWhiteBalanceLock(_ device: AVCaptureDevice) {
        guard let kelvin = whiteBalanceTemperature,
              device.isWhiteBalanceModeSupported(.locked) else { return }
        let tint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: kelvin, tint: 0)
        let gains = device.deviceWhiteBalanceGains(for: tint)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    private func configureDataOutputForActiveFormat(activeFormat: AVCaptureDevice.Format) -> String? {
        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes.map {
            UInt32(truncating: $0 as NSNumber)
        }
        let candidates = CameraSampleValidationPolicy.preferredTenBitPixelFormats(from: supportedPixelFormats)
        let pixelFormatList = CameraSampleValidationPolicy.fourCCListDescription(supportedPixelFormats)
        print("Camera output negotiation: active format \(Self.captureFormatSubtypeDescription(activeFormat)); " +
              "advertised pixel formats: \(pixelFormatList); ten-bit candidates: " +
              "\(CameraSampleValidationPolicy.fourCCListDescription(candidates))")
        guard !candidates.isEmpty else {
            return "no advertised ten-bit bi-planar YUV pixel format (output advertises: \(pixelFormatList))"
        }
        var candidateFailures: [String] = []
        let selectedPixelFormat = CameraSampleValidationPolicy.firstUsableTenBitPixelFormat(
            from: supportedPixelFormats
        ) { pixelFormat in
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)]
            if let rejection = configureWriterForDataOutput(pixelFormat: pixelFormat,
                                                            candidates: candidates) {
                candidateFailures.append("\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)): \(rejection)")
                return false
            } else {
                return true
            }
        }
        guard selectedPixelFormat == nil else { return nil }
        return "no advertised ten-bit format could negotiate HEVC Main10 (output advertises: \(pixelFormatList); " +
            "attempts: \(candidateFailures.joined(separator: "; ")))"
    }

    private func configureWriterForDataOutput(pixelFormat: UInt32,
                                              candidates: [UInt32]) -> String? {
        let codecs = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        let codecNames = codecs.map(\.rawValue)
        let codecList = codecNames.isEmpty ? "none" : codecNames.joined(separator: ", ")
        guard #available(iOS 27.0, *) else {
            return "Apple Log 2 writer color tags require iOS 27 (running version is older)"
        }
        let profile = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        let colorProperties = [
            AVVideoLogTransferFunctionKey: AVVideoLogTransferFunction_AppleLog2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        let dimensions = [CameraSampleValidationPolicy.CodedDimensions.landscape4K,
                          CameraSampleValidationPolicy.CodedDimensions.portrait4K]
        var landscapeSettings: [String: Any]?
        for codedSize in dimensions {
            let settings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(
                width: codedSize.width, height: codedSize.height,
                profile: profile, averageBitRate: DeliverySettings.averageBitRate,
                colorProperties: colorProperties
            )
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            guard CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
                codec: settings[AVVideoCodecKey] as? AVVideoCodecType,
                width: (settings[AVVideoWidthKey] as? NSNumber)?.intValue,
                height: (settings[AVVideoHeightKey] as? NSNumber)?.intValue,
                profile: compression[AVVideoProfileLevelKey] as? String,
                expectedProfile: profile
            ) else {
                return "constructed settings are not HEVC Main10 at \(codedSize.width)x\(codedSize.height)"
            }
            let probeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hevc-main10-capability-\(UUID().uuidString).mov")
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: probeURL, fileType: .mov)
            } catch {
                return "could not create a temporary AVAssetWriter capability probe: \(error.localizedDescription)"
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                return "AVAssetWriter.canApply rejected HEVC Main10 \(codedSize.width)x\(codedSize.height) " +
                    "(profile: \(profile), input pixel format: " +
                    "\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)); " +
                    "capture-output MOV codecs (diagnostic only): \(codecList))"
            }
            if codedSize == .landscape4K { landscapeSettings = settings }
        }
        guard let settings = landscapeSettings else {
            return "landscape HEVC Main10 writer settings were not constructed"
        }
        acceptedPixelFormats = [pixelFormat]
        acceptedVideoSettings = settings
        print("Capture writer capability: hvc1 Main10 3840x2160 and 2160x3840; selected pixel format " +
              "\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)); " +
              "advertised ten-bit formats: \(CameraSampleValidationPolicy.fourCCListDescription(candidates)); " +
              "capture-output MOV codecs (diagnostic only): \(codecList)")
        return nil
    }

    // MARK: - Camera Switching

    /// Lenses available on this device (queryable before session configuration).
    var availableLenses: [CameraLens] {
        var lenses: [CameraLens] = []
        if Self.deviceAvailable(.builtInWideAngleCamera, .back) { lenses.append(.wide) }
        if Self.deviceAvailable(.builtInUltraWideCamera, .back) { lenses.append(.ultraWide) }
        if Self.deviceAvailable(.builtInTelephotoCamera, .back) { lenses.append(.telephoto) }
        if Self.deviceAvailable(.builtInWideAngleCamera, .front) { lenses.append(.front) }
        return lenses
    }

    private static func deviceAvailable(
        _ type: AVCaptureDevice.DeviceType,
        _ position: AVCaptureDevice.Position
    ) -> Bool {
        AVCaptureDevice.default(type, for: .video, position: position) != nil
    }

    /// Switch to a specific lens (rear wide/ultrawide/tele, or front).
    ///
    /// Async for the same reason as `configure(completion:)`: swapping the video
    /// input reconfigures capture hardware and must not block the main thread.
    /// `completion` runs on the main queue with `nil` on success.
    func selectCamera(_ lens: CameraLens, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.sharedIdleEnabled, !self.sharedGraph.acceptsIdleControls {
                DispatchQueue.main.async { completion(CameraError.frameRateTransitionInProgress) }; return
            }
            if self.developmentPhotoController != nil || self.developmentPhotoExitCompletion != nil {
                guard let update = self.developmentPhotoUpdate else {
                    DispatchQueue.main.async { completion(CameraError.noCameraAvailable) }
                    return
                }
                let previous = self.activeLens
                DispatchQueue.main.async {
                    self.selectDevelopmentPhotoCamera(lens, previous: previous, update: update, completion: completion)
                }
                return
            }
#endif
            if self.activeLens == lens, self.isConfigured {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            guard !self.isRecordingOrPending else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.exposureChangeDuringRecording) } }
                return
            }
            guard !self.frameRateTransitionPending else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.frameRateTransitionInProgress) } }
                return
            }
            self.cancelZoomOnQueue()
            self.zoomLifecycle.cameraChanged()
            self.publishZoom()
            self.suspendPreview(true)
            defer { self.suspendPreview(false) }
            self.invalidateMetering()
            var switchError: Error?
            let previousDevice = self.activeDevice
            let previousFormat = previousDevice?.activeFormat
            let previousColorSpace = previousDevice?.activeColorSpace
            self.session.beginConfiguration()
            var configurationOpen = true

            guard let device = AVCaptureDevice.default(
                lens.deviceType,
                for: .video,
                position: lens.position
            ) else {
                let error = CameraError.noCameraAvailable
                self.session.commitConfiguration()
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }

            guard #available(iOS 26.0, *),
                  Self.captureFormatAvailable(for: device, mode: self.frameRate) else {
                let error = self.frameRate == .daylight60
                    ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                    : CameraError.appleLog2NotSupported
                self.session.commitConfiguration()
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }

            do {
                try self.addDevice(device)
                self.session.commitConfiguration()
                configurationOpen = false
                try self.configureDevice(device)
                self.activeLens = lens
                self.isConfigured = true
                self.logApertureCapability(for: device, lens: lens)
                // A committed manual focus must either be re-applied to the new
                // device or dropped so the UI can reset to AF through the
                // readback — the panel must never keep saying MF while the new
                // lens auto-focuses (L09).
                self.committedManualFocusLensPosition = CameraManualFocusPolicy.lensPositionAfterLensChange(
                    committed: self.committedManualFocusLensPosition,
                    newDeviceSupportsLock: device.isLockingFocusWithCustomLensPositionSupported)
                if let position = self.committedManualFocusLensPosition {
                    self.applyLockedFocus(position, on: device)
                }
            } catch {
                let originalError = error
                switchError = originalError
                if configurationOpen {
                    self.session.commitConfiguration()
                    configurationOpen = false
                }
                // Re-adding an input resets its frame durations, so restore
                // the prior capture configuration before committing rollback.
                if let previousDevice {
                    self.session.beginConfiguration()
                    var rollbackError: Error?
                    var previousDeviceRestored = false
                    do {
                        try self.addDevice(previousDevice)
                        if let previousFormat, let previousColorSpace {
                            do {
                                try previousDevice.lockForConfiguration()
                                defer { previousDevice.unlockForConfiguration() }
                                previousDevice.activeFormat = previousFormat
                                previousDevice.activeColorSpace = previousColorSpace
                                // Restore the mode's own target, not the stale
                                // durations left over from the previous device.
                                try self.reassertFrameDuration(on: previousDevice, mode: self.frameRate)
                            }
                        }
                        previousDeviceRestored = true
                    } catch {
                        rollbackError = error
                    }
                    self.session.commitConfiguration()
                    self.activeDevice = previousDeviceRestored ? previousDevice : nil
                    do { try self.configureDevice(previousDevice, applyDefaultExposure: false) }
                    catch { if rollbackError == nil { rollbackError = error } }
                    if let rollbackError {
                        self.isConfigured = false
                        switchError = CameraError.lensRollbackFailed(original: originalError, rollback: rollbackError)
                    } else {
                        self.isConfigured = true
                        self.logApertureCapability(for: previousDevice, lens: self.activeLens)
                    }
                } else {
                    self.activeDevice = nil
                    self.isConfigured = false
                }
            }

            self.publishZoom()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(switchError) } }
        }
    }

    // MARK: - Zoom

    private func zoomBounds(for device: AVCaptureDevice) -> CameraZoomPolicy.Bounds? {
        let multiplier: Double
        if #available(iOS 18.0, *) {
            multiplier = Double(device.displayVideoZoomFactorMultiplier)
        } else {
            multiplier = 1 // iOS 17: explicitly per-lens, never a fabricated global ratio.
        }
        // Use the installed physical capture device, not a lens selection that
        // may still be pending while the session reconfigures or rolls back.
        let displayCeiling: Double
        if device.position == .back && device.deviceType == .builtInTelephotoCamera {
            displayCeiling = CameraZoomPolicy.telephotoDisplayCeiling
        } else if device.position == .back && device.deviceType == .builtInWideAngleCamera {
            displayCeiling = CameraZoomPolicy.mainWideDisplayCeiling(multiplier: multiplier)
        } else {
            displayCeiling = CameraZoomPolicy.defaultDisplayCeiling
        }
        return CameraZoomPolicy.bounds(multiplier: multiplier,
                                       effectiveMinimum: Double(device.minAvailableVideoZoomFactor),
                                       effectiveMaximum: Double(device.maxAvailableVideoZoomFactor),
                                       formatMaximum: Double(device.activeFormat.videoMaxZoomFactor),
                                       displayCeiling: displayCeiling)
    }

    func observeZoom(_ observer: @escaping @MainActor @Sendable (CameraZoomSnapshot?) -> Void) {
        sessionQueue.async { [weak self] in
            self?.zoomObserver = observer
            self?.publishZoom()
        }
    }

    private func publishZoom() {
        let snapshot: CameraZoomSnapshot?
        if let device = activeDevice, let bounds = zoomBounds(for: device) {
            let raw = Double(device.videoZoomFactor) * bounds.multiplier
            snapshot = CameraZoomSnapshot(cameraRevision: zoomLifecycle.cameraRevision,
                                          displayFactor: min(max(raw, bounds.minimumDisplay), bounds.maximumDisplay),
                                          minimumDisplayFactor: bounds.minimumDisplay,
                                          maximumDisplayFactor: bounds.maximumDisplay,
                                          isRamping: device.isRampingVideoZoom,
                                          isPerLens: {
                                            if #available(iOS 18.0, *) { return false }
                                            return true
                                          }(),
                                          displayMultiplier: bounds.multiplier)
        } else { snapshot = nil }
        if let zoomObserver {
            DispatchQueue.main.async { MainActor.assumeIsolated { zoomObserver(snapshot) } }
        }
    }

    /// Every UI source sends displayed magnification and the snapshot's revision.
    func setDisplayZoom(_ factor: Double, revision: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self, self.zoomLifecycle.cameraRevision == revision,
                  let device = self.activeDevice, let bounds = self.zoomBounds(for: device),
                  let requestedTarget = bounds.target(factor) else { return }
#if DEBUG
            let target = self.developmentPhotoSnapshot != nil ? 1.0 : requestedTarget
#else
            let target = requestedTarget
#endif
            self.cancelZoomOnQueue()
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = CGFloat(target)
            } catch { self.reportCameraError(error) }
            self.publishZoom()
        }
    }

    func beginSlowZoom(_ direction: CameraZoomDirection, revision: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self, self.zoomLifecycle.cameraRevision == revision,
                  let device = self.activeDevice, let bounds = self.zoomBounds(for: device) else { return }
            self.cancelZoomOnQueue()
            #if DEBUG
            guard self.developmentPhotoSnapshot == nil else { self.publishZoom(); return }
#endif
            let endpoint = direction == .in ? bounds.maximumDevice : bounds.minimumDevice
            guard abs(Double(device.videoZoomFactor) - endpoint) > 0.001 else { self.publishZoom(); return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.ramp(toVideoZoomFactor: CGFloat(endpoint), withRate: CameraZoomPolicy.rampRate)
                _ = self.zoomLifecycle.begin(revision: revision)
                self.zoomSamplingGeneration &+= 1
                self.sampleZoom(generation: self.zoomSamplingGeneration, remaining: 600)
            } catch { self.reportCameraError(error) }
            self.publishZoom()
        }
    }

    func endSlowZoom(revision: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self, self.zoomLifecycle.cameraRevision == revision else { return }
            self.cancelZoomOnQueue()
            self.publishZoom()
            self.zoomSamplingGeneration &+= 1
            self.sampleZoom(generation: self.zoomSamplingGeneration, remaining: 20)
        }
    }

    /// Native magnification for the shared idle graph, used by Photo: its zoom is a
    /// software crop applied to both the preview and the still.
    private func resetSharedIdleDeviceZoom(_ device: AVCaptureDevice) {
        guard let bounds = zoomBounds(for: device) else { return }
        let target = max(1.0, bounds.minimumDevice)
        guard abs(Double(device.videoZoomFactor) - target) > 0.001 else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(target)
            device.unlockForConfiguration()
            publishZoom()
        } catch { reportCameraError(error) }
    }

    private func cancelZoomOnQueue() {
        zoomSamplingGeneration &+= 1
        if let device = activeDevice, device.isRampingVideoZoom {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.cancelVideoZoomRamp()
            } catch { reportCameraError(error) }
        }
        _ = zoomLifecycle.end(revision: zoomLifecycle.cameraRevision)
    }

    private func sampleZoom(generation: UInt64, remaining: Int) {
        guard remaining > 0 else { return }
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.zoomSamplingGeneration == generation else { return }
            self.publishZoom()
            if self.activeDevice?.isRampingVideoZoom == true || remaining > 590 {
                self.sampleZoom(generation: generation, remaining: remaining - 1)
            }
        }
    }

    /// Focus the active lens at a normalized device point (0–1).
    func setFocusAndExposurePoint(_ point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, !self.sharedDeviceTransitionInFlight, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus),
                   CameraManualFocusPolicy.allowsAutofocusOnTap(
                       committedLensPosition: self.committedManualFocusLensPosition) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
            } catch { self.reportCameraError(error) }
            // A new metering point means the held exposure is no longer the one
            // the user asked for: drop the pin and re-meter for the new area.
            // Without this, tapping a different part of the scene left the
            // locked exposure untouched.
            self.invalidateMetering()
            if self.isShutterPriority, !self.isRecordingOrPending {
                self.pinShutterToFilm()
            }
        }
    }

    func setPortraitMode(isEnabled: Bool, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            var operationError: Error?
            if let device = self?.activeDevice, !device.activeFormat.supportedDepthDataFormats.isEmpty {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.activeDepthDataFormat = isEnabled
                        ? device.activeFormat.supportedDepthDataFormats.first
                        : nil
                } catch { operationError = error }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
        }
    }

    /// Manual focus: lock the lens at a specific raw lens position (0–1).
    /// Commits the position so a preview tap re-meters exposure without silently
    /// autofocusing and a lens switch can reapply it (L09).
    func setManualFocusPosition(_ lensPosition: Float, expectedRevision: UInt64? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, !self.sharedDeviceTransitionInFlight,
                  expectedRevision == nil || expectedRevision == self.apertureCameraRevision,
                  let device = self.activeDevice,
                  device.isLockingFocusWithCustomLensPositionSupported else { return }
            let clamped = min(max(lensPosition, 0), 1)
            self.committedManualFocusLensPosition = clamped
            self.applyLockedFocus(clamped, on: device)
        }
    }

    /// Lock focus at a raw lens position on the active device. MUST be called on
    /// `sessionQueue`.
    private func applyLockedFocus(_ lensPosition: Float, on device: AVCaptureDevice) {
        guard device.isLockingFocusWithCustomLensPositionSupported else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
        } catch { reportCameraError(error) }
    }

    /// Return the lens to continuous auto-focus and drop the committed MF state.
    func resetAutoFocus() {
        sessionQueue.async { [weak self] in
            guard let self, !self.sharedDeviceTransitionInFlight else { return }
            self.committedManualFocusLensPosition = nil
            guard let device = self.activeDevice,
                  device.isFocusModeSupported(.continuousAutoFocus) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusMode = .continuousAutoFocus
            } catch { self.reportCameraError(error) }
        }
    }

    var isManualFocusSupported: Bool {
        activeDevice?.isLockingFocusWithCustomLensPositionSupported ?? false
    }

    /// Read the committed manual-focus state for the UI. The revision lets the
    /// view discard a snapshot queued before a lens/config change, so the MF
    /// selection can be reset to AF through the readback when a new lens cannot
    /// lock focus (L09). The view model owns the binding integration.
    ///
    /// By default `lensPosition` is the committed locked position (nil = auto).
    /// Pass `includeCurrentPosition: true` to instead read the live
    /// `activeDevice.lensPosition` on the session queue, so enabling manual
    /// focus can lock the lens where it currently is rather than jumping to a
    /// stored default. Both reads stay serialized on `sessionQueue`; the UI
    /// never touches `activeDevice` directly.
    func readManualFocusSnapshot(
        includeCurrentPosition: Bool = false,
        completion: @escaping @MainActor @Sendable (CameraManualFocusSnapshot) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let isSupported = self.activeDevice?.isLockingFocusWithCustomLensPositionSupported ?? false
            let lensPosition: Float?
            if includeCurrentPosition, isSupported, let device = self.activeDevice {
                lensPosition = min(max(device.lensPosition, 0), 1)
            } else {
                lensPosition = self.committedManualFocusLensPosition
            }
            let snapshot = CameraManualFocusSnapshot(
                lensPosition: lensPosition,
                isSupported: isSupported,
                cameraRevision: self.apertureCameraRevision)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }


    /// Current sensor ISO (0 if no active device). Read from any thread for display.
    var currentISO: Float {
        activeDevice?.iso ?? 0
    }

    /// Metered exposure level's offset from the device's target exposure, in EV
    /// (positive = over). This is the live meter the under/over indicator shows
    /// and the shutter-priority stabiliser gates on; it is updated continuously
    /// by the device, including while custom exposure is held.
    var currentExposureTargetOffset: Float {
        activeDevice?.exposureTargetOffset ?? 0
    }

    /// Whether the metered offset is readable (an active device is configured).
    var hasExposureMeter: Bool {
        guard let device = activeDevice else { return false }
        return device.exposureTargetOffset.isFinite
    }

    /// Read all aperture UI state on the serialized camera queue. The revision
    /// lets the view model discard snapshots queued before a lens/config change.
    func readApertureSnapshot(completion: @escaping @MainActor @Sendable (CameraApertureSnapshot) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let capability: CameraAperturePolicy.Capability
            let measured: Float?
            if #available(iOS 27.0, *), let device = self.activeDevice {
                capability = Self.apertureCapability(for: device)
                let aperture = device.lensAperture
                measured = aperture.isFinite && aperture > 0 ? aperture : nil
            } else {
                capability = .unavailable
                measured = nil
            }
            let snapshot = CameraApertureSnapshot(
                capability: capability,
                measured: measured,
                selected: self.selectedLensAperture,
                cameraRevision: self.apertureCameraRevision
            )
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    /// A Gray-World estimate of the scene's neutral white point, read on the
    /// session queue. Used only for the soft stock-selector hint; it is never
    /// applied to the device, so the locked per-stock white balance is untouched.
    struct NeutralSceneEstimate: Equatable, Sendable {
        /// Device-independent correlated colour temperature, in Kelvin.
        let kelvin: Float
        /// Sample time on the session queue, not its eventual main-queue delivery.
        let capturedAt: Date
        /// Configuration revision the reading belongs to, so a snapshot queued
        /// before a lens/format change can be discarded.
        let cameraRevision: UInt64
    }

    /// Read the scene's Gray-World neutral estimate on the session queue.
    ///
    /// Read-only: `grayWorldDeviceWhiteBalanceGains` is valid regardless of the
    /// white-balance mode, so this never unlocks, perturbs, or re-applies white
    /// balance. Returns nil when there is no active device, the gains are
    /// non-finite/non-positive/out of range, or the converted temperature is
    /// implausible — so an unusable reading can never produce a hint.
    func readNeutralSceneEstimate(completion: @escaping @MainActor @Sendable (NeutralSceneEstimate?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            let gains = device.grayWorldDeviceWhiteBalanceGains
            let estimate: NeutralSceneEstimate?
            if StockSelectorHintPolicy.gainsAreUsable(red: Double(gains.redGain),
                                                      green: Double(gains.greenGain),
                                                      blue: Double(gains.blueGain),
                                                      maximumGain: Double(device.maxWhiteBalanceGain)) {
                let kelvin = Double(device.temperatureAndTintValues(for: gains).temperature)
                estimate = StockSelectorHintPolicy.plausibleKelvin.contains(kelvin)
                    ? NeutralSceneEstimate(kelvin: Float(kelvin), capturedAt: Date(),
                                           cameraRevision: self.apertureCameraRevision)
                    : nil
            } else {
                estimate = nil
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(estimate) } }
        }
    }

    @available(iOS 27.0, *)
    private static func apertureCapability(for device: AVCaptureDevice) -> CameraAperturePolicy.Capability {
        let format = device.activeFormat
        return CameraAperturePolicy.capability(
            recommended: format.recommendedLensApertureStops,
            minimum: format.minLensAperture,
            maximum: format.maxLensAperture
        )
    }

    private func logApertureCapability(for device: AVCaptureDevice, lens: CameraLens) {
#if DEBUG
        guard #available(iOS 27.0, *) else {
            print("Camera aperture: lens=\(lens.rawValue), capability=unavailable (iOS < 27)")
            return
        }
        let format = device.activeFormat
        let capability = Self.apertureCapability(for: device)
        let stops = capability.stops.map { String(format: "f/%.1f", $0) }.joined(separator: ",")
        let measured = String(format: "f/%.1f", device.lensAperture)
        print("Camera aperture: lens=\(lens.rawValue), capability=\(capability.isVariable ? "variable" : (stops.isEmpty ? "unavailable" : "fixed")), stops=[\(stops)], range=f/\(String(format: "%.1f", format.minLensAperture))...f/\(String(format: "%.1f", format.maxLensAperture)), measured=\(measured)")
#endif
    }

    /// Current shutter duration in seconds (0 if no active device).
    var currentShutterSeconds: Double {
        activeDevice?.exposureDuration.seconds ?? 0
    }

    /// Device's supported ISO range (fallback 100–3200 before the device is ready).
    var isoRange: ClosedRange<Float> {
        guard let device = activeDevice else { return 100...3200 }
        return device.activeFormat.minISO...device.activeFormat.maxISO
    }

    /// The ISO band the video (Apple Log 2) path can honour on the active camera.
    ///
    /// `isoRange` is the *active* format's, and the shared idle graph holds a
    /// still-capable format that is wider than the recorder's — measured on an
    /// iPhone 18 Pro main camera, 55...12320 still against 55...5280 Log 2, with
    /// the top differing per camera (ultra-wide 3600, telephoto 7680). Reading
    /// `isoRange` in video mode therefore offers ISO the take cannot take.
    var videoISORange: ClosedRange<Float> {
        guard let device = activeDevice else { return 100...3200 }
        let eligible = Self.appleLog2CaptureFormats(in: device.formats, mode: frameRate)
            .map { $0.minISO...$0.maxISO }
        return CameraVideoISORangePolicy.range(forCandidates: eligible) ?? isoRange
    }

    // MARK: - Exposure Controls

    /// Lock exposure at a specific ISO and shutter duration.
    private func setExposureLocked(iso: Float, shutter: CMTime, on device: AVCaptureDevice,
                                   mode: CameraAperturePolicy.ExposureMode? = nil) throws {
        let exposureMode = mode ?? (isShutterPriority ? .shutterPriority : .manual)
        let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        let clampedShutter = min(max(shutter, device.activeFormat.minExposureDuration),
                                 device.activeFormat.maxExposureDuration)
        if #available(iOS 27.0, *), Self.apertureCapability(for: device).isVariable {
            try applyCustomExposureHoldingAperture(on: device, mode: exposureMode,
                                                   duration: clampedShutter, iso: clampedISO)
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: clampedShutter, iso: clampedISO) { _ in }
        // A custom-exposure write can change the active frame durations; re-assert
        // the mode's fixed rate under the same lock.
        try reassertFrameDuration(on: device, mode: frameRate)
    }

    /// Apply a custom exposure without ever changing the lens aperture. A
    /// variable-iris format is asked for the held/selected aperture; if the
    /// format rejects it, fall back to the aperture-agnostic overload so the
    /// metering path can never raise `apertureExposureUnsupported`.
    @available(iOS 27.0, *)
    private func applyCustomExposureHoldingAperture(on device: AVCaptureDevice,
                                                    mode: CameraAperturePolicy.ExposureMode,
                                                    duration: CMTime, iso: Float) throws {
        if let parameters = try? apertureParameters(for: device, mode: mode,
                                                    duration: duration, manualISO: iso) {
            let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                device.activeFormat.supportsExposureModeCustom(
                    lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
            }) {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureModeCustom(lensAperture: parameters.aperture,
                                             duration: parameters.duration, iso: parameters.iso) { _ in }
                try reassertFrameDuration(on: device, mode: frameRate)
            }
            if applied { return }
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: duration, iso: iso) { _ in }
        try reassertFrameDuration(on: device, mode: frameRate)
    }

    /// The aperture a custom-exposure write should hold: the user's explicit
    /// choice, else the device's current value reconciled to a supported stop,
    /// else the format's first stop. `device.lensAperture` reads 0 while the
    /// device is still settling, so it cannot be trusted raw — using it directly
    /// made the recording start throw `apertureExposureUnsupported` and refuse
    /// the take. Returns nil when the active format has no variable iris.
    @available(iOS 27.0, *)
    private func heldAperture(on device: AVCaptureDevice) -> Float? {
        let capability = Self.apertureCapability(for: device)
        guard capability.isVariable else { return nil }
        return selectedLensAperture
            ?? CameraAperturePolicy.reconcile(device.lensAperture, with: capability)
            ?? capability.stops.first
    }

    @available(iOS 27.0, *)
    private func apertureParameters(for device: AVCaptureDevice,
                                    mode: CameraAperturePolicy.ExposureMode,
                                    duration: CMTime,
                                    manualISO: Float) throws -> CameraAperturePolicy.ExposureParameters {
        let capability = Self.apertureCapability(for: device)
        guard !capability.stops.isEmpty else { throw CameraError.apertureUnavailable }
        // Aperture is never auto-driven: without an explicit user choice the
        // current iris value is held. The auto sentinel is never requested
        // because custom exposure rejects it on this hardware.
        let heldAperture = CameraAperturePolicy.reconcile(device.lensAperture, with: capability)
            ?? capability.stops[0]
        let autoISO = AVCaptureDevice.autoISO
        let parameters = CameraAperturePolicy.exposureParameters(
            selectedAperture: selectedLensAperture,
            heldAperture: heldAperture,
            mode: mode,
            manualISO: manualISO,
            autoISO: autoISO,
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            duration: duration
        )
        guard let parameters else { throw CameraError.apertureExposureUnsupported }
        return parameters
    }

    @available(iOS 27.0, *)
    private func applySelectedAperture(on device: AVCaptureDevice,
                                      mode: CameraAperturePolicy.ExposureMode) throws {
        let duration = min(max(filmShutterDuration, device.activeFormat.minExposureDuration),
                           device.activeFormat.maxExposureDuration)
        let parameters = try apertureParameters(for: device, mode: mode,
                                                duration: duration, manualISO: manualExposureISO)
        let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
            device.activeFormat.supportsExposureModeCustom(
                lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
        }) {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(lensAperture: parameters.aperture,
                                         duration: parameters.duration, iso: parameters.iso) { _ in }
        }
        guard applied else { throw CameraError.apertureExposureUnsupported }
    }

    /// Apply a supported aperture or Auto request to the currently negotiated
    /// active format. Every capability read and write runs on sessionQueue.
    func setLensAperture(_ aperture: Float?, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var operationError: Error?
#if DEBUG
            if let controller = self.developmentPhotoController {
                do {
                    try controller.setAperture(aperture)
                    self.selectedLensAperture = aperture
                } catch { operationError = error }
                let result = operationError
                DispatchQueue.main.async { completion(result) }
                return
            }
#endif
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if #available(iOS 27.0, *), let device = self.activeDevice {
                let capability = Self.apertureCapability(for: device)
                guard capability.isVariable,
                      aperture.map({ capability.stops.contains($0) }) ?? true else {
                    operationError = CameraError.apertureUnavailable
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
                    return
                }
                let previous = self.selectedLensAperture
                self.selectedLensAperture = aperture
                do {
                    let mode: CameraAperturePolicy.ExposureMode = self.isShutterPriority ? .shutterPriority : .manual
                    let clampedDuration = min(max(filmShutterDuration, device.activeFormat.minExposureDuration),
                                              device.activeFormat.maxExposureDuration)
                    let parameters = try self.apertureParameters(
                        for: device, mode: mode, duration: clampedDuration,
                        manualISO: self.manualExposureISO)
                    let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                        device.activeFormat.supportsExposureModeCustom(
                            lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
                    }) {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(lensAperture: parameters.aperture,
                                                     duration: parameters.duration, iso: parameters.iso) { _ in }
                    }
                    guard applied else { throw CameraError.apertureExposureUnsupported }
                } catch {
                    self.selectedLensAperture = previous
                    operationError = error
                }
            } else {
                operationError = CameraError.apertureUnavailable
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
        }
    }

    /// The mode's fixed 180° shutter: 1/48s at 24 fps, 1/120s at 60 fps. Every
    /// exposure/manual/start path reads it, so the shutter tracks the mode.
    private var filmShutterDuration: CMTime { frameRate.filmShutterDuration }

    /// Lock exposure to the film standard: 180° shutter (1/48s) at a fixed ISO.
    func lockManualExposure(iso: Float, completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
            var operationError: Error?
            // The video band, never the wider shared idle format's: an ISO the
            // Log 2 take cannot reach must not be offered or pinned.
            let band = self.videoISORange
            let iso = min(max(iso, band.lowerBound), band.upperBound)
#if DEBUG
            // The shared mirror is Video's manual ISO for the take that follows,
            // whether or not Photo's controller applied it to the device now.
            if self.sharedIdleEnabled { self.sharedVideoManualISO = iso }
            if self.defersVideoExposureWrites {
                self.traceVideoExposure("iso-deferred-to-photo")
                self.mirrorSharedExposureIntent(iso: iso)
                if let completion { DispatchQueue.main.async { completion(nil) } }
                return
            }
            self.traceVideoExposure("iso-direct")
#endif
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice {
                do {
                    try self.setExposureLocked(iso: iso, shutter: filmShutterDuration,
                                               on: device, mode: .manual)
                    self.manualExposureISO = iso
                    self.isShutterPriority = false
                }
                catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// Switch to continuous auto exposure (default).
    func setAutoExposure(completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
#if DEBUG
            if self.sharedIdleEnabled { self.sharedVideoManualISO = nil }
            if self.defersVideoExposureWrites {
                self.traceVideoExposure("auto-deferred-to-photo")
                self.mirrorSharedExposureIntent(iso: nil)
                if let completion { DispatchQueue.main.async { completion(nil) } }
                return
            }
#endif
            var operationError: Error?
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice, device.isExposureModeSupported(.continuousAutoExposure) {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.exposureMode = .continuousAutoExposure
                    self.traceVideoExposure("auto-direct")
                } catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// Lock the current auto-exposure values (AE lock).
    func lockCurrentExposure(completion: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.sharedIdleEnabled { self.sharedVideoManualISO = self.activeDevice?.iso }
            if self.defersVideoExposureWrites {
                self.traceVideoExposure("ae-lock-deferred-to-photo")
                self.mirrorSharedExposureIntent(iso: self.sharedVideoManualISO)
                if let completion { DispatchQueue.main.async { completion(nil) } }
                return
            }
#endif
            var operationError: Error?
            if self.isRecordingOrPending {
                operationError = CameraError.exposureChangeDuringRecording
            } else if let device = self.activeDevice, device.isExposureModeSupported(.autoExpose) {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    device.exposureMode = .autoExpose
                } catch { operationError = error }
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(operationError) } }
            } else if let operationError {
                self.reportCameraError(operationError)
            }
        }
    }

    /// EV compensation applied to the auto-exposure target, in stops.
    ///
    /// Deliberately OUR value, not `AVCaptureDevice.exposureTargetBias`. The 180°
    /// shutter lock drives the device in custom (manual) exposure mode, where the
    /// device's own bias has no effect; worse, every re-meter switches exposure
    /// mode and Apple resets that bias to 0, so reading it back made the control
    /// appear to revert. Compensation is applied by scaling the metered ISO
    /// instead, which survives the shutter-priority re-meter.
    private(set) var exposureBiasEV: Float = 0

    /// Supported EV compensation range, bounded to a film-useful ±3 EV span
    /// (fallback ±3 EV before the device is ready).
    var exposureBiasRange: ClosedRange<Float> {
        guard let device = activeDevice else { return -3...3 }
        return max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3)
    }

    /// Set EV compensation and re-pin the shutter-priority exposure so the change
    /// is visible immediately. No-op in manual ISO mode, where the ISO chooser
    /// drives exposure directly.
    func setExposureBiasEV(_ ev: Float) {
        guard ev.isFinite else { return }
        let range = exposureBiasRange
        let clamped = min(max(ev, range.lowerBound), range.upperBound)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.exposureBiasEV != clamped else { return }
            self.exposureBiasEV = clamped
            if self.defersVideoExposureWrites {
                self.mirrorSharedExposureIntent(iso: self.sharedVideoManualISO)
                return
            }
            guard !self.isRecordingOrPending else { return }
            if self.isShutterPriority, self.pinnedExposure != nil {
                // Retarget a held pin without reopening auto exposure. If initial
                // metering is pending, its callback will use this latest EV.
                self.pinShutterToFilm()
                return
            }
            // Nothing is pinned, so there is no metered ISO to scale: hand the
            // compensation to the phone's own auto exposure. The shared idle
            // profile runs that mode, and an EV control the operator cannot see
            // working is not a control (this was Video's second dead control).
            self.applyDeviceExposureTargetBias()
        }
    }

    /// Hand our compensation to the device's own auto-exposure target.
    private func applyDeviceExposureTargetBias() {
        guard let device = activeDevice, device.maxExposureTargetBias > device.minExposureTargetBias else { return }
        let clamped = min(max(exposureBiasEV, device.minExposureTargetBias), device.maxExposureTargetBias)
        guard abs(device.exposureTargetBias - clamped) > 0.001 else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            self.traceVideoExposure("bias-direct")
            device.setExposureTargetBias(clamped) { _ in }
        } catch { reportCameraError(error) }
    }

    // MARK: - Shutter Priority (180° film shutter)

    /// Lock the shutter to 180° (1/48s at 24fps) and let ISO auto-meter.
    /// AVFoundation has no native shutter-priority mode, so we meter briefly in
    /// continuous-auto, then hold the fixed shutter at the freshly metered ISO.
    /// `refreshShutterPriority()` re-acquires only when no pin is held, so the
    /// periodic tick does not step the preview.
    func enableShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.defersVideoDeviceWrites { self.sharedVideoManualISO = nil; return }
#endif
            guard !self.isRecordingOrPending else { return }
            self.isShutterPriority = true
            self.invalidateMetering()
            self.pinShutterToFilm()
        }
    }

    func disableShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isShutterPriority = false
            self.invalidateMetering()
        }
    }

    /// Re-meter and re-pin the 180° shutter (no-op when shutter priority is off
    /// or while recording — exposure is frozen during a take).
    func refreshShutterPriority() {
        sessionQueue.async { [weak self] in
            guard let self, self.isShutterPriority, !self.isRecordingOrPending else { return }
            self.pinShutterToFilm()
        }
    }

    func onCameraOperationError(_ handler: @escaping @MainActor @Sendable (Error, CameraLens) -> Void) {
        sessionQueue.async { [weak self] in self?.onCameraError = handler }
    }

    private func pinShutterToFilm() {
        guard !defersVideoDeviceWrites, let device = activeDevice else { return }
        let duration = min(max(filmShutterDuration, device.activeFormat.minExposureDuration),
                           device.activeFormat.maxExposureDuration)
        let ev = exposureBiasEV
        // A held pin is corrected from the device's own meter rather than by
        // re-metering: re-metering re-enters auto exposure (the shutter-priority
        // branch writes `AVCaptureDevice.autoISO`), which snapped the preview to
        // the default exposure and back on every 1.5 s tick.
        //
        // `exposureTargetOffset` is the metered level's offset from the target in
        // EV. Measured on device (iPhone 18 Pro, iOS 27): darkening the image two
        // stops drove the offset to about -2.0, so a POSITIVE offset means the
        // image is brighter than the target and the held ISO is scaled by
        // 2^(ev-offset). The deadband keeps a settled pin from being nudged every
        // tick.
        if let pin = pinnedExposure {
            let isEVChange = pin.ev != ev
            let corrected: Float?
            if isEVChange {
                corrected = ExposureStabilizer.retargetedISO(
                    pin: pin, targetEV: ev,
                    minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO)
            } else {
                corrected = ExposureStabilizer.correctedISO(
                    heldISO: pin.iso, meteredOffsetEV: device.exposureTargetOffset, targetEV: ev,
                    minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO)
            }
            guard let corrected else { return }
            // Explicit changes bypass the deadband, not the held-exposure path.
            // Even a clamped ISO must record the new EV to avoid compounding.
            guard isEVChange || abs(log2(corrected / pin.iso)) > ExposureStabilizer.deadbandStops else { return }
            do {
                try setExposureLocked(iso: corrected, shutter: duration, on: device, mode: .manual)
                pinnedExposure = ExposureStabilizer.Pin(iso: corrected, ev: ev,
                                                        meteredISO: pin.meteredISO)
            } catch {
                reportCameraError(error)
            }
            return
        }
        guard !isShutterMeteringPending else { return }
        if #available(iOS 27.0, *), Self.apertureCapability(for: device).isVariable {
            do {
                try applyCustomExposureHoldingAperture(on: device, mode: .shutterPriority,
                                                       duration: duration, iso: manualExposureISO)
            } catch {
                reportCameraError(error)
                return
            }
        } else {
            // Fixed/unavailable iris formats keep their previous auto-meter path.
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard device.isExposureModeSupported(.continuousAutoExposure) else { return }
                device.exposureMode = .continuousAutoExposure
            } catch {
                reportCameraError(error)
                return
            }
        }

        // Pin at the measured ISO after the meter settles. EV remains a software
        // compensation so custom exposure mode does not reset it; explicit iris
        // stays fixed because variable formats never enter full continuous AE.
        let generation = meterGeneration.issue()
        isShutterMeteringPending = true
        sessionQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.meterGeneration.accepts(generation) else { return }
            self.isShutterMeteringPending = false
            guard self.isShutterPriority,
                  !self.isRecordingOrPending,
                  let device = self.activeDevice else { return }
            let latestEV = self.exposureBiasEV
            let meteredISO = device.iso
            let iso: Float
            switch ExposureStabilizer.decide(
                meteredISO: meteredISO, ev: latestEV, current: self.pinnedExposure,
                minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO
            ) {
            case .apply(let target):
                iso = target
            case .hold:
                // Re-freeze the previous pin instead of leaving the device in
                // the auto-exposure state the re-meter briefly entered.
                let held = self.pinnedExposure?.iso ?? device.iso
                guard held.isFinite, held > 0 else {
                    self.reportCameraError(CameraError.exposureMeterUnavailable)
                    return
                }
                iso = held
            }
            do {
                try self.setExposureLocked(iso: iso, shutter: duration,
                                           on: device, mode: .manual)
            } catch {
                self.reportCameraError(error)
                return
            }
            self.pinnedExposure = ExposureStabilizer.Pin(iso: iso, ev: latestEV, meteredISO: meteredISO)
        }
    }

    private func invalidateMetering() {
        meterGeneration.invalidate()
        isShutterMeteringPending = false
        pinnedExposure = nil
    }

    private func reportCameraError(_ error: Error) {
        guard let handler = onCameraError else { return }
        // Attribute queued callbacks to the camera that produced them. A
        // metering failure can already be enqueued on main when a lens switch
        // invalidates its generation, so the receiver must reject old-lens
        // results as well as callbacks that have not fired yet.
        let sourceLens = activeLens
#if DEBUG
        if error.localizedDescription == CameraError.apertureExposureUnsupported.localizedDescription {
            let device = activeDevice
            let format = device?.activeFormat
            let apertureCapability: String
            if #available(iOS 27.0, *), let device {
                let capability = Self.apertureCapability(for: device)
                apertureCapability = capability.isVariable ? "variable" : "fixed/unavailable"
            } else {
                apertureCapability = "unavailable"
            }
            let callStack = Thread.callStackSymbols.prefix(10).joined(separator: " <- ")
            print("Aperture error provenance: path=reportCameraError, lens=\(sourceLens.rawValue), " +
                  "device=\(device?.deviceType.rawValue ?? "nil"), position=\(device.map { String(describing: $0.position) } ?? "nil"), " +
                  "format=\(format.map { String(describing: ObjectIdentifier($0)) } ?? "nil"), " +
                  "capability=\(apertureCapability), selected=\(selectedLensAperture.map { String(describing: $0) } ?? "Auto"), " +
                  "iso=\(device?.iso.description ?? "nil"), shutter=\(device?.exposureDuration.seconds.description ?? "nil"), " +
                  "stack=\(callStack)")
        }
#endif
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(error, sourceLens) } }
    }

    // MARK: - Frame-rate mode (session-only daylight 60 fps)

    /// The capture state restored when a frame-rate transition must roll back.
    private struct FrameRateSnapshot {
        let mode: CameraFrameRate
        let format: AVCaptureDevice.Format
        let colorSpace: AVCaptureColorSpace
        let acceptedPixelFormats: Set<UInt32>
        let acceptedVideoSettings: [String: Any]
        let isShutterPriority: Bool
        let pinnedExposure: ExposureStabilizer.Pin?
        let exposureMode: AVCaptureDevice.ExposureMode
        let exposureDuration: CMTime
        let iso: Float
    }

    /// Arm or disarm the session-only frame-rate mode.
    ///
    /// Atomic: the runtime mode changes only after a successful preflight, format
    /// application and data-output negotiation. Any failure restores the previous
    /// format, output and exposure state and leaves the mode unchanged, so an
    /// armed mode is never silently downgraded. Refused while a take is pending,
    /// active or draining, and while another transition is in flight.
    func setFrameRate(_ mode: CameraFrameRate,
                      completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let generation = self.frameRateTransitionGeneration
            func finish(_ error: Error?) {
                self.completeFrameRateTransition(generation: generation, error: error, completion: completion)
            }
            guard !self.frameRateTransitionPending else {
                finish(CameraError.frameRateTransitionInProgress)
                return
            }
            guard CameraFrameRatePolicy.canChange(recording: self.recordingActive,
                                                  starting: self.recordingStartPending,
                                                  finishing: self.recordingFinishing) else {
                finish(CameraError.exposureChangeDuringRecording)
                return
            }
            guard self.isConfigured, self.activeDevice != nil else {
                finish(CameraError.noCameraAvailable)
                return
            }
            guard mode != self.frameRate else {
                finish(nil)
                return
            }
            if self.defersVideoDeviceWrites {
                guard mode == .standard24 || Self.captureFormatAvailable(for: self.activeDevice!, mode: mode) else {
                    finish(CameraError.daylight60Unsupported(CameraError.daylight60Reason)); return
                }
                self.frameRate = mode
                finish(nil)
                return
            }
            self.frameRateTransitionPending = true
            let error = self.applyFrameRateMode(mode)
            self.frameRateTransitionPending = false
            finish(error)
        }
    }

    /// Whether the active (or default) camera advertises a 4K Apple Log 2 10-bit
    /// format whose ranges include 60 fps. Read at arm time so the control is
    /// disabled on an ineligible device instead of failing a take.
    func supportsDaylight60(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device = self.activeDevice ?? AVCaptureDevice.default(
                self.activeLens.deviceType, for: .video, position: self.activeLens.position)
            let supported = device.map {
                Self.appleLog2CaptureFormat(in: $0.formats, mode: .daylight60) != nil
            } ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(supported) } }
        }
    }

    /// Queue the session-boundary reset back to `.standard24`. Applied at once
    /// when no take is in flight; otherwise deferred until the active take
    /// drains, so the enqueued job keeps its captured policy. The next
    /// configure/start also applies it, even when the drain was interrupted.
    func resetFrameRateForNextSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingFrameRateReset = true
            // Invalidate any in-flight transition completion so it cannot restore
            // the armed mode on the next foreground session.
            self.frameRateTransitionGeneration &+= 1
            self.applyDeferredFrameRateReset()
        }
    }

    /// Apply a queued session-boundary reset once no take is in flight. MUST run
    /// on `sessionQueue`.
    private func applyDeferredFrameRateReset() {
        guard pendingFrameRateReset else { return }
        guard CameraFrameRatePolicy.canChange(recording: recordingActive,
                                              starting: recordingStartPending,
                                              finishing: recordingFinishing) else { return }
        guard frameRate != .standard24 else {
            pendingFrameRateReset = false
            return
        }
        if defersVideoDeviceWrites {
            frameRate = .standard24
        } else if isConfigured, activeDevice != nil {
            if let error = applyFrameRateMode(.standard24) {
                // Keep the reset pending. A failed reset must never admit a new
                // take at 60fps while the foreground UI has already reset to 24.
                isConfigured = false
                acceptedPixelFormats = []
                acceptedVideoSettings = [:]
                reportCameraError(CameraError.captureRecoveryRequired(error.localizedDescription))
                return
            }
        } else {
            frameRate = .standard24
        }
        pendingFrameRateReset = false
    }

    /// Apply `mode` to the active device. MUST run on `sessionQueue` with no take
    /// in flight. Returns nil on success; on any failure the previous format,
    /// data-output negotiation and exposure state are restored and the mode is
    /// left unchanged.
    private func applyFrameRateMode(_ mode: CameraFrameRate) -> Error? {
        guard let device = activeDevice else { return CameraError.noCameraAvailable }
        guard #available(iOS 26.0, *) else { return CameraError.appleLog2NotSupported }
        guard let format = Self.appleLog2CaptureFormat(in: device.formats, mode: mode) else {
            return mode == .daylight60
                ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                : CameraError.appleLog2NotSupported
        }
        let snapshot = makeFrameRateSnapshot()
        do {
            try CameraFrameRatePolicy.applyTransition(format: {
                try applyCaptureFormat(format, to: device, mode: mode)
                acceptedPixelFormats = []
                acceptedVideoSettings = [:]
                if let rejection = configureDataOutputForActiveFormat(activeFormat: format) {
                    throw CameraError.writerUnavailable(rejection)
                }
                frameRate = mode
            }, exposure: {
                // Exposure is part of the transaction, not fire-and-forget AE.
                // Keep the currently metered/manual ISO and pin the new shutter;
                // the ordinary shutter-priority loop can then correct held ISO.
                try repinExposureForCurrentMode()
                try device.lockForConfiguration()
                applyWhiteBalanceLock(device)
                device.unlockForConfiguration()
            }, rollback: {
                restoreFrameRateSnapshot(snapshot)
            })
        } catch { return error }
        applyRecordingStabilization()
        refreshPreviewFormat()
        updatePreviewConnection()
        return nil
    }

    private func makeFrameRateSnapshot() -> FrameRateSnapshot? {
        guard let device = activeDevice else { return nil }
        return FrameRateSnapshot(mode: frameRate,
                                 format: device.activeFormat,
                                 colorSpace: device.activeColorSpace,
                                 acceptedPixelFormats: acceptedPixelFormats,
                                 acceptedVideoSettings: acceptedVideoSettings,
                                 isShutterPriority: isShutterPriority,
                                 pinnedExposure: pinnedExposure,
                                 exposureMode: device.exposureMode,
                                 exposureDuration: device.exposureDuration,
                                 iso: device.iso)
    }

    /// Restore a saved capture state after a failed transition. MUST run on
    /// `sessionQueue`.
    private func restoreFrameRateSnapshot(_ snapshot: FrameRateSnapshot?) {
        guard let snapshot else { return }
        frameRate = snapshot.mode
        isShutterPriority = snapshot.isShutterPriority
        pinnedExposure = snapshot.pinnedExposure
        acceptedPixelFormats = snapshot.acceptedPixelFormats
        acceptedVideoSettings = snapshot.acceptedVideoSettings
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = snapshot.format
            device.activeColorSpace = snapshot.colorSpace
            try reassertFrameDuration(on: device, mode: snapshot.mode)
            applyWhiteBalanceLock(device)
        } catch {
            isConfigured = false
            acceptedPixelFormats = []
            acceptedVideoSettings = [:]
            reportCameraError(CameraError.captureRecoveryRequired(error.localizedDescription))
            return
        }
        do {
            if snapshot.exposureMode == .custom {
                try setExposureLocked(iso: snapshot.iso, shutter: snapshot.exposureDuration,
                                      on: device, mode: .manual)
            } else {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.exposureMode = snapshot.exposureMode
                try reassertFrameDuration(on: device, mode: snapshot.mode)
            }
        } catch {
            isConfigured = false
            acceptedPixelFormats = []
            acceptedVideoSettings = [:]
            reportCameraError(CameraError.captureRecoveryRequired(error.localizedDescription))
            return
        }
        if let rejection = configureDataOutputForActiveFormat(activeFormat: snapshot.format) {
            // Negotiation really failed: don't resurrect stale accepted settings.
            isConfigured = false
            acceptedPixelFormats = []
            acceptedVideoSettings = [:]
            reportCameraError(CameraError.captureRecoveryRequired(rejection))
        }
        applyRecordingStabilization()
        refreshPreviewFormat()
        updatePreviewConnection()
    }

    /// Re-pin the fixed 180° shutter for the current mode after a format change.
    /// Both auto-ISO and manual-ISO use the fixed shutter. Failures propagate to
    /// the transition so its completion cannot publish a false success.
    private func repinExposureForCurrentMode() throws {
        guard let device = activeDevice else { throw CameraError.noCameraAvailable }
        invalidateMetering()
        let shutter = filmShutterDuration
        guard shutter >= device.activeFormat.minExposureDuration,
              shutter <= device.activeFormat.maxExposureDuration else {
            throw CameraError.writerUnavailable("the format cannot provide the requested 180° shutter")
        }
        let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
        try setExposureLocked(iso: iso, shutter: shutter, on: device, mode: .manual)
        if isShutterPriority {
            pinnedExposure = ExposureStabilizer.Pin(iso: iso, ev: exposureBiasEV, meteredISO: iso)
        } else {
            manualExposureISO = iso
        }
    }

    /// Fence a transition's completion against a later session-boundary reset: a
    /// callback that lands after the reset must not restore the armed mode on the
    /// next foreground session.
    private func completeFrameRateTransition(generation: UInt64, error: Error?,
                                             completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let superseded = self.frameRateTransitionGeneration != generation
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(superseded ? CameraError.frameRateTransitionSuperseded : error)
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording(to url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
#if DEBUG
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.sharedIdleEnabled {
                guard self.sharedGraph.acceptsIdleControls, !self.photoLensOwnership.isPending,
                      !self.isRecordingOrPending else {
                    DispatchQueue.main.async { completion(CameraError.recordingInProgress) }; return
                }
                let epoch = self.sharedGraph.request(.video)
                self.sharedVideoRequest = SharedVideoRequest(epoch: epoch, url: url, completion: completion)
                self.driveSharedGraph()
            } else {
                let reference = CameraOrientationSessionReference(session: self)
                Self.withPhysicalOrientation { orientation in
                    reference.session?.startRecording(to: url, deliveryOrientation: orientation, completion: completion)
                }
            }
        }
#else
        let reference = CameraOrientationSessionReference(session: self)
        Self.withPhysicalOrientation { orientation in
            reference.session?.startRecording(to: url, deliveryOrientation: orientation, completion: completion)
        }
#endif
    }

    private func startRecording(to url: URL,
                                deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation,
                                sharedRequestEpoch: UInt64? = nil,
                                completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        // The take's content begins when the recording exposure takes effect, not
        // when the writer finally confirms it.
        let startRequestedAt = Date()
#if DEBUG
        // Measured on device to size the button's optimistic "starting" state:
        // this is the gap between the user's request and the take really running.
        startPhases = StartPhases(requestedAt: startRequestedAt)
#endif
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if let sharedRequestEpoch, !self.sharedGraph.acceptsVideoRequest(sharedRequestEpoch) {
                DispatchQueue.main.async { completion(CameraSampleBufferRecorderError.cancelled) }; return
            }
            // All early exits (unsupported format, destination or writer) must
            // release the Record request back to idle, not strand the Log graph.
            defer {
                if self.sharedIdleEnabled, !self.recordingStartPending,
                   !self.recordingActive, !self.recordingFinishing {
                    self.returnToSharedIdleIfNeeded()
                }
            }
#endif
            self.invalidateMetering()
            guard !self.isRecordingOrPending else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.recordingInProgress) } }
                return
            }
            self.applyDeferredFrameRateReset()
            guard !self.frameRateTransitionPending else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.frameRateTransitionInProgress) } }
                return
            }
            guard !self.pendingFrameRateReset, self.isConfigured else {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    completion(CameraError.captureRecoveryRequired("the capture configuration is not ready"))
                } }
                return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.destinationAlreadyExists) } }
                return
            }
            guard let device = self.activeDevice else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(CameraError.noCameraAvailable) } }
                return
            }
            guard #available(iOS 26.0, *),
                  device.activeColorSpace == .appleLog2,
                  Self.appleLog2CaptureFormat(in: [device.activeFormat], mode: self.frameRate) != nil else {
                let error = self.frameRate == .daylight60
                    ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                    : CameraError.appleLog2NotSupported
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
                return
            }
            guard !self.acceptedVideoSettings.isEmpty, !self.acceptedPixelFormats.isEmpty else {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    completion(CameraError.writerUnavailable("the active format has not been negotiated"))
                } }
                return
            }
            // Snapshot once, before exposure settling. Do not re-read the angle
            // when the first buffer arrives or if the phone turns during the take.
            if self.rotationCoordinator?.device !== device {
                self.configureCaptureRotation(for: device)
            }
            let captureRotationAngle = self.captureRotationAngle(for: deliveryOrientation)
            self.applyRecordingStabilization()
            self.recordingStartPending = true
            self.pendingStartCompletion = completion
            self.recordingGeneration &+= 1
            let generation = self.recordingGeneration
#if DEBUG
            startPhases.queuedAt = Date()
            startPhases.captureClockAtRequest = self.session.synchronizationClock.map { CMClockGetTime($0) }
#endif
            do {
#if DEBUG
                let requestedISO = self.sharedIdleEnabled ? self.sharedRecordingISO(for: device) : device.iso
#else
                let requestedISO = device.iso
#endif
                let iso = min(max(requestedISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                let shutter = min(max(filmShutterDuration, device.activeFormat.minExposureDuration),
                                  device.activeFormat.maxExposureDuration)
                // The completion's sync time is when the requested exposure
                // actually takes effect; frames before it still carry the old
                // exposure, so the recorder drops them.
                // `setExposureModeCustom` stores this handler and calls it on its
                // own queue, so it must be `@Sendable`: it re-enters sessionQueue
                // through a fresh weak capture instead of handing the outer weak
                // `self` (a captured var) to a nested concurrent block.
                let completionHandler: @Sendable (CMTime) -> Void = { [weak self] syncTime in
                    let headOffset = Date().timeIntervalSince(startRequestedAt)
#if DEBUG
                    self?.startPhases.exposureAppliedAt = Date()
#endif
                    guard let session = self else { return }
                    session.sessionQueue.async { [weak session] in
                        guard let session else { return }
#if DEBUG
                        session.videoStartExposureInFlight = false
                        defer { session.driveSharedGraph() }
#endif
                        guard session.recordingGeneration == generation,
                              session.recordingStartPending else { return }
                        // The custom-exposure completion is the last writer of the
                        // device's frame durations, so re-assert the take's fixed
                        // rate after it lands — not only before it. A reassert that
                        // fails refuses the take rather than recording at the
                        // wrong rate.
                        guard let device = session.activeDevice else {
                            session.failPendingStart(CameraError.noCameraAvailable)
                            return
                        }
                        do {
                            try device.lockForConfiguration()
                            defer { device.unlockForConfiguration() }
                            try session.reassertFrameDuration(on: device, mode: session.frameRate)
                        } catch {
                            session.failPendingStart(error)
                            return
                        }
                        session.recordingStateLock.lock()
                        session.recordedStartHeadOffset = headOffset
                        session.recordingStateLock.unlock()
                        session.beginSampleBufferRecording(to: url, generation: generation,
                                                           startAfter: syncTime,
                                                           deliveryOrientation: deliveryOrientation,
                                                           captureRotationAngle: captureRotationAngle)
                    }
                }
#if DEBUG
                self.videoStartExposureInFlight = true
#endif
                if #available(iOS 27.0, *), let heldAperture = self.heldAperture(on: device) {
                    let parameters = CameraAperturePolicy.ExposureParameters(
                        aperture: heldAperture, duration: shutter, iso: iso)
                    let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                        device.activeFormat.supportsExposureModeCustom(
                            lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
                    }) {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(lensAperture: parameters.aperture,
                                                     duration: shutter, iso: iso,
                                                     completionHandler: completionHandler)
                        try self.reassertFrameDuration(on: device, mode: self.frameRate)
                    }
                    if applied {
                        self.recordingAperturePin = CameraAperturePolicy.RecordingPin(
                            aperture: heldAperture, restoresAuto: self.selectedLensAperture == nil)
                    } else {
                        // The format rejected a lens-aperture custom exposure;
                        // start the take with the iris left where it is rather
                        // than refusing to record.
                        try device.lockForConfiguration()
                        do {
                            defer { device.unlockForConfiguration() }
                            device.setExposureModeCustom(duration: shutter, iso: iso,
                                                         completionHandler: completionHandler)
                            try self.reassertFrameDuration(on: device, mode: self.frameRate)
                        }
                    }
                } else {
                    try device.lockForConfiguration()
                    do {
                        defer { device.unlockForConfiguration() }
                        device.setExposureModeCustom(duration: shutter, iso: iso,
                                                     completionHandler: completionHandler)
                        try self.reassertFrameDuration(on: device, mode: self.frameRate)
                    }
                }
            } catch {
#if DEBUG
                self.videoStartExposureInFlight = false
#endif
                self.recordingStartPending = false
                self.pendingStartCompletion = nil
                self.recordingAperturePin = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
            }
        }
    }

    private func beginSampleBufferRecording(to url: URL, generation: UInt64,
                                            startAfter: CMTime = .invalid,
                                            deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation = .unknown,
                                            captureRotationAngle: CGFloat? = nil) {
#if DEBUG
        startPhases.recorderBeganAt = Date()
#endif
        guard let device = activeDevice,
              #available(iOS 26.0, *),
              device.activeColorSpace == .appleLog2,
              Self.appleLog2CaptureFormat(in: [device.activeFormat], mode: frameRate) != nil else {
            recordingStartPending = false
            failPendingStart(frameRate == .daylight60
                ? CameraError.daylight60Unsupported(CameraError.daylight60Reason)
                : CameraError.appleLog2NotSupported)
            return
        }
        guard !acceptedVideoSettings.isEmpty, !acceptedPixelFormats.isEmpty else {
            failPendingStart(CameraError.writerUnavailable("the active format has not been negotiated"))
            return
        }
        // The device can recommend uncompressed `lpcm` for the built-in mic; the
        // original is contracted to AAC, so request it explicitly.
        let audioSettings: [String: Any]? = microphoneAdded
            ? CameraSampleValidationPolicy.aacAudioSettings(
                sampleRate: CameraSampleValidationPolicy.normalizedAACSampleRate(
                    AVAudioSession.sharedInstance().sampleRate),
                averageBitRate: DeliverySettings.aacAverageBitRate)
            : nil
#if DEBUG
        if let audioSettings {
            print("HEVC Log2 audio settings: \(String(describing: audioSettings)); " +
                  "recommended=\(String(describing: audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)))")
        }
#endif
        guard recorderCompletionBridge.begin(epoch: generation) else {
            failPendingStart(CameraError.recordingInProgress)
            return
        }
        let callbackContext = CameraSessionRecorderCallbackContext(session: self, queue: sessionQueue)
#if DEBUG
        let preservationProbeEnabled = debugSmokeURL == url
#else
        let preservationProbeEnabled = false
#endif
        sampleBufferRecorder.begin(
            to: url,
            videoSettings: acceptedVideoSettings,
            audioSettings: audioSettings,
            acceptedPixelFormats: acceptedPixelFormats,
            metadata: captureMetadataItems(),
            deliveryOrientation: deliveryOrientation,
            captureRotationAngle: captureRotationAngle,
            preservationProbeEnabled: preservationProbeEnabled,
            requiresAudioEvidence: microphoneAdded,
            startAfter: startAfter,
            videoFrameDuration: frameRate.fallbackVideoSampleDuration,
            onStarted: { [callbackContext] error in
                callbackContext.enqueueStarted(CameraRecorderErrorBox(error), generation: generation)
            },
            onFinished: { [callbackContext] result in
                callbackContext.enqueueFinished(CameraRecorderResultBox(result), generation: generation)
            }
        )
    }

    fileprivate func recorderStartedOnSessionQueue(_ error: Error?, generation: UInt64) {
        guard recordingGeneration == generation, recordingStartPending,
              recorderCompletionBridge.acceptsStarted(epoch: generation) else { return }
        recordingStartPending = false
#if DEBUG
        startPhases.printLatency(error: error)
        // Same value the REC timer is back-dated by: proving it is populated is
        // what ties the measured head loss to what the timer uses.
        print("Recording head offset: \(Int(recordedStartHeadOffset * 1000))ms")
        startPhases = StartPhases()
#endif
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        recordingActive = error == nil
        refreshPublicRecordingState()
        if let completion {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    fileprivate func recorderFinishedOnSessionQueue(_ result: Result<URL, Error>, generation: UInt64) {
        guard let shouldNotifyForEpoch = recorderCompletionBridge.consumeTerminal(epoch: generation) else { return }
        let hadStarted = recordingActive
        let shouldNotifyFinish = shouldNotifyForEpoch && hadStarted && recordingGeneration == generation
        recordingActive = false
        recordingFinishing = false
        recordingStartPending = false
        restoreAutomaticApertureAfterRecording()
        refreshPublicRecordingState()
        // A session-boundary reset queued while the take was draining lands now,
        // so the next foreground session starts at the default mode.
        applyDeferredFrameRateReset()
        if stopSessionAfterRecording {
            stopSessionAfterRecording = false
            if session.isRunning { session.stopRunning() }
        }
        let completion: Result<RecordingCompletion, Error>
        switch result {
        case .success(let outputURL):
            completion = .success(RecordingCompletion(url: outputURL, warning: nil))
        case .failure(let error):
            // The recorder throws the retained error only when the writer
            // produced a readable, non-empty file, so that URL is exactly the
            // "the movie finished playable" signal the policy wants.
            let retainedURL = CameraRetainedRecordingError.retainedURL(from: error)
            if RecordingCompletionPolicy.shouldPublish(errorExists: true, finishedPlayable: retainedURL != nil),
               let retainedURL {
                completion = .success(RecordingCompletion(url: retainedURL, warning: error,
                                                          retainedOriginal: true))
            } else {
                completion = .failure(error)
            }
        }
#if DEBUG
        returnToSharedIdleIfNeeded()
#endif
        let handler = onRecordingFinished
#if DEBUG
        if let smokeURL = debugSmokeURL {
            debugSmokeURL = nil
            let timedOut = debugSmokeTimedOut
            debugSmokeTimedOut = false
            DispatchQueue.main.async {
                if timedOut {
                    print("HEVC Log2 smoke failed: capture exceeded its timeout")
                } else if case .success(let completion) = completion {
                    print("HEVC Log2 smoke passed: \(completion.url.lastPathComponent)")
                } else if case .failure(let error) = completion {
                    print("HEVC Log2 smoke failed: \(error.localizedDescription)")
                }
                if CommandLine.arguments.contains("--keep-hevc-log2-smoke"),
                   case .success(let recording) = completion {
                    print("HEVC Log2 smoke retained: \(recording.url.path)")
                } else {
                    try? FileManager.default.removeItem(at: smokeURL)
                }
            }
            return
        }
#endif
        guard shouldNotifyFinish else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(completion) } }
    }

    private func failPendingStart(_ error: Error) {
        recordingStartPending = false
#if DEBUG
        startPhases = StartPhases()
#endif
        restoreAutomaticApertureAfterRecording()
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        if let completion {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
#if DEBUG
        returnToSharedIdleIfNeeded()
#endif
    }

    /// Recording pins the measured iris when the user's choice is Auto, then
    /// restores Auto after the writer reaches a terminal state.
    private func restoreAutomaticApertureAfterRecording() {
        guard let pin = recordingAperturePin else { return }
        recordingAperturePin = nil
#if DEBUG
        // Shared idle restores iris via Photo intent, not an ignored Video ACK.
        if sharedIdleEnabled { return }
#endif
        guard CameraAperturePolicy.selectedApertureAfterRecording(pin: pin) == nil else { return }
        guard #available(iOS 27.0, *), let device = activeDevice,
              Self.apertureCapability(for: device).isVariable else { return }
        do {
            let mode: CameraAperturePolicy.ExposureMode = isShutterPriority ? .shutterPriority : .manual
            let duration = min(max(filmShutterDuration, device.activeFormat.minExposureDuration),
                               device.activeFormat.maxExposureDuration)
            let parameters = try apertureParameters(for: device, mode: mode,
                                                    duration: duration, manualISO: manualExposureISO)
            let applied = try CameraAperturePolicy.performIfSupported(parameters, supports: {
                device.activeFormat.supportsExposureModeCustom(
                    lensAperture: $0.aperture, duration: $0.duration, iso: $0.iso)
            }) {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureModeCustom(lensAperture: parameters.aperture,
                                             duration: parameters.duration, iso: parameters.iso) { _ in }
            }
            guard applied else { throw CameraError.apertureExposureUnsupported }
        } catch { reportCameraError(error) }
    }

    /// Shutter speed/angle + ISO at the moment recording starts. The shutter is
    /// locked to 180° (1/48s at 24fps) in manual exposure; auto mode reports its
    /// actual metered value so the metadata stays honest.
    private func captureMetadataItems() -> [AVMetadataItem] {
        guard let device = activeDevice else { return [] }
        let shutterSeconds = device.exposureDuration.seconds
        let angle = Int((shutterSeconds * Double(frameRate.fps) * 360.0).rounded())
        let speed = shutterSeconds > 0 ? Self.fractionString(seconds: shutterSeconds) : "auto"
        return [
            Self.captureItem("shutter-speed", speed),
            Self.captureItem("shutter-angle", "\(angle)"),
            Self.captureItem("capture-iso", "\(Int(device.iso))"),
            Self.captureItem("capture-color-space", Self.captureColorSpaceLabel(device)),
            Self.captureItem("capture-format", Self.captureFormatLabel(device)),
            Self.captureItem("capture-codec", acceptedVideoSettings[AVVideoCodecKey] as? String ?? "unknown")
        ]
    }

    private static func captureColorSpaceLabel(_ device: AVCaptureDevice) -> String {
        if #available(iOS 26.0, *), device.activeColorSpace == .appleLog2 { return "Apple Log 2" }
        return String(describing: device.activeColorSpace)
    }

    private static func captureFormatLabel(_ device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameRate = device.activeVideoMinFrameDuration.seconds > 0
            ? Int((1 / device.activeVideoMinFrameDuration.seconds).rounded()) : 0
        return "\(dimensions.width)x\(dimensions.height)@\(frameRate)fps"
    }

    private static func captureItem(_ key: String, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.filmemulation.\(key)" as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func fractionString(seconds: Double) -> String {
        let reciprocal = (1.0 / seconds).rounded()
        return reciprocal >= 2 ? "1/\(Int(reciprocal))" : String(format: "%.4fs", seconds)
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateMetering()
#if DEBUG
            if self.sharedIdleEnabled {
                self.sharedGraph.request(.idle)
                let request = self.sharedVideoRequest
                self.sharedVideoRequest = nil
                if let request { DispatchQueue.main.async { request.completion(CameraSampleBufferRecorderError.cancelled) } }
                defer { self.driveSharedGraph() }
            }
#endif
            if self.recordingStartPending {
                self.recordingStartPending = false
                self.recordingGeneration &+= 1
                self.failPendingStart(CameraSampleBufferRecorderError.noVideoFrames)
                if let epoch = self.recorderCompletionBridge.activeEpoch {
                    self.recorderCompletionBridge.cancelUserStart(epoch: epoch)
                    self.recordingFinishing = true
                    self.refreshPublicRecordingState()
                    self.sampleBufferRecorder.cancel()
                }
            } else if self.recordingActive {
                self.recordingFinishing = true
                self.refreshPublicRecordingState()
                self.sampleBufferRecorder.stop()
            }
        }
    }

#if DEBUG
    /// Debug-only: grab a single frame from the live camera as a `CVPixelBuffer`
    /// in the same RGBA-half layout the offline renderer decodes, so the debug
    /// single-frame render can feed it straight to pass1.
    ///
    /// Uses a dedicated second video output whose connection stays disabled
    /// except while a frame is requested, so the recorder's `videoOutput` and
    /// delegate are never touched. Only runs when the session is not recording,
    /// and reconfigures nothing but its own output. `completion` runs on
    /// `sessionQueue`.
    func captureDebugFrame(completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        let reference = CameraOrientationSessionReference(session: self)
        Self.withPhysicalOrientation { orientation in
            reference.session?.captureDebugFrame(deliveryOrientation: orientation, completion: completion)
        }
    }

    private func captureDebugFrame(deliveryOrientation: CameraSampleValidationPolicy.DeliveryOrientation,
                                   completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            print("Debug frame: requested configured=\(self.isConfigured) running=\(self.session.isRunning) " +
                  "recording=\(self.isRecordingOrPending) acceptedFormats=\(self.acceptedPixelFormats.count)")
            guard self.isConfigured, self.session.isRunning,
                  !self.isRecordingOrPending,
                  let pixelFormat = self.acceptedPixelFormats.first else {
                print("Debug frame: session unavailable")
                completion(nil)
                return
            }
            guard self.attachDebugFrameOutput(pixelFormat: pixelFormat),
                  let connection = self.debugFrameOutput.connection(with: .video) else {
                print("Debug frame: output could not be attached")
                completion(nil)
                return
            }
            print("Debug frame: output attached, awaiting frame")
            let request = CameraDebugFrameRequest()
            if let device = self.activeDevice, self.rotationCoordinator?.device !== device {
                self.configureCaptureRotation(for: device)
            }
            let captureRotationAngle = self.captureRotationAngle(for: deliveryOrientation)
            connection.isEnabled = true
            self.debugFrameTap.request { [weak self] buffer in
                guard let self else { return }
                // The frame crosses to sessionQueue in the same documented box
                // the other debug hops use; the connection is re-read from the
                // output on that queue instead of capturing the live object.
                let transferred = SendablePixelBuffer(buffer: buffer)
                self.sessionQueue.async {
                    guard request.finish() else { return }
                    self.debugFrameOutput.connection(with: .video)?.isEnabled = false
                    guard let buffer = transferred.buffer else {
                        completion(nil)
                        return
                    }
                    let converted = DebugFrameConverter.rgbaHalfBuffer(from: buffer)
                    if let converted {
                        // The tap can fall back to its advertised format, which
                        // need not be 4K. Only its native aspect is needed here;
                        // the recording path retains strict 4K validation.
                        let coded: CameraSampleValidationPolicy.CodedDimensions =
                            CVPixelBufferGetHeight(buffer) > CVPixelBufferGetWidth(buffer) ? .portrait4K : .landscape4K
                        let turns = CameraSampleValidationPolicy.deliveryQuarterTurns(
                            for: deliveryOrientation, coded: coded, captureRotationAngle: captureRotationAngle)
                        CameraFrozenFrameOrientationPolicy.setQuarterTurns(turns, on: converted)
                    }
                    print("Debug frame: received, converted=\(converted != nil)")
                    completion(converted)
                }
            }
            self.sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard request.finish() else { return }
                self?.debugFrameOutput.connection(with: .video)?.isEnabled = false
                print("Debug frame: timed out waiting for a frame")
                completion(nil)
            }
        }
    }

    /// Add (once) or refresh the debug tap's output. Returns false if the session
    /// refuses the output, leaving the recording path untouched either way.
    private func attachDebugFrameOutput(pixelFormat: UInt32) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !session.outputs.contains(where: { $0 === debugFrameOutput }) {
            guard session.canAddOutput(debugFrameOutput) else { return false }
            debugFrameOutput.alwaysDiscardsLateVideoFrames = true
            debugFrameOutput.setSampleBufferDelegate(debugFrameTap, queue: debugFrameQueue)
            session.addOutput(debugFrameOutput)
        }
        // `availableVideoCVPixelFormatTypes` is only meaningful once the output is
        // part of a session, and setting a format it does not advertise raises
        // NSInvalidArgumentException (a hard crash, not a catchable error). So
        // request the recorder's negotiated format only when the output actually
        // offers it, and otherwise leave the output's own default in place —
        // `DebugFrameConverter` normalises whatever arrives to 64RGBAHalf anyway.
        let available = debugFrameOutput.availableVideoPixelFormatTypes.map {
            UInt32(truncating: $0 as NSNumber)
        }
        print("Debug frame: attach negotiated=\(CameraSampleValidationPolicy.fourCCDescription(pixelFormat)) " +
              "available=\(CameraSampleValidationPolicy.fourCCListDescription(available))")
        if available.contains(pixelFormat) {
            debugFrameOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)
            ]
        }
        if let connection = debugFrameOutput.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            connection.isEnabled = false
        }
        return true
    }

    @MainActor private func selectDevelopmentPhotoCamera(_ lens: CameraLens, previous: CameraLens,
        update: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void,
        completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.activeLens == lens, !self.photoLensOwnership.isPending {
                DispatchQueue.main.async { completion(nil) }; return
            }
            guard let controller = self.developmentPhotoController,
                  let saved = self.developmentPhotoSnapshot,
                  !self.sharedGraph.isBusy,
                  (!self.sharedIdleEnabled || self.sharedGraph.acceptsIdleControls),
                  self.developmentPhotoExitCompletion == nil,
                  let epoch = self.photoLensOwnership.begin() else {
                DispatchQueue.main.async { completion(CameraError.frameRateTransitionInProgress) }
                return
            }
            guard let candidate = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position),
                  let priorDevice = self.activeDevice else {
                _ = self.photoLensOwnership.finish(epoch)
                DispatchQueue.main.async { completion(CameraError.noCameraAvailable) }; return
            }
            self.developmentPhotoLensSwitchPending = true
            self.sharedPhotoIntent = controller.intentSnapshot
            controller.stop { [weak self] in
                guard let self, self.photoLensOwnership.owns(epoch) else { return }
                self.developmentPhotoController = nil
                if self.sharedIdleEnabled, self.sharedGraph.desired != .idle {
                    _ = self.photoLensOwnership.finish(epoch)
                    self.developmentPhotoLensSwitchPending = false
                    DispatchQueue.main.async { completion(CameraSampleBufferRecorderError.cancelled) }
                    self.driveSharedGraph()
                    return
                }
                var failure: Error?
                do {
                    try self.installDevelopmentPhotoCamera(candidate, lens: lens, directory: saved.directory, update: update)
                } catch {
                    failure = error
                    do {
                        try self.installDevelopmentPhotoCamera(priorDevice, lens: previous, directory: saved.directory, update: update)
                    } catch {
                        self.isConfigured = false
                        failure = CameraError.lensRollbackFailed(original: failure!, rollback: error)
                    }
                }
                let disposition = self.photoLensOwnership.finish(epoch)
                self.developmentPhotoLensSwitchPending = false
                let outcome = failure
                DispatchQueue.main.async { completion(outcome) }
                if self.sharedIdleEnabled {
                    self.driveSharedGraph()
                } else if disposition == .exitRequested {
                    let waiters = self.developmentPhotoExitWaiters
                    self.developmentPhotoExitWaiters.removeAll()
                    self.exitDevelopmentPhotoOnQueue { result in waiters.forEach { $0(result) } }
                }
            }
        }
    }

    /// Retain the attached Photo output and running session. One input transaction
    /// replaces the selected physical sensor; no intermediate Log graph is built.
    private func installDevelopmentPhotoCamera(_ device: AVCaptureDevice, lens: CameraLens, directory: URL,
        update: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void) throws {
        guard let output = retainedPhotoOutput,
              session.outputs.contains(where: { $0 === output }) else { throw CameraError.cannotAddOutput }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        let previousInputs = session.inputs.filter { $0.ports.contains(where: { $0.mediaType == .video }) }
        for old in previousInputs { session.removeInput(old) }
        guard session.canAddInput(input) else {
            for old in previousInputs where session.canAddInput(old) { session.addInput(old) }
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)
        videoDeviceInput = input
        session.commitConfiguration()
        try configureNativePhotoDevice(device)
        try startDevelopmentPhotoController(device: device, output: output, directory: directory, update: update)
        activeDevice = device
        activeLens = lens
        apertureCameraRevision &+= 1
        selectedLensAperture = sharedPhotoIntent?.aperture
        configureCaptureRotation(for: device)
        zoomLifecycle.cameraChanged()
        publishZoom()
    }

    private func startDevelopmentPhotoController(device: AVCaptureDevice, output: AVCapturePhotoOutput,
        directory: URL, update: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void) throws {
        let formats = output.availableRawPhotoPixelFormatTypes.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
        guard let pixelFormat = formats.first,
              let dimensions = PhotoCapturePolicy.selectDimensions(candidates:
                device.activeFormat.supportedMaxPhotoDimensions.map { .init(width: Int($0.width), height: Int($0.height)) },
                bayerPixelFormats: formats, pixelFormat: pixelFormat) else {
            throw CameraError.writerUnavailable("This camera does not support native Bayer RAW within the Photo resolution budget")
        }
        let size = CMVideoDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height))
        if output.maxPhotoDimensions.width != size.width || output.maxPhotoDimensions.height != size.height {
            output.maxPhotoDimensions = size
        }
        if output.maxPhotoQualityPrioritization != .speed { output.maxPhotoQualityPrioritization = .speed }
        if let connection = output.connection(with: .video), connection.videoScaleAndCropFactor != 1 {
            connection.videoScaleAndCropFactor = 1
        }
        let controller = DevelopmentPhotoController(device: device, output: output,
            pixelFormat: pixelFormat, dimensions: size, directory: directory,
            queue: sessionQueue, onUpdate: update) { [weak self] message in
                self?.reportDevelopmentPhotoError(CameraError.writerUnavailable(message))
            }
        developmentPhotoController = controller
        try controller.start()
        if let sharedPhotoIntent { try controller.restoreIntent(sharedPhotoIntent) }
        // First entry in a session: the shared exposure controls (a held ISO, the
        // EV compensation) come over from Video, the shutter does not — Photo's
        // idle exposure is the device's own auto exposure with that compensation
        // applied, which is what `mirrorSharedExposureIntent` writes.
        else { mirrorSharedExposureIntent(iso: sharedVideoManualISO) }
    }

    func setDevelopmentPhotoMode(_ enabled: Bool,
        onUpdate: @escaping @MainActor @Sendable (PhotoExposureSnapshot) -> Void,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !enabled {
                self.exitDevelopmentPhotoOnQueue(completion: completion)
                return
            }
            guard DevelopmentPhotoFeature.isAvailable(isDebugBuild: true,
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? ""), self.isConfigured,
                  self.session.isRunning, !self.isRecordingOrPending,
                  !self.frameRateTransitionPending, self.developmentPhotoController == nil,
                  let device = self.activeDevice else {
                DispatchQueue.main.async { completion(.failure(CameraError.writerUnavailable("Photo camera is busy or unavailable"))) }
                return
            }
            // RAW availability is checked on the selected camera after the Photo graph commits.
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DevelopmentPhotos", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let run = DebugPhotoRun(owner: self, device: device, directory: directory) { [weak self] result in
                self?.finishDevelopmentPhotoRestoration(result)
            }
            self.developmentPhotoSnapshot = run
            self.debugPhotoRun = run
            self.cancelZoomOnQueue()
            // Photo framing is a software crop (`photoCropZoom`); the shared idle
            // device stays at its native magnification. A zoom left installed by an
            // earlier take would both change the sensor area the still is cropped
            // from and fail the capture's native-magnification check, which reads to
            // the operator as a shutter that has stopped working.
            self.resetSharedIdleDeviceZoom(device)
            self.invalidateMetering()
            self.isShutterPriority = false
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = try self.configureDebugPhotoGraph(run)
                let formats = output.availableRawPhotoPixelFormatTypes.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
                guard let pixelFormat = formats.first,
                      let dimensions = PhotoCapturePolicy.selectDimensions(candidates:
                        device.activeFormat.supportedMaxPhotoDimensions.map {
                            .init(width: Int($0.width), height: Int($0.height))
                        }, bayerPixelFormats: formats, pixelFormat: pixelFormat) else {
                    throw CameraError.writerUnavailable("No native 12MP-class Bayer format is available")
                }
                let size = CMVideoDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height))
                output.maxPhotoDimensions = size
                output.maxPhotoQualityPrioritization = .speed
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraError.writerUnavailable("Photo session did not start") }
                let controller = DevelopmentPhotoController(device: device, output: output,
                    pixelFormat: pixelFormat, dimensions: size, directory: directory,
                    queue: self.sessionQueue, onUpdate: onUpdate) { [weak self] message in
                        self?.reportDevelopmentPhotoError(CameraError.writerUnavailable(message))
                    }
                self.developmentPhotoController = controller
                self.developmentPhotoUpdate = onUpdate
                try controller.start()
                self.debugPhotoRun = nil
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.developmentPhotoExitCompletion = completion
                self.developmentPhotoController?.stop { }
                self.developmentPhotoController = nil
                self.completeDebugPhotoRun(run, captureFailure: error.localizedDescription)
            }
        }
    }

    private func exitDevelopmentPhotoOnQueue(
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        if photoLensOwnership.requestExit() {
            developmentPhotoExitWaiters.append(completion)
            return
        }
        guard developmentPhotoExitCompletion == nil else {
            developmentPhotoExitWaiters.append(completion)
            return
        }
        guard let run = developmentPhotoSnapshot, let controller = developmentPhotoController else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        developmentPhotoExitCompletion = completion
        controller.stop { [weak self, run] in
            guard let self, self.developmentPhotoSnapshot === run else { return }
            self.developmentPhotoController = nil
            self.debugPhotoRun = run
            self.completeDebugPhotoRun(run, captureFailure: nil)
        }
    }

    private func finishDevelopmentPhotoRestoration(_ result: Result<URL, Error>) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let completion = self.developmentPhotoExitCompletion
            self.developmentPhotoExitCompletion = nil
            let waiters = self.developmentPhotoExitWaiters
            self.developmentPhotoExitWaiters.removeAll()
            self.developmentPhotoController = nil
            if let saved = self.developmentPhotoSnapshot {
                self.activeDevice = saved.device
                self.activeLens = saved.device.position == .front ? .front :
                    (saved.device.deviceType == .builtInUltraWideCamera ? .ultraWide :
                     (saved.device.deviceType == .builtInTelephotoCamera ? .telephoto : .wide))
                self.videoDeviceInput = saved.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                    .first { $0.device.hasMediaType(.video) }
                self.apertureCameraRevision &+= 1
                self.zoomLifecycle.cameraChanged()
                self.publishZoom()
            }
            self.developmentPhotoSnapshot = nil
            DispatchQueue.main.async {
                let outcome = result.map { _ in () }
                completion?(outcome)
                for waiter in waiters { waiter(outcome) }
            }
        }
    }

    private func reportDevelopmentPhotoError(_ error: Error) {
        let handler = onCameraError
        let lens = activeLens
        DispatchQueue.main.async { handler?(error, lens) }
    }

    private func updateDevelopmentPhoto(_ action: @escaping @Sendable (DevelopmentPhotoController) throws -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let controller = self.developmentPhotoController,
                  self.developmentPhotoExitCompletion == nil,
                  !self.sharedDeviceTransitionInFlight else { return }
            do { try action(controller) }
            catch { self.reportDevelopmentPhotoError(error) }
        }
    }

    func setDevelopmentPhotoISO(_ value: Float) {
        updateDevelopmentPhoto { try $0.setISO(value) }
    }

    func setDevelopmentPhotoDuration(_ seconds: Double) {
        updateDevelopmentPhoto { try $0.setDuration(seconds) }
    }

    func setDevelopmentPhotoISOLocked(_ locked: Bool) {
        updateDevelopmentPhoto { try $0.setISOLocked(locked) }
    }

    func setDevelopmentPhotoShutterLocked(_ locked: Bool) {
        updateDevelopmentPhoto { try $0.setShutterLocked(locked) }
    }

    func setDevelopmentPhotoEV(_ value: Float) {
        updateDevelopmentPhoto { try $0.setEV(value) }
    }

    /// Replace the whole exposure intent in one transition. Used when a shooting
    /// mode hands the shared idle graph back: composing the single-value setters
    /// would submit (and acknowledge) one hardware write per property.
    func applyDevelopmentPhotoIntent(iso: Float?, duration: Double?, ev: Float) {
        updateDevelopmentPhoto {
            try $0.restoreIntent(.init(iso: iso, duration: duration, ev: ev, aperture: nil))
        }
    }

    func captureDevelopmentPhoto(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let controller = self.developmentPhotoController,
                  self.developmentPhotoExitCompletion == nil,
                  !self.sharedDeviceTransitionInFlight else {
                DispatchQueue.main.async { completion(.failure(CameraError.writerUnavailable("Photo camera is not ready"))) }
                return
            }
            do { try controller.capture(completion: completion) }
            catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func startDebugPhotoExposureSmoke(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        Task { @MainActor in
            let smoke = DevelopmentPhotoExposureSmoke(session: self)
            await smoke.run(completion: completion)
        }
    }

    func startDebugPhotoRawCapture(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.isRecordingOrPending,
                  !self.frameRateTransitionPending, let device = self.activeDevice else {
                DispatchQueue.main.async { completion(.failure(CameraError.writerUnavailable("Photo RAW P0: camera busy or unavailable"))) }
                return
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotoModeP0", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let run = DebugPhotoRun(owner: self, device: device, directory: directory, completion: completion)
            self.debugPhotoRun = run
            self.cancelZoomOnQueue()
            self.invalidateMetering()
            self.isShutterPriority = false
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try self.writeDebugPhotoEvidence(run)
                let output = try self.configureDebugPhotoGraph(run)
                let formats = output.availableRawPhotoPixelFormatTypes.filter(AVCapturePhotoOutput.isBayerRAWPixelFormat)
                guard let pixelFormat = formats.first,
                      let dimensions = PhotoCapturePolicy.selectDimensions(
                        candidates: device.activeFormat.supportedMaxPhotoDimensions.map {
                            .init(width: Int($0.width), height: Int($0.height))
                        }, bayerPixelFormats: formats, pixelFormat: pixelFormat) else {
                    throw CameraError.writerUnavailable("Photo RAW P0: no Bayer format within the native 12MP-class budget")
                }
                let size = CMVideoDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height))
                output.maxPhotoDimensions = size
                output.maxPhotoQualityPrioritization = .speed
                run.evidence["photoFormat"] = Self.captureFormatSubtypeDescription(device.activeFormat)
                run.evidence["photoDimensions"] = "\(dimensions.width)x\(dimensions.height)"
                run.evidence["photoMinExposureSeconds"] = String(device.activeFormat.minExposureDuration.seconds)
                run.evidence["photoMaxExposureSeconds"] = String(device.activeFormat.maxExposureDuration.seconds)
                run.evidence["photoAEMaxExposureSeconds"] = String(device.activeMaxExposureDuration.seconds)
                run.evidence["bayerFormat"] = String(pixelFormat)
                run.evidence["status"] = "capturing"
                try self.writeDebugPhotoEvidence(run)
                let helper = try CameraPhotoCapture(output: output, pixelFormat: pixelFormat, dimensions: size,
                    directory: directory, queue: self.sessionQueue,
                    timeoutInterval: max(30, device.activeFormat.maxExposureDuration.seconds * 2 + 10)) { [weak self, run] result in
                        guard let self, self.debugPhotoRun === run else { return }
                        let failure = result.failure ?? (result.dngURL == nil ? "missing validated DNG" : nil)
                        self.completeDebugPhotoRun(run, captureFailure: failure)
                    }
                self.debugPhotoCapture = helper
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraError.writerUnavailable("Photo RAW P0: photo session did not start") }
                try helper.start()
            } catch {
                // Every throwing operation occurs before capturePhoto is invoked.
                self.completeDebugPhotoRun(run, captureFailure: error.localizedDescription)
            }
        }
    }

    private func configureDebugPhotoGraph(_ run: DebugPhotoRun) throws -> AVCapturePhotoOutput {
        if session.isRunning { session.stopRunning() }
        let output = retainedPhotoOutput ?? AVCapturePhotoOutput()
        retainedPhotoOutput = output
        suspendPreview(true)
        session.beginConfiguration()
        run.graphChanged = true
        do {
            defer { session.commitConfiguration() }
            for old in session.outputs { session.removeOutput(old) }
            guard session.canSetSessionPreset(.photo) else { throw CameraError.cannotAddOutput }
            session.sessionPreset = .photo
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }
        try configureNativePhotoDevice(run.device)
        return output
    }

    private func configureNativePhotoDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard device.isExposureModeSupported(.continuousAutoExposure),
              Self.debugPhotoDurationSupported(device.activeFormat.maxExposureDuration, device: device) else {
            throw CameraError.writerUnavailable("Photo RAW P0: unsupported photo auto-exposure range")
        }
        // The shared idle profile is always SDR, even when entered from Log2.
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        } else if device.activeFormat.supportedColorSpaces.contains(.P3_D65) {
            device.activeColorSpace = .P3_D65
        } else {
            throw CameraError.writerUnavailable("Photo RAW P0: no neutral photo color space")
        }
        device.videoZoomFactor = 1
        device.exposureMode = .continuousAutoExposure
        device.activeMaxExposureDuration = device.activeFormat.maxExposureDuration
        applyWhiteBalanceLock(device)
    }

    private static func debugPhotoDurationSupported(_ value: CMTime, device: AVCaptureDevice) -> Bool {
        value.isNumeric && value.seconds.isFinite && value.seconds > 0
            && CMTimeCompare(value, device.activeFormat.minExposureDuration) >= 0
            && CMTimeCompare(value, device.activeFormat.maxExposureDuration) <= 0
    }

    private func restoreDebugPhotoGraph(_ run: DebugPhotoRun) throws {
        guard run.graphChanged else { return }
        if session.isRunning { session.stopRunning() }
        try run.device.lockForConfiguration()
        if run.device.isExposureModeSupported(.continuousAutoExposure) {
            run.device.exposureMode = .continuousAutoExposure
        }
        run.device.unlockForConfiguration()
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            for output in session.outputs { session.removeOutput(output) }
            for input in session.inputs where !run.inputs.contains(where: { $0 === input }) { session.removeInput(input) }
            for input in run.inputs where !session.inputs.contains(where: { $0 === input }) {
                guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
                session.addInput(input)
            }
            guard session.canSetSessionPreset(run.preset) else { throw CameraError.cannotAddOutput }
            session.sessionPreset = run.preset
            for output in run.outputs {
                guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
                session.addOutput(output)
            }
            try restoreDebugPhotoDevice(run)
        }
        // A detached output advertises fallback formats. Reconnect and commit
        // the Log2 graph before validating and restoring its original pixel type.
        guard let pixelFormat = run.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber,
              videoOutput.availableVideoPixelFormatTypes.contains(UInt32(truncating: pixelFormat)) else {
            throw CameraError.writerUnavailable("Photo RAW P0: restored graph rejects original video pixel format")
        }
        videoOutput.videoSettings = run.videoSettings
    }

    private func restoreDebugPhotoDevice(_ run: DebugPhotoRun) throws {
        let device = run.device
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard run.format.supportedColorSpaces.contains(run.color) else { throw CameraError.appleLog2NotSupported }
        // A custom Photo ISO may exceed the Video format's range. Drop custom
        // exposure before changing format; restore the saved pins after commit.
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.activeFormat = run.format
        device.activeColorSpace = run.color
        let framesSupported = run.format.videoSupportedFrameRateRanges.contains {
            CMTimeCompare(run.minimumFrame, $0.minFrameDuration) >= 0
                && CMTimeCompare(run.maximumFrame, $0.maxFrameDuration) <= 0
        }
        guard framesSupported, CMTimeCompare(run.minimumFrame, run.maximumFrame) <= 0,
              device.isExposureModeSupported(run.exposureMode),
              device.isWhiteBalanceModeSupported(run.whiteBalanceMode), run.zoom.isFinite,
              run.zoom >= device.minAvailableVideoZoomFactor, run.zoom <= device.maxAvailableVideoZoomFactor else {
            throw CameraError.writerUnavailable("Photo RAW P0: original video settings are no longer supported")
        }
        if CMTimeCompare(run.maximumFrame, device.activeVideoMinFrameDuration) < 0 {
            device.activeVideoMinFrameDuration = run.minimumFrame
            device.activeVideoMaxFrameDuration = run.maximumFrame
        } else {
            device.activeVideoMaxFrameDuration = run.maximumFrame
            device.activeVideoMinFrameDuration = run.minimumFrame
        }
        if run.maximumExposure.isValid {
            guard Self.debugPhotoDurationSupported(run.maximumExposure, device: device) else {
                throw CameraError.writerUnavailable("Photo RAW P0: invalid original AE ceiling")
            }
            device.activeMaxExposureDuration = run.maximumExposure
        } else { device.activeMaxExposureDuration = .invalid }
        device.videoZoomFactor = run.zoom
    }

    private func applyDebugPhotoRestoredControls(_ run: DebugPhotoRun) throws {
        let device = run.device
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Frame-stamped completions must be requested on the committed, running
        // video graph, not while replacing the stopped Photo graph.
        guard run.bias.isFinite, run.bias >= device.minExposureTargetBias, run.bias <= device.maxExposureTargetBias else {
            throw CameraError.writerUnavailable("Photo RAW P0: invalid original exposure bias")
        }
        if device.exposureTargetBias == run.bias {
            run.restorationBarrier.complete(.biasApplied)
            run.evidence["biasRestore"] = "unchanged"
        } else {
            device.setExposureTargetBias(run.bias) { [weak self, run] time in
                self?.sessionQueue.async { [weak self, run] in
                    self?.debugPhotoSettingApplied(.biasApplied, run: run, time: time)
                }
            }
        }
        if run.exposureMode == .custom || run.exposureMode == .locked {
            guard device.isExposureModeSupported(.custom), Self.debugPhotoDurationSupported(run.duration, device: device),
                  run.iso.isFinite, run.iso >= device.activeFormat.minISO, run.iso <= device.activeFormat.maxISO else {
                throw CameraError.writerUnavailable("Photo RAW P0: invalid original custom exposure")
            }
            device.setExposureModeCustom(duration: run.duration, iso: run.iso) { [weak self, run] time in
                self?.sessionQueue.async { [weak self, run] in
                    self?.debugPhotoSettingApplied(.exposureApplied, run: run, time: time)
                }
            }
        } else { device.exposureMode = run.exposureMode }
        if run.whiteBalanceMode == .locked {
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                  [run.gains.redGain, run.gains.greenGain, run.gains.blueGain].allSatisfy({
                      $0.isFinite && $0 >= 1 && $0 <= device.maxWhiteBalanceGain
                  }) else { throw CameraError.writerUnavailable("Photo RAW P0: invalid original WB gains") }
            device.setWhiteBalanceModeLocked(with: run.gains) { [weak self, run] time in
                self?.sessionQueue.async { [weak self, run] in
                    self?.debugPhotoSettingApplied(.whiteBalanceApplied, run: run, time: time)
                }
            }
        } else { device.whiteBalanceMode = run.whiteBalanceMode }
    }

    private func completeDebugPhotoRun(_ run: DebugPhotoRun, captureFailure: String?) {
        guard debugPhotoRun === run, !run.restorationStarted else { return }
        run.restorationStarted = true
        run.captureFailure = captureFailure
        do {
            try restoreDebugPhotoGraph(run)
            isShutterPriority = run.shutterPriority
            if !run.graphChanged {
                run.evidence["restoration"] = "unchanged"
                for step: PhotoCompletionStep in [.graphConfigured, .exposureApplied, .whiteBalanceApplied, .biasApplied] {
                    run.restorationBarrier.complete(step)
                }
                verifyDebugPhotoRestorationIfReady(run)
                return
            }
            run.restorationBarrier.complete(.graphConfigured)
            guard run.shouldRestart, !run.interrupted else {
                throw CameraError.writerUnavailable("Photo experiment interrupted; restored values remain unverified")
            }
            configureRawLandscapeRecordingConnection()
            applyRecordingStabilization()
            refreshPreviewFormat()
            updatePreviewConnection()
            session.startRunning()
            guard session.isRunning else { throw CameraError.writerUnavailable("Restored video session did not start") }
            try applyDebugPhotoRestoredControls(run)
            run.evidence["restoration"] = "awaitingDeviceAcknowledgments"
            try writeDebugPhotoEvidence(run)
            sessionQueue.asyncAfter(deadline: .now() + max(15, run.duration.seconds * 2 + 5)) { [weak self, run] in
                guard let self, self.debugPhotoRun === run else { return }
                run.restorationFailure = "device restoration acknowledgment timed out"
                self.finishDebugPhotoRun(run)
            }
            verifyDebugPhotoRestorationIfReady(run)
        } catch {
            run.restorationFailure = error.localizedDescription
            finishDebugPhotoRun(run)
        }
    }

    private func debugPhotoSettingApplied(_ step: PhotoCompletionStep, run: DebugPhotoRun, time: CMTime) {
        guard debugPhotoRun === run, run.restorationStarted else { return }
        guard !run.interrupted, run.shouldRestart, time.isNumeric, time.seconds.isFinite else {
            run.restorationFailure = "invalid or interrupted device restoration acknowledgment"
            finishDebugPhotoRun(run)
            return
        }
        if step == .exposureApplied, run.exposureMode == .locked {
            do {
                try run.device.lockForConfiguration()
                defer { run.device.unlockForConfiguration() }
                guard run.device.isExposureModeSupported(.locked) else { throw CameraError.appleLog2NotSupported }
                run.device.exposureMode = .locked
            } catch {
                run.restorationFailure = error.localizedDescription
                finishDebugPhotoRun(run)
                return
            }
        }
        run.evidence["ack_\(step)"] = String(time.seconds)
        run.restorationBarrier.complete(step)
        verifyDebugPhotoRestorationIfReady(run)
    }

    private func verifyDebugPhotoRestorationIfReady(_ run: DebugPhotoRun) {
        guard debugPhotoRun === run, run.restorationBarrier.isReady else { return }
        let device = run.device
        let actualGains = device.deviceWhiteBalanceGains
        func near(_ actual: Double, _ expected: Double, floor: Double) -> Bool {
            actual.isFinite && expected.isFinite && abs(actual - expected) <= max(floor, abs(expected) * 0.001)
        }
        let manualExposure = run.exposureMode == .custom || run.exposureMode == .locked
        let exposureMatches = !manualExposure || (
            abs(Double(device.iso) - Double(run.iso)) <= max(1, Double(run.iso) * 0.01)
                && near(device.exposureDuration.seconds, run.duration.seconds, floor: 0.000001))
        let gainsMatch = run.whiteBalanceMode != .locked || (
            near(Double(actualGains.redGain), Double(run.gains.redGain), floor: 0.001)
                && near(Double(actualGains.greenGain), Double(run.gains.greenGain), floor: 0.001)
                && near(Double(actualGains.blueGain), Double(run.gains.blueGain), floor: 0.001))
        let graphMatches = session.inputs.count == run.inputs.count && session.outputs.count == run.outputs.count
            && run.inputs.allSatisfy { old in session.inputs.contains { $0 === old } }
            && run.outputs.allSatisfy { old in session.outputs.contains { $0 === old } }
        run.evidence["restoredISO"] = String(device.iso)
        run.evidence["restoredExposureSeconds"] = String(device.exposureDuration.seconds)
        run.evidence["restoredWBGains"] = "\(actualGains.redGain),\(actualGains.greenGain),\(actualGains.blueGain)"
        run.evidence["restoredExposureMode"] = String(device.exposureMode.rawValue)
        run.evidence["restoredWBMode"] = String(device.whiteBalanceMode.rawValue)
        run.evidence["restoredBias"] = String(device.exposureTargetBias)
        guard !run.interrupted, run.shouldRestart, session.isRunning, graphMatches,
              device.activeFormat === run.format, device.activeColorSpace == run.color,
              session.sessionPreset == run.preset, device.exposureMode == run.exposureMode,
              device.whiteBalanceMode == run.whiteBalanceMode, exposureMatches, gainsMatch,
              near(device.activeVideoMinFrameDuration.seconds, run.minimumFrame.seconds, floor: 0.000001),
              near(device.activeVideoMaxFrameDuration.seconds, run.maximumFrame.seconds, floor: 0.000001),
              near(Double(device.videoZoomFactor), Double(run.zoom), floor: 0.0001),
              near(Double(device.exposureTargetBias), Double(run.bias), floor: 0.001) else {
            run.restorationFailure = "video restoration postcondition failed after device acknowledgments"
            finishDebugPhotoRun(run)
            return
        }
        run.evidence["restoration"] = "frameworkConfirmed"
        finishDebugPhotoRun(run)
    }

    private func finishDebugPhotoRun(_ run: DebugPhotoRun) {
        guard debugPhotoRun === run else { return }
        var failure = run.restorationFailure ?? run.captureFailure
        if run.interrupted { failure = failure ?? "capture experiment interrupted by backgrounding" }
        if run.restorationFailure != nil || run.interrupted {
            if session.isRunning { session.stopRunning() }
            isConfigured = false
            run.evidence["restoration"] = "failedStopped"
        }
        run.evidence["runningAfter"] = String(session.isRunning)
        run.evidence["status"] = failure == nil ? "captureAndConfigurationComplete" : "failed"
        if let failure { run.evidence["failure"] = String(failure.prefix(600)) }
        do { try writeDebugPhotoEvidence(run) }
        catch {
            failure = "session evidence could not be persisted: \(error.localizedDescription)"
            if session.isRunning { session.stopRunning() }
            isConfigured = false
        }
        debugPhotoCapture = nil
        debugPhotoRun = nil
        let result: Result<URL, Error> = failure.map { .failure(CameraError.writerUnavailable("Photo RAW P0: \($0)")) }
            ?? .success(run.directory)
        print("Photo RAW P0 evidence: \(run.directory.path); \(failure ?? "capture/configuration complete; video/audio still unverified")")
        DispatchQueue.main.async { run.completion(result) }
    }

    private func writeDebugPhotoEvidence(_ run: DebugPhotoRun) throws {
        let data = try JSONSerialization.data(withJSONObject: run.evidence, options: [.sortedKeys])
        guard data.count <= 8192 else { throw CameraError.writerUnavailable("Photo RAW P0: session evidence too large") }
        try data.write(to: run.directory.appendingPathComponent("session.json"), options: .atomic)
    }

    func startDebugSmokeCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning, !self.isRecordingOrPending else {
                print("HEVC Log2 smoke failed: camera session is unavailable or busy")
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hevc-log2-smoke-\(UUID().uuidString).mov")
            self.debugSmokeURL = url
            self.debugSmokeTimedOut = false
            let smokeContext = CameraSessionSmokeCallbackContext(session: self, queue: self.sessionQueue, url: url)
            self.startRecording(to: url) { [smokeContext] error in
                smokeContext.recordingStarted(errorDescription: error?.localizedDescription)
            }
            smokeContext.scheduleTimeout()
        }
    }

    fileprivate func debugSmokeStartFailed(_ message: String, url: URL) {
        guard debugSmokeURL == url else { return }
        debugSmokeURL = nil
        debugSmokeTimedOut = false
        print("HEVC Log2 smoke failed to start: \(message)")
        try? FileManager.default.removeItem(at: url)
    }

    fileprivate func debugSmokeStop(url: URL, timedOut: Bool) {
        guard debugSmokeURL == url else { return }
        debugSmokeTimedOut = timedOut
        guard timedOut else {
            stopRecording()
            return
        }
        recordingGeneration &+= 1
        if recordingStartPending {
            recordingStartPending = false
            failPendingStart(CameraSampleBufferRecorderError.cancelled)
        }
        if let epoch = recorderCompletionBridge.activeEpoch {
            recorderCompletionBridge.cancelUserStart(epoch: epoch)
            recordingFinishing = true
            refreshPublicRecordingState()
            sampleBufferRecorder.cancel()
        } else {
            finishDebugSmokeTimeoutWithoutRecorder(url: url)
        }
    }

    private func finishDebugSmokeTimeoutWithoutRecorder(url: URL) {
        guard debugSmokeURL == url else { return }
        debugSmokeURL = nil
        debugSmokeTimedOut = false
        recordingActive = false
        recordingFinishing = false
        recordingStartPending = false
        refreshPublicRecordingState()
        print("HEVC Log2 smoke failed: capture exceeded its timeout before the recorder started")
        try? FileManager.default.removeItem(at: url)
    }
#endif

    var isRecording: Bool {
        recordingStateLock.lock()
        defer { recordingStateLock.unlock() }
        return publicRecordingState
    }

    private var isRecordingOrPending: Bool {
#if DEBUG
        if debugPhotoRun != nil || developmentPhotoController?.isCapturing == true { return true }
#endif
        return recordingActive || recordingFinishing || recordingStartPending
    }

    private func refreshPublicRecordingState() {
        recordingStateLock.lock()
        publicRecordingState = recordingActive || recordingFinishing
        recordingStateLock.unlock()
    }

    func onFinish(_ handler: @escaping @MainActor @Sendable (Result<RecordingCompletion, Error>) -> Void) {
        sessionQueue.async { [weak self] in self?.onRecordingFinished = handler }
    }

    // MARK: - Session lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.sharedIdleEnabled {
                self.stopSessionAfterRecording = false
                self.beginDeviceOrientationNotificationsIfNeeded()
                self.sharedGraph.request(.idle)
                self.driveSharedGraph()
                return
            }
            if self.developmentPhotoController != nil {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            if let run = self.debugPhotoRun { run.shouldRestart = true; return }
#endif
            // A session boundary always begins at the default mode, even when a
            // previous take was still draining when the reset was queued.
            self.applyDeferredFrameRateReset()
            guard self.isConfigured else { return }
            self.stopSessionAfterRecording = false
            self.beginDeviceOrientationNotificationsIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.suspendPreview(false)
            if !self.isRecordingOrPending { self.applyRecordingStabilization() }
        }
    }


    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.sharedIdleEnabled {
                self.sharedGraph.request(.stopped)
                let request = self.sharedVideoRequest
                self.sharedVideoRequest = nil
                if let request { DispatchQueue.main.async { request.completion(CameraSampleBufferRecorderError.cancelled) } }
                self.cancelZoomOnQueue()
                self.invalidateMetering()
                if self.recordingStartPending || self.recordingActive || self.recordingFinishing {
                    self.stopSessionAfterRecording = true
                } else {
                    self.driveSharedGraph()
                    return
                }
            }
            if !self.sharedIdleEnabled, let run = self.developmentPhotoSnapshot, self.developmentPhotoController != nil {
                run.shouldRestart = false
                run.interrupted = true
                self.exitDevelopmentPhotoOnQueue { _ in }
                // The controller drains entered capture/setter callbacks before
                // graph restoration stops the session. Stopping here can prevent
                // the frame-stamped acknowledgment needed to release ownership.
                return
            }
            if let run = self.debugPhotoRun {
                run.shouldRestart = false
                run.interrupted = true
                if self.session.isRunning { self.session.stopRunning() }
                if run.restorationStarted {
                    run.restorationFailure = "video restoration interrupted by backgrounding"
                    self.finishDebugPhotoRun(run)
                }
                return
            }
#endif
            self.cancelZoomOnQueue()
            self.publishZoom()
            self.suspendPreview(true)
            self.invalidateMetering()
            if self.recordingStartPending {
                self.recordingStartPending = false
                self.recordingGeneration &+= 1
                self.failPendingStart(CameraSampleBufferRecorderError.cancelled)
                if let epoch = self.recorderCompletionBridge.activeEpoch {
                    self.recorderCompletionBridge.cancelUserStart(epoch: epoch)
                    self.recordingFinishing = true
                    self.refreshPublicRecordingState()
                    self.sampleBufferRecorder.cancel()
                }
            } else if self.recordingActive {
                // Keep the capture connection running until the recorder has
                // drained video to the frozen audio endpoint.
                self.stopSessionAfterRecording = true
                self.recordingFinishing = true
                self.refreshPublicRecordingState()
                self.sampleBufferRecorder.stop()
                return
            }
#if DEBUG
            if self.sharedIdleEnabled { self.driveSharedGraph(); return }
#endif
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

/// Sendable bridge for the writer queue. It only retains a weak session and
/// hops recorder results to sessionQueue before touching camera state.
private final class CameraSessionRecorderCallbackContext: @unchecked Sendable {
    private weak var session: CameraSession?
    private let queue: DispatchQueue

    init(session: CameraSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    func enqueueStarted(_ error: CameraRecorderErrorBox, generation: UInt64) {
        queue.async { [self] in session?.recorderStartedOnSessionQueue(error.value, generation: generation) }
    }

    func enqueueFinished(_ result: CameraRecorderResultBox, generation: UInt64) {
        queue.async { [self] in session?.recorderFinishedOnSessionQueue(result.result, generation: generation) }
    }
}

#if DEBUG
/// The launch smoke's delayed callbacks carry only immutable URL/configuration
/// and enqueue all mutable session access onto sessionQueue.
private final class CameraSessionSmokeCallbackContext: @unchecked Sendable {
    private weak var session: CameraSession?
    private let queue: DispatchQueue
    private let url: URL

    init(session: CameraSession, queue: DispatchQueue, url: URL) {
        self.session = session
        self.queue = queue
        self.url = url
    }

    func recordingStarted(errorDescription: String?) {
        if let errorDescription {
            queue.async { [self] in session?.debugSmokeStartFailed(errorDescription, url: url) }
        } else {
            queue.asyncAfter(deadline: .now() + 3) { [self] in session?.debugSmokeStop(url: url, timedOut: false) }
        }
    }

    func scheduleTimeout() {
        queue.asyncAfter(deadline: .now() + 15) { [self] in session?.debugSmokeStop(url: url, timedOut: true) }
    }
}
#endif

private struct CameraRecorderErrorBox: @unchecked Sendable {
    let value: Error?
    init(_ value: Error?) { self.value = value }
}

private struct CameraRecorderResultBox: @unchecked Sendable {
    let result: Result<URL, Error>
    init(_ result: Result<URL, Error>) { self.result = result }
}

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case writerUnavailable(String)
    case appleLogNotSupported
    case appleLog2NotSupported
    case recordingInProgress
    case destinationAlreadyExists
    case recordingFailed
    case exposureChangeDuringRecording
    case apertureUnavailable
    case apertureExposureUnsupported
    case exposureMeterUnavailable
    case lensRollbackFailed(original: Error, rollback: Error)
    case daylight60Unsupported(String)
    case frameRateTransitionInProgress
    case frameRateTransitionSuperseded
    case captureRecoveryRequired(String)

    /// Plain-words reason carried by `.daylight60Unsupported`.
    static let daylight60Reason =
        "no 4K Apple Log 2 10-bit format supports 60 fps on this device"

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available."
        case .cannotAddInput:
            return "Failed to add camera input to capture session."
        case .cannotAddOutput:
            return "Failed to add a sample-buffer output to the capture session."
        case .writerUnavailable(let detail):
            return "Apple Log 2 HEVC Main10 recording is unavailable. \(detail)"
        case .appleLogNotSupported:
            return "Apple Log color space is not supported on this device."
        case .appleLog2NotSupported:
            return "Apple Log 2 recording requires a supported 4K, 24 fps camera format on this device."
        case .recordingInProgress:
            return "A recording is already in progress."
        case .destinationAlreadyExists:
            return "The recording destination already exists."
        case .recordingFailed:
            return "The recording could not be finalized."
        case .exposureChangeDuringRecording:
            return "Exposure cannot be changed during a recording."
        case .apertureUnavailable:
            return "Aperture control is unavailable for the active camera format."
        case .apertureExposureUnsupported:
            return "The active camera format does not support that aperture with the current exposure settings."
        case .exposureMeterUnavailable:
            return "The camera could not provide a valid ISO reading for shutter-priority exposure."
        case .lensRollbackFailed(let original, let rollback):
            return "Camera switch failed (\(original.localizedDescription)); restoring the previous camera also failed (\(rollback.localizedDescription))."
        case .daylight60Unsupported(let detail):
            return "Daylight 60 fps is unavailable on this device: \(detail)."
        case .frameRateTransitionInProgress:
            return "A frame-rate change is already in progress."
        case .frameRateTransitionSuperseded:
            return "The frame-rate change was superseded by the end of the camera session."
        case .captureRecoveryRequired(let detail):
            return "Camera configuration needs recovery: \(detail). Try recording again after the camera reconnects."
        }
    }
}
