import Foundation

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

        init(width: Int32, height: Int32, supportsAppleLog2: Bool,
             supports24FPS: Bool, isTenBitBiPlanar420: Bool = false) {
            self.width = width
            self.height = height
            self.supportsAppleLog2 = supportsAppleLog2
            self.supports24FPS = supports24FPS
            self.isTenBitBiPlanar420 = isTenBitBiPlanar420
        }
    }

    static func appleLog2Index(in candidates: [Candidate]) -> Int? {
        let matches = candidates.indices.filter {
            let candidate = candidates[$0]
            return candidate.width == 3840 && candidate.height == 2160
                && candidate.supportsAppleLog2 && candidate.supports24FPS
        }
        return matches.first(where: { candidates[$0].isTenBitBiPlanar420 }) ?? matches.first
    }
}

enum CameraMovieCapabilityPolicy {
    static func settings(
        availableCodecs: [String],
        hevcCodec: String,
        availableSettingsKeys: Set<String>,
        formatDescription: String,
        codecKey: String,
        compressionKey: String,
        averageBitRateKey: String,
        maxKeyFrameIntervalKey: String,
        profileLevelKey: String,
        averageBitRate: Int,
        maxKeyFrameInterval: Int,
        main10Profile: String
    ) throws -> [String: Any] {
        guard availableSettingsKeys.contains(codecKey) else {
            throw CameraMovieCapabilityError.codecSettingsUnavailable(format: formatDescription)
        }
        guard availableCodecs.contains(hevcCodec) else {
            throw CameraMovieCapabilityError.hevcUnavailable(available: availableCodecs, format: formatDescription)
        }
        var result: [String: Any] = [codecKey: hevcCodec]
        if availableSettingsKeys.contains(compressionKey) {
            result[compressionKey] = [
                averageBitRateKey: averageBitRate,
                maxKeyFrameIntervalKey: maxKeyFrameInterval,
                profileLevelKey: main10Profile
            ]
        }
        return result
    }
}

enum CameraMovieCapabilityError: LocalizedError {
    case codecSettingsUnavailable(format: String)
    case hevcUnavailable(available: [String], format: String)

    var errorDescription: String? {
        switch self {
        case .codecSettingsUnavailable(let format):
            return "HEVC recording settings are unavailable for this camera connection (\(format))."
        case .hevcUnavailable(let available, let format):
            let names = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "HEVC recording is unavailable for \(format). Available codecs: \(names)."
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
