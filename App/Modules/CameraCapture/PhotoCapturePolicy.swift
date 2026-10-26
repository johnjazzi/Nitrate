import Foundation

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
