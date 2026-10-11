import Foundation

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
