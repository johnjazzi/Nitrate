import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import ImageIO

/// Per-camera, session-queue-confined memory of the latest real physical hold.
/// A fresh source defaults through the portrait mapping; flat readings retain
/// its last stable gravity angle instead of inventing a new orientation.
struct CameraCaptureRotationPolicy: Sendable {
    private var lastStableAngle: CGFloat?

    mutating func snapshot(for orientation: CameraSampleValidationPolicy.DeliveryOrientation,
                           liveAngle: CGFloat?) -> CGFloat? {
        if orientation.isPhysicalHold, let liveAngle, liveAngle.isFinite {
            lastStableAngle = liveAngle
        }
        return lastStableAngle
    }
}

/// Orientation travels with the frozen buffer, not the portrait-locked UI or
/// the later slider render. Only the final rendered BGRA image is rotated;
/// sensor pixels and the existing Metal grading pipeline stay untouched.
enum CameraFrozenFrameOrientationPolicy {
    private static var attachmentKey: CFString { "com.fea.debug.capture-quarter-turns" as CFString }

    static func setQuarterTurns(_ turns: Int, on buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, attachmentKey, NSNumber(value: (turns % 4 + 4) % 4), .shouldPropagate)
    }

    static func quarterTurns(in buffer: CVPixelBuffer) -> Int {
        let value = (CVBufferCopyAttachment(buffer, attachmentKey, nil) as? NSNumber)?.intValue ?? 0
        return (value % 4 + 4) % 4
    }

    static func orient(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = (quarterTurns % 4 + 4) % 4
        guard turns != 0 else { return image }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        let oriented = CIImage(cgImage: image).oriented(orientations[turns])
        // Rotation is a pixel permutation, not an additional color conversion.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        return context.createCGImage(oriented, from: oriented.extent, format: .BGRA8,
                                     colorSpace: image.colorSpace)
    }
}

/// Select a declared Log 2 4K/24fps format from device capability evidence.
/// Keeping the policy independent of hardware lets tests cover mixed-format
/// devices and unsupported lenses without constructing AVCaptureDevice objects.
enum CameraCaptureFormatPolicy {
    struct Candidate: Sendable {
        let width: Int32
        let height: Int32
        let supportsAppleLog2: Bool
        let supports24FPS: Bool
        /// `videoSupportedFrameRateRanges` contains 60.
        let supports60FPS: Bool
        let isTenBitBiPlanar420: Bool
        let isTenBitBiPlanar422: Bool

        init(width: Int32, height: Int32, supportsAppleLog2: Bool,
             supports24FPS: Bool, isTenBitBiPlanar420: Bool = false,
             isTenBitBiPlanar422: Bool = false, supports60FPS: Bool = false) {
            self.width = width
            self.height = height
            self.supportsAppleLog2 = supportsAppleLog2
            self.supports24FPS = supports24FPS
            self.supports60FPS = supports60FPS
            self.isTenBitBiPlanar420 = isTenBitBiPlanar420
            self.isTenBitBiPlanar422 = isTenBitBiPlanar422
        }
    }

    static func appleLog2Index(in candidates: [Candidate]) -> Int? {
        appleLog2CandidateIndexes(in: candidates).first
    }

    static func appleLog2CandidateIndexes(in candidates: [Candidate]) -> [Int] {
        let matches = candidates.indices.filter {
            let candidate = candidates[$0]
            return candidate.width == 3840 && candidate.height == 2160
                && candidate.supportsAppleLog2 && candidate.supports24FPS
                && (candidate.isTenBitBiPlanar420 || candidate.isTenBitBiPlanar422)
        }
        return matches.filter { candidates[$0].isTenBitBiPlanar420 }
            + matches.filter { candidates[$0].isTenBitBiPlanar422 }
    }

    /// Parallel to `appleLog2CandidateIndexes`, but requires a 60 fps range.
    /// `.standard24` selection is unchanged; `.daylight60` uses this.
    static func appleLog2SixtyCandidateIndexes(in candidates: [Candidate]) -> [Int] {
        appleLog2CandidateIndexes(in: candidates)
    }
}

/// Approximate capture time while reserving space for the retained source and
/// rendered movie at the configured delivery video and audio bitrates.
enum CameraStorageEstimatePolicy {
    static func remainingSeconds(
        freeBytes: Int64,
        criticalReserveBytes: Int64,
        videoBitRate: Int,
        audioBitRate: Int,
        retainedCopies: Int = 2
    ) -> TimeInterval? {
        guard freeBytes >= 0,
              criticalReserveBytes >= 0,
              videoBitRate > 0,
              audioBitRate > 0,
              retainedCopies > 0 else { return nil }

        let budgetBytes = max(0, freeBytes - criticalReserveBytes)
        let bitsPerSecond = Double(retainedCopies)
            * (Double(videoBitRate) + Double(audioBitRate))
        let bytesPerSecond = bitsPerSecond / 8
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }

        let seconds = Double(budgetBytes) / bytesPerSecond
        return seconds.isFinite ? seconds : nil
    }
}

/// Pure aperture policy for the iOS 27 lens-aperture controls. Values displayed
/// in the UI come only from the active format's recommended stops.
enum CameraAperturePolicy {
    enum Capability: Equatable, Sendable {
        case unavailable
        case fixed(Float)
        case variable([Float])

        var stops: [Float] {
            switch self {
            case .unavailable: return []
            case .fixed(let value): return [value]
            case .variable(let values): return values
            }
        }

        var isVariable: Bool {
            if case .variable = self { return true }
            return false
        }
    }

    enum ExposureMode {
        case shutterPriority
        case manual
    }

    struct ExposureParameters: Equatable {
        let aperture: Float
        let duration: CMTime
        let iso: Float
    }

    struct RecordingPin: Equatable {
        let aperture: Float
        let restoresAuto: Bool
    }

    static func performIfSupported(_ parameters: ExposureParameters,
                                   supports: (ExposureParameters) -> Bool,
                                   apply: () throws -> Void) rethrows -> Bool {
        guard supports(parameters) else { return false }
        try apply()
        return true
    }

    static func recordingPin(selectedAperture: Float?, measuredAperture: Float) -> RecordingPin? {
        guard measuredAperture.isFinite, measuredAperture > 0 else { return nil }
        return RecordingPin(aperture: selectedAperture ?? measuredAperture,
                            restoresAuto: selectedAperture == nil)
    }

    static func selectedApertureAfterRecording(pin: RecordingPin) -> Float? {
        pin.restoresAuto ? nil : pin.aperture
    }

    static func evCompensatedISO(meteredISO: Float, ev: Float,
                                 minimum: Float, maximum: Float) -> Float? {
        guard meteredISO.isFinite, meteredISO > 0, ev.isFinite,
              minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        return min(max(meteredISO * powf(2, ev), minimum), maximum)
    }

    static func recommendedStops(_ recommended: [Float], minimum: Float, maximum: Float) -> [Float] {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return [] }
        return Array(Set(recommended.filter {
            $0.isFinite && $0 >= minimum && $0 <= maximum
        })).sorted()
    }

    static func capability(recommended: [Float], minimum: Float, maximum: Float) -> Capability {
        let stops = recommendedStops(recommended, minimum: minimum, maximum: maximum)
        switch stops.count {
        case 0: return .unavailable
        case 1: return .fixed(stops[0])
        default: return .variable(stops)
        }
    }

    /// `nil` represents Auto. Explicit choices are reconciled to the nearest
    /// stop reported by the new active format.
    static func reconcile(_ selected: Float?, with capability: Capability) -> Float? {
        guard let selected else { return nil }
        let stops = capability.stops
        guard !stops.isEmpty else { return nil }
        return stops.min { abs($0 - selected) < abs($1 - selected) }
    }

    static func exposureParameters(selectedAperture: Float?, heldAperture: Float,
                                   mode: ExposureMode, manualISO: Float,
                                   autoISO: Float, minISO: Float, maxISO: Float,
                                   duration: CMTime) -> ExposureParameters? {
        guard heldAperture.isFinite, minISO.isFinite, maxISO.isFinite,
              minISO <= maxISO, duration.isNumeric,
              selectedAperture.map({ $0.isFinite && $0 > 0 }) ?? true else { return nil }
        let iso: Float
        switch mode {
        case .shutterPriority: iso = autoISO
        case .manual:
            guard manualISO.isFinite else { return nil }
            iso = min(max(manualISO, minISO), maxISO)
        }
        return ExposureParameters(aperture: selectedAperture ?? heldAperture,
                                  duration: duration, iso: iso)
    }
}

struct CameraApertureSnapshot: Sendable {
    let capability: CameraAperturePolicy.Capability
    let measured: Float?
    let selected: Float?
    let cameraRevision: UInt64
}

enum CameraSampleValidationPolicy {
    /// Physical device orientation held at the moment a recording starts. The
    /// delivered movie's display orientation follows this value, so a take
    /// recorded horizontally is saved landscape instead of portrait.
    ///
    /// The raw values mirror `UIDeviceOrientation`, which keeps the UIKit bridge
    /// in `CameraSession` a plain pass-through and lets the mapping stay
    /// UIKit-free so it can be unit-tested on macOS.
    enum DeliveryOrientation: Equatable, Sendable {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight
        case faceUp
        case faceDown
        case unknown

        /// Bridge from `UIDeviceOrientation.rawValue`. Unrecognised values (and
        /// `unknown`, `faceUp`, `faceDown`) deliver portrait.
        init(deviceOrientationRawValue: Int) {
            switch deviceOrientationRawValue {
            case 1: self = .portrait
            case 2: self = .portraitUpsideDown
            case 3: self = .landscapeLeft
            case 4: self = .landscapeRight
            case 5: self = .faceUp
            case 6: self = .faceDown
            default: self = .unknown
            }
        }

        /// Only a face-on landscape hold selects landscape delivery. Lying flat
        /// (faceUp/faceDown) and an unknown reading keep the portrait default.
        var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
        var isPhysicalHold: Bool { isLandscape || self == .portrait || self == .portraitUpsideDown }
    }

    /// The writer's track transform and the display dimensions it produces,
    /// chosen from the sensor (coded) buffer orientation and the device
    /// orientation held at recording start.
    struct DeliveryGeometry: Equatable, Sendable {
        let transform: CGAffineTransform
        let displayWidth: Int
        let displayHeight: Int
    }

    struct CodedDimensions: Equatable, Sendable {
        let width: Int
        let height: Int

        static let landscape4K = CodedDimensions(validatedWidth: 3840, height: 2160)
        static let portrait4K = CodedDimensions(validatedWidth: 2160, height: 3840)

        private init(validatedWidth width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        init?(width: Int, height: Int) {
            guard (width == 3840 && height == 2160) || (width == 2160 && height == 3840) else {
                return nil
            }
            self.init(validatedWidth: width, height: height)
        }

        var isPortrait: Bool { height > width }
    }

    /// Clockwise quarter turns relative to the unrotated sensor. Camera-specific
    /// AVFoundation capture angles take precedence over the fallback convention.
    /// Native portrait input is already one quarter turn from landscape-coded
    /// input; its landscapeLeft mapping must therefore be 270°, not 90°.
    static func deliveryQuarterTurns(for orientation: DeliveryOrientation,
                                     coded: CodedDimensions,
                                     captureRotationAngle: CGFloat? = nil) -> Int {
        if let angle = captureRotationAngle, angle.isFinite {
            let normalized = angle.truncatingRemainder(dividingBy: 360)
            return (Int((normalized / 90).rounded()) % 4 + 4) % 4
        }
        let landscapeTurns: Int
        switch orientation {
        case .landscapeLeft: landscapeTurns = 0
        case .landscapeRight: landscapeTurns = 2
        case .portraitUpsideDown: landscapeTurns = 3
        case .portrait, .unknown, .faceUp, .faceDown: landscapeTurns = 1
        }
        return (landscapeTurns + (coded.isPortrait ? 3 : 0)) % 4
    }

    static func deliveryGeometry(for orientation: DeliveryOrientation,
                                 coded: CodedDimensions,
                                 captureRotationAngle: CGFloat? = nil) -> DeliveryGeometry {
        let turns = deliveryQuarterTurns(for: orientation, coded: coded,
                                         captureRotationAngle: captureRotationAngle)
        let transform: CGAffineTransform
        switch turns {
        case 1:
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(coded.height), ty: 0)
        case 2:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1,
                                          tx: CGFloat(coded.width), ty: CGFloat(coded.height))
        case 3:
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(coded.width))
        default: transform = .identity
        }
        return DeliveryGeometry(transform: transform,
                                displayWidth: turns % 2 == 0 ? coded.width : coded.height,
                                displayHeight: turns % 2 == 0 ? coded.height : coded.width)
    }

    static var appleLog2Identifier: String {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            return kCVImageBufferLogTransferFunction_AppleLog2 as String
        }
        return "com.apple.apple-wide-gamut.apple-log"
    }

    static func preferredTenBitPixelFormats(from available: [UInt32]) -> [UInt32] {
        let tenBit420: Set<UInt32> = [0x78343230, 0x78663230] // x420, xf20
        let tenBit422: Set<UInt32> = [0x78343232, 0x78663232] // x422, xf22
        return available.filter { tenBit420.contains($0) } + available.filter { tenBit422.contains($0) }
    }

    static func firstUsableTenBitPixelFormat(from available: [UInt32],
                                             isUsable: (UInt32) -> Bool) -> UInt32? {
        preferredTenBitPixelFormats(from: available).first(where: isUsable)
    }

    static func fourCCDescription(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        guard bytes.allSatisfy({ (32...126).contains($0) }),
              let fourCC = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "0x%08X", value)
        }
        return fourCC
    }

    static func fourCCListDescription(_ values: [UInt32]) -> String {
        values.isEmpty ? "none" : values.map(fourCCDescription).joined(separator: ", ")
    }

    static func accepts(width: Int, height: Int, pixelFormat: UInt32,
                        acceptedPixelFormats: Set<UInt32>, logTransfer: String?, matrix: String?,
                        primaries: String?, transfer: String?) -> Bool {
        rejectionReasons(width: width, height: height, pixelFormat: pixelFormat,
            acceptedPixelFormats: acceptedPixelFormats, logTransfer: logTransfer,
            matrix: matrix, primaries: primaries, transfer: transfer).isEmpty
    }

    static func rejectionReasons(width: Int, height: Int, pixelFormat: UInt32,
                                 acceptedPixelFormats: Set<UInt32>, logTransfer: String?,
                                 matrix: String?, primaries: String?, transfer: String?) -> [String] {
        var reasons: [String] = []
        if CodedDimensions(width: width, height: height) == nil {
            reasons.append("format dimensions are \(width)x\(height), expected 3840x2160 or 2160x3840")
        }
        if !acceptedPixelFormats.contains(pixelFormat) {
            reasons.append("pixel format \(fourCCDescription(pixelFormat)) was not negotiated")
        }
        if !isAppleLog2(logTransfer) {
            reasons.append("Log transfer is \(logTransfer ?? "missing"), expected Apple Log 2")
        }
        if matrix != "ITU_R_2020" {
            reasons.append("YCbCr matrix is \(matrix ?? "missing"), expected ITU_R_2020")
        }
        if let primaries, primaries != "Unspecified" {
            reasons.append("color primaries is \(primaries), expected missing or Unspecified")
        }
        if let transfer, transfer != "Unspecified" {
            reasons.append("transfer function is \(transfer), expected missing or Unspecified")
        }
        return reasons
    }

    static func isAppleLog2(_ identifier: String?) -> Bool {
        identifier == appleLog2Identifier
    }

    static func audioIsAfterSessionStart(sampleTime: Double, sessionStart: Double) -> Bool {
        sampleTime.isFinite && sessionStart.isFinite && sampleTime >= sessionStart
    }

    static func timestampIsIncreasing(current: Double, previous: Double?) -> Bool {
        current.isFinite && (previous.map { current > $0 } ?? true)
    }

    static func shouldFailForFrameDrops(recentDropCount: Int, threshold: Int = 3) -> Bool {
        recentDropCount >= threshold
    }

    static func dropTimesWithinWindow(_ times: [Double], now: Double, window: Double = 2) -> [Double] {
        guard now.isFinite, window.isFinite, window >= 0 else { return [] }
        return times.filter { $0.isFinite && now >= $0 && now - $0 <= window } + [now]
    }

    static func portraitTrackTransform(codedWidth: Int, codedHeight: Int) -> CGAffineTransform {
        guard codedWidth > codedHeight else { return .identity }
        return CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                 tx: CGFloat(codedHeight), ty: 0)
    }

    static func displayDimensions(codedWidth: Int, codedHeight: Int, transform: CGAffineTransform) -> (Int, Int) {
        if abs(transform.b) > 0.5 || abs(transform.c) > 0.5 {
            return (codedHeight, codedWidth)
        }
        return (codedWidth, codedHeight)
    }

    static func hasHEVCEncoder(_ codecTypes: [String]) -> Bool {
        codecTypes.contains("hvc1")
    }

    static func explicitHEVCMain10Settings(width: Int = 3840, height: Int = 2160, profile: String, averageBitRate: Int,
                                           colorProperties: [String: String]) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: profile,
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoMaxKeyFrameIntervalKey: 48
            ],
            AVVideoColorPropertiesKey: colorProperties
        ]
    }

    /// Explicit AAC settings for the recorded original.
    ///
    /// `AVCaptureAudioDataOutput.recommendedAudioSettingsForAssetWriter` can
    /// return uncompressed `lpcm` for the built-in microphone. The original is
    /// contracted to carry AAC, so request it explicitly instead of trusting
    /// the recommendation.
    static func aacAudioSettings(sampleRate: Double, channels: Int = 1,
                                 averageBitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: averageBitRate
        ]
    }

    /// AAC sample rates the encoder accepts; other rates are coerced.
    static func normalizedAACSampleRate(_ requested: Double) -> Double {
        requested == 44_100 ? 44_100 : 48_000
    }

    /// Bind `AVVideoCodecKey` as `AVVideoCodecType`, not `String`. AVFoundation
    /// boxes that value as an `AVVideoCodecType`, so casting it to `String`
    /// always yields nil and would reject valid HEVC settings on device.
    static func acceptsHEVCMain10Settings(codec: AVVideoCodecType?, width: Int?, height: Int?,
                                           profile: String?, expectedProfile: String) -> Bool {
        guard let width, let height else { return false }
        return codec == .hevc && CodedDimensions(width: width, height: height) != nil
            && profile == expectedProfile
    }
}

enum CameraSampleBufferRecorderState: Equatable {
    case idle
    case awaitingVideo
    case recording
    case finishing
    case finished
    case failed
}

enum CameraSampleBufferRecorderEvent {
    case begin
    case firstVideoAppend
    case stop
    case finishSuccess
    case failure
    case reset
}

enum CameraSampleBufferRecorderLifecyclePolicy {
    static func acceptsCompletion(callbackGeneration: UInt64, activeGeneration: UInt64?) -> Bool {
        activeGeneration == callbackGeneration
    }

    static func transition(_ state: CameraSampleBufferRecorderState,
                           on event: CameraSampleBufferRecorderEvent) -> CameraSampleBufferRecorderState? {
        switch (state, event) {
        case (.idle, .begin): return .awaitingVideo
        case (.awaitingVideo, .firstVideoAppend): return .recording
        case (.awaitingVideo, .failure), (.recording, .failure), (.finishing, .failure): return .failed
        case (.recording, .stop): return .finishing
        case (.finishing, .finishSuccess): return .finished
        case (.finished, .reset), (.failed, .reset): return .idle
        default: return nil
        }
    }
}

/// Small deterministic gate shared by the camera lifecycle and its tests.
struct CameraLifecycleGate {
    private(set) var isActive = false
    private(set) var generation: UInt64 = 0

    mutating func activate() -> UInt64? {
        guard !isActive else { return nil }
        isActive = true
        generation &+= 1
        return generation
    }

    mutating func deactivate() {
        guard isActive else { return }
        isActive = false
        generation &+= 1
    }

    func accepts(_ callbackGeneration: UInt64) -> Bool {
        isActive && generation == callbackGeneration
    }
}

/// Shared session/recorder completion ownership. User-start cancellation does
/// not release the epoch; only that writer's terminal callback can do so.
struct CameraRecorderCompletionBridge {
    private(set) var activeEpoch: UInt64?
    private(set) var userStartCancelled = false

    mutating func begin(epoch: UInt64) -> Bool {
        guard activeEpoch == nil else { return false }
        activeEpoch = epoch
        userStartCancelled = false
        return true
    }

    func acceptsStarted(epoch: UInt64) -> Bool {
        activeEpoch == epoch && !userStartCancelled
    }

    mutating func cancelUserStart(epoch: UInt64) {
        if activeEpoch == epoch { userStartCancelled = true }
    }

    mutating func consumeTerminal(epoch: UInt64) -> Bool? {
        guard activeEpoch == epoch else { return nil }
        let shouldNotifyUser = !userStartCancelled
        activeEpoch = nil
        userStartCancelled = false
        return shouldNotifyUser
    }
}

/// Rejects timer tasks that were already queued on MainActor when a timer was
/// invalidated or replaced.
struct RecordingTimerGeneration {
    private(set) var isActive = false
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func end() {
        isActive = false
        generation &+= 1
    }

    func accepts(_ callbackGeneration: UInt64) -> Bool {
        isActive && generation == callbackGeneration
    }
}

/// Invalidates shutter re-meter work queued before a mode/session boundary.
struct CameraMeteringGeneration {
    private(set) var generation: UInt64 = 0

    mutating func issue() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ callbackGeneration: UInt64) -> Bool {
        generation == callbackGeneration
    }
}

/// A finalized, readable original that failed a quality check.
///
/// The recording stays on disk: the writer produced a playable file, so the
/// media is still worth delivering even though the take cannot be reported as a
/// clean success. `originalURL` is the retained file and `reason` is the check
/// that failed.
///
/// `@unchecked Sendable` follows the existing recorder callbacks, which already
/// hand `any Error` across the recorder/session queues in `@unchecked Sendable`
/// boxes; the payload is a value type created on the recorder queue.
struct CameraRetainedRecordingError: LocalizedError, @unchecked Sendable {
    let originalURL: URL
    let reason: Error

    var errorDescription: String? {
        "Recording kept, but it did not pass validation: \(reason.localizedDescription)"
    }

    /// The retained original carried by an error, if it is one of ours.
    static func retainedURL(from error: Error) -> URL? {
        (error as? CameraRetainedRecordingError)?.originalURL
    }
}

/// A readable original kept back because the take failed a quality check.
///
/// It is deliberately not a recorded clip: the camera screen saves it to Photos
/// unchanged instead of handing it to the render queue.
struct RetainedOriginal: Equatable, Sendable {
    let url: URL
    let reason: String
}

/// The recorder's terminal result for one take, published to the view model.
struct RecordingCompletion: @unchecked Sendable {
    let url: URL
    let warning: Error?
    /// True when `url` is a readable original that failed validation. Such a
    /// take must not be rendered and must not be reported as a clean success.
    let retainedOriginal: Bool

    init(url: URL, warning: Error?, retainedOriginal: Bool = false) {
        self.url = url
        self.warning = warning
        self.retainedOriginal = retainedOriginal
    }
}

/// What the camera screen does with a finished take.
enum RecordingFinishPresentation: Equatable, Sendable {
    /// A normal take: publish it and let the screen auto-render it.
    case render(URL)
    /// A kept original: save it to Photos unchanged, never render it.
    case saveOriginalUnchanged(URL, reason: String)
}

/// Decides that split in one place, so "a retained original is never rendered"
/// is a testable rule rather than an accident of the view's wiring.
enum RecordingFinishPresentationPolicy {
    static func plan(for completion: RecordingCompletion) -> RecordingFinishPresentation {
        guard !completion.retainedOriginal else {
            return .saveOriginalUnchanged(completion.url, reason: reasonText(for: completion))
        }
        return .render(completion.url)
    }

    /// The underlying failing check, not the wrapper's own description: the
    /// session hands up the `CameraRetainedRecordingError` itself, and callers
    /// (messages, logs) want to know what actually failed.
    static func reasonText(for completion: RecordingCompletion) -> String {
        if let retained = completion.warning as? CameraRetainedRecordingError {
            return retained.reason.localizedDescription
        }
        return completion.warning?.localizedDescription ?? "the recording did not pass validation"
    }
}

/// The AVFoundation completion flag determines whether an errored movie is
/// still a valid finalized recording that must be published to the queue.
enum RecordingCompletionPolicy {
    static func shouldPublish(errorExists: Bool, finishedPlayable: Bool?) -> Bool {
        !errorExists || finishedPlayable == true
    }
}

/// Stabilises the 180° shutter-priority re-meter so the preview stops flickering.
///
/// AVFoundation has no native shutter-priority mode, so `CameraSession` briefly
/// re-enters auto exposure to meter, then pins custom exposure at the freshly
/// metered ISO. The old code did that unconditionally on every 1.5 s timer tick
/// and sampled the meter only 100 ms into an unconverged re-meter, so the pin
/// chased its own metering and the preview oscillated. This policy is the pure
/// decision that gates both steps: it holds while the scene is stable and only
/// lets the pin move once the metered value drifts past a deadband.
enum ExposureStabilizer {
    /// The exposure currently pinned on the device.
    struct Pin: Equatable, Sendable {
        /// ISO written to the device.
        let iso: Float
        /// EV compensation baked into `iso`.
        let ev: Float
        /// Raw metered ISO the pin was derived from, before `ev`.
        let meteredISO: Float
    }

    enum Action: Equatable, Sendable {
        /// Write `iso` as the new custom-exposure pin.
        case apply(iso: Float)
        /// Leave the current pin untouched.
        case hold
    }

    /// One third of a stop: a single step on the standard 1/3-stop ISO ladder,
    /// and below the ~0.5 stop change that is visible in the preview.
    static let deadbandStops: Float = 0.34

    /// A meter reading this close to the ISO we already applied is an echo of
    /// our own pin rather than an independent measurement.
    static let echoToleranceStops: Float = 0.02

    /// The held ISO corrected by the device's metered offset, in EV.
    ///
    /// Measured on device (iPhone 18 Pro, iOS 27): with custom exposure held,
    /// darkening the image two stops moved `exposureTargetOffset` to about -2.0,
    /// so a POSITIVE offset means the image is brighter than the target and the
    /// held ISO must come down. To preserve the selected compensation, use
    /// `heldISO * 2^(targetEV - offset)`; zero EV retains the neutral correction.
    /// Returns nil when an input is unusable, so the caller holds instead.
    static func correctedISO(heldISO: Float, meteredOffsetEV: Float, targetEV: Float = 0,
                             minimum: Float, maximum: Float) -> Float? {
        guard heldISO.isFinite, heldISO > 0, meteredOffsetEV.isFinite, targetEV.isFinite,
              minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        return min(max(heldISO * powf(2, targetEV - meteredOffsetEV), minimum), maximum)
    }

    /// Apply only the user's EV delta to the currently held scene exposure.
    /// This is not a fresh meter reading: using the original metered ISO would
    /// discard scene corrections, and applying the full EV would compound it.
    static func retargetedISO(pin: Pin, targetEV: Float,
                              minimum: Float, maximum: Float) -> Float? {
        correctedISO(heldISO: pin.iso, meteredOffsetEV: pin.ev, targetEV: targetEV,
                     minimum: minimum, maximum: maximum)
    }

    /// Decide the ISO to write from a fresh meter reading.
    ///
    /// Holds when the compensated target is within `deadbandStops` of the pin,
    /// and rejects re-deriving a target from a reading that already carries the
    /// EV compensation (which would apply the EV a second time and compound).
    static func decide(meteredISO: Float, ev: Float, current: Pin?,
                       minimum: Float, maximum: Float,
                       deadbandStops: Float = ExposureStabilizer.deadbandStops) -> Action {
        guard let target = CameraAperturePolicy.evCompensatedISO(
            meteredISO: meteredISO, ev: ev, minimum: minimum, maximum: maximum
        ) else { return .hold }
        guard let current, current.iso > 0, current.meteredISO > 0,
              ev.isFinite, deadbandStops.isFinite, deadbandStops >= 0 else {
            return .apply(iso: target)
        }
        // Compounding guard: the meter returned the ISO we already applied, so
        // it did not actually re-meter. Multiplying by 2^ev again would stack
        // the compensation cycle after cycle.
        if current.ev == ev,
           abs(log2(meteredISO / current.iso)) <= echoToleranceStops {
            return .hold
        }
        // Deadband: the current pin already sits within a third of a stop.
        if abs(log2(target / current.iso)) <= deadbandStops {
            return .hold
        }
        return .apply(iso: target)
    }
}

/// Maps the device's metered exposure-target offset (EV) onto the horizontal
/// under/over indicator and decides when the meter agrees with the target.
enum ExposureIndicatorPolicy {
    /// The indicator spans this many stops either side of centre.
    static let fullScaleEV: Float = 2

    /// |metered − target| within this many stops counts as a match.
    static let matchToleranceEV: Float = 0.1

    /// Normalised position on the bar: 0 = fully under (left), 1 = fully over
    /// (right), 0.5 = the centre EV. Clamped to the bar.
    static func position(ev: Float, fullScaleEV: Float = ExposureIndicatorPolicy.fullScaleEV) -> Float {
        guard ev.isFinite, fullScaleEV.isFinite, fullScaleEV > 0 else { return 0.5 }
        return min(max(0.5 + (ev / fullScaleEV) * 0.5, 0), 1)
    }

    /// Whether the metered offset agrees with the target inside `tolerance`.
    static func matches(meteredEV: Float, targetEV: Float,
                        tolerance: Float = ExposureIndicatorPolicy.matchToleranceEV) -> Bool {
        guard meteredEV.isFinite, targetEV.isFinite,
              tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(meteredEV - targetEV) <= tolerance
    }
}
