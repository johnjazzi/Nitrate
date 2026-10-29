import Foundation

/// Queue-confined arbiter used by the live session, not a UI mode flag. A newer
/// request changes the destination, but cannot release an entered hardware drain.
struct SharedCameraGraphOwnership: Sendable {
    enum Profile: Equatable, Sendable { case stopped, idle, video }
    struct Lease: Equatable, Sendable { let epoch: UInt64; let target: Profile }
    private(set) var desired: Profile = .stopped
    private(set) var actual: Profile = .stopped
    private(set) var lease: Lease?
    private(set) var requestEpoch: UInt64 = 0
    private var operationEpoch: UInt64 = 0
    var isBusy: Bool { lease != nil }
    var acceptsIdleControls: Bool { desired == .idle && actual == .idle && !isBusy }

    @discardableResult mutating func request(_ profile: Profile) -> UInt64 {
        requestEpoch &+= 1
        desired = profile
        return requestEpoch
    }

    mutating func begin(_ target: Profile) -> Lease? {
        guard lease == nil else { return nil }
        operationEpoch &+= 1
        let value = Lease(epoch: operationEpoch, target: target)
        lease = value
        return value
    }

    func owns(_ value: Lease) -> Bool { lease == value }
    func acceptsVideoRequest(_ epoch: UInt64) -> Bool {
        desired == .video && requestEpoch == epoch
    }

    @discardableResult mutating func finish(_ value: Lease, actual: Profile) -> Bool {
        guard owns(value) else { return false }
        self.actual = actual
        lease = nil
        return true
    }
}

/// Queue-confined ownership of the controller drain used by a warm input swap.
struct PhotoLensSwitchOwnership: Sendable {
    enum Completion: Equatable { case completed, exitRequested }
    private var epoch: UInt64 = 0
    private var activeEpoch: UInt64?
    private var exitPending = false
    var isPending: Bool { activeEpoch != nil }
    mutating func begin() -> UInt64? {
        guard !isPending else { return nil }
        epoch &+= 1; activeEpoch = epoch; exitPending = false
        return epoch
    }
    func owns(_ value: UInt64) -> Bool { activeEpoch == value }
    mutating func requestExit() -> Bool {
        guard isPending else { return false }
        exitPending = true
        return true
    }
    mutating func finish(_ value: UInt64) -> Completion? {
        guard owns(value) else { return nil }
        activeEpoch = nil
        let result: Completion = exitPending ? .exitRequested : .completed
        exitPending = false
        return result
    }
}

/// Capability rules shared by the production-hidden Bayer feasibility path.
enum PhotoCapturePolicy {
    static let maximumPixelCount = 12_192_768

    struct Dimensions: Equatable, Sendable {
        let width: Int
        let height: Int
        var pixelCount: Int {
            let result = width.multipliedReportingOverflow(by: height)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    static func permitsActualDimensions(_ dimensions: Dimensions) -> Bool {
        dimensions.width > 0 && dimensions.height > 0
            && dimensions.pixelCount <= maximumPixelCount
    }

    static func permitsBayerStorage(_ storage: Dimensions, usable: Dimensions) -> Bool {
        // Measured native DNG: 4224x3024 storage, 4032x3024 ActiveArea.
        // Bound backing storage separately; padding does not enlarge the image budget.
        permitsActualDimensions(usable)
            && storage.width >= usable.width && storage.height >= usable.height
            && storage.pixelCount <= 4224 * 3024
    }

    static func selectDimensions(candidates: [Dimensions], bayerPixelFormats: [UInt32],
                                 pixelFormat: UInt32) -> Dimensions? {
        guard bayerPixelFormats.contains(pixelFormat) else { return nil }
        return candidates.filter(permitsActualDimensions).max { lhs, rhs in
            lhs.pixelCount == rhs.pixelCount ? lhs.width < rhs.width : lhs.pixelCount < rhs.pixelCount
        }
    }
}

enum PhotoCompletionStep: Hashable, Sendable {
    case rawProcessed, captureTerminated, graphConfigured, exposureApplied, whiteBalanceApplied, biasApplied
}

/// A transaction can finish only after every required event has settled.
struct PhotoCompletionBarrier: Sendable {
    private var pending: Set<PhotoCompletionStep>
    init(waitingFor steps: Set<PhotoCompletionStep>) { pending = steps }
    var isReady: Bool { pending.isEmpty }
    mutating func complete(_ step: PhotoCompletionStep) { pending.remove(step) }
}

enum PhotoCaptureCallbackDisposition: Equatable, Sendable {
    case accepted, duplicate, foreign, terminal
}

enum PhotoCaptureTimeoutDisposition: Equatable, Sendable {
    case markedFailed, alreadyFailed, terminal
}

/// A timeout changes the result but never releases the sensor transaction.
struct PhotoCaptureTransactionState: Sendable {
    let uniqueID: Int64
    private(set) var timedOut = false
    private(set) var callbackSeen = false
    private(set) var isInFlight = true

    mutating func timeout() -> PhotoCaptureTimeoutDisposition {
        guard isInFlight else { return .terminal }
        guard !timedOut else { return .alreadyFailed }
        timedOut = true
        return .markedFailed
    }

    mutating func acceptCallback(uniqueID: Int64) -> PhotoCaptureCallbackDisposition {
        guard self.uniqueID == uniqueID else { return .foreign }
        guard isInFlight else { return .terminal }
        guard !callbackSeen else { return .duplicate }
        callbackSeen = true
        return .accepted
    }

    mutating func finish(uniqueID: Int64) -> Bool {
        guard self.uniqueID == uniqueID, isInFlight else { return false }
        isInFlight = false
        return true
    }
}

/// What a Photo shutter tap would do right now.
///
/// The shutter is never disabled. A tap always reaches the camera and may fail,
/// but it must never be an unresponsive control: this value says what is in the
/// way so the UI can explain a refusal instead of silently swallowing the tap.
enum PhotoShutterReadiness: Equatable, Sendable {
    case ready
    case capturing
    case changingMode
    case cameraNotReady

    /// The attempt is always accepted; only its outcome varies.
    var attemptsCapture: Bool { true }

    /// The operator-facing reason, nil when nothing is in the way.
    var blockedReason: String? {
        switch self {
        case .ready: nil
        case .capturing: "A photo is already being captured."
        case .changingMode: "Wait for the camera to finish changing."
        case .cameraNotReady: "The photo camera is not ready yet."
        }
    }
}

enum PhotoShutterReadinessPolicy {
    static func readiness(isPhotoMode: Bool, isChangingFrameRate: Bool,
                          isChangingCaptureProfile: Bool, isCaptureBusy: Bool,
                          canCapture: Bool) -> PhotoShutterReadiness {
        guard isPhotoMode else { return .cameraNotReady }
        if isCaptureBusy { return .capturing }
        if isChangingFrameRate || isChangingCaptureProfile { return .changingMode }
        return canCapture ? .ready : .cameraNotReady
    }
}
