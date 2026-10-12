import Foundation
import AVFoundation
import CoreVideo

/// Select a declared Log 2 4K/24fps format from device capability evidence.
/// Keeping the policy independent of hardware lets tests cover mixed-format
/// devices and unsupported lenses without constructing AVCaptureDevice objects.
enum CameraCaptureFormatPolicy {
    struct Candidate: Sendable {
        let width: Int32
        let height: Int32
        let supportsAppleLog2: Bool
        let supports24FPS: Bool
        let isTenBitBiPlanar420: Bool
        let isTenBitBiPlanar422: Bool

        init(width: Int32, height: Int32, supportsAppleLog2: Bool,
             supports24FPS: Bool, isTenBitBiPlanar420: Bool = false,
             isTenBitBiPlanar422: Bool = false) {
            self.width = width
            self.height = height
            self.supportsAppleLog2 = supportsAppleLog2
            self.supports24FPS = supports24FPS
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
}

enum CameraSampleValidationPolicy {
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
        width == 3840 && height == 2160 && acceptedPixelFormats.contains(pixelFormat)
            && isAppleLog2(logTransfer)
            && matrix == "ITU_R_2020"
            && (primaries == nil || primaries == "Unspecified")
            && (transfer == nil || transfer == "Unspecified")
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
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(codedHeight), ty: 0)
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

    static func explicitHEVCMain10Settings(profile: String, averageBitRate: Int,
                                           colorProperties: [String: String]) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 3840,
            AVVideoHeightKey: 2160,
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
        codec == .hevc && width == 3840 && height == 2160 && profile == expectedProfile
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

/// The AVFoundation completion flag determines whether an errored movie is
/// still a valid finalized recording that must be published to the queue.
enum RecordingCompletionPolicy {
    static func shouldPublish(errorExists: Bool, finishedPlayable: Bool?) -> Bool {
        !errorExists || finishedPlayable == true
    }
}
