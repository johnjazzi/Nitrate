import Foundation

/// Queue-confined logical ownership of noncapture camera setters. A deadline
/// invalidates only its own acknowledgement lease; it does NOT prove that a
/// physical device operation (and especially a RAW capture) has terminated.
struct PhotoExposureOperationOwnership {
    enum Kind: Hashable, Sendable { case custom, bias }
    struct Token: Hashable, Sendable {
        let id: UInt64
        let kind: Kind
    }

    private var nextID: UInt64 = 0
    private var deadlines: [Token: TimeInterval] = [:]
    private var stopped = false
    private(set) var requiresRecovery = false
    private var lastAppliedAt: TimeInterval?
    private var lastMeteringReadAt: TimeInterval?

    var customPending: Bool { deadlines.keys.contains { $0.kind == .custom } }
    var biasPendingCount: Int { deadlines.keys.filter { $0.kind == .bias }.count }

    /// A bias reset and a custom write may be part of the same transaction, but
    /// a second operation of either kind cannot replace that kind's live lease.
    /// Recovery admission is separately enforced by the controller; keeping token
    /// retirement independent also fences callbacks across recovery ordering.
    mutating func begin(_ kind: Kind, now: TimeInterval) -> Token? {
        guard !stopped, !deadlines.keys.contains(where: { $0.kind == kind }) else { return nil }
        nextID &+= 1
        let token = Token(id: nextID, kind: kind)
        deadlines[token] = now + PhotoExposureCadence.setterTimeout
        return token
    }

    @discardableResult
    mutating func acknowledge(_ token: Token, now: TimeInterval) -> Bool {
        guard deadlines.removeValue(forKey: token) != nil else { return false }
        // Use queue receipt time conservatively, rather than mixing a CMTime
        // device clock with monotonic uptime or trusting a pre-ACK meter sample.
        noteApplied(now: now)
        return true
    }

    @discardableResult
    mutating func expire(_ token: Token, now: TimeInterval) -> Bool {
        guard let deadline = deadlines[token], now >= deadline else { return false }
        deadlines.removeValue(forKey: token)
        // A readable installed value is NOT proof that an unacknowledged setter
        // cannot mutate hardware later. The controller must stop issuing writes
        // and ask its session owner for an explicit stop/reconfigure boundary.
        requiresRecovery = true
        noteApplied(now: now)
        return true
    }

    mutating func stop() { stopped = true }

    func canDrain(capturing: Bool) -> Bool {
        // Logical setters may expire, but an entered RAW owner never does. The
        // session must inspect requiresRecovery before it reuses the device.
        stopped && deadlines.isEmpty && !capturing
    }

    mutating func noteApplied(now: TimeInterval) {
        lastAppliedAt = max(lastAppliedAt ?? now, now)
    }

    mutating func noteMeteringRead(now: TimeInterval) {
        lastMeteringReadAt = max(lastMeteringReadAt ?? now, now)
    }

    func meteringReady(now: TimeInterval, duration: Double) -> Bool {
        guard !requiresRecovery, deadlines.isEmpty else { return false }
        let interval = PhotoExposureCadence.measurementInterval(duration: duration)
        if let lastAppliedAt, now < lastAppliedAt + interval { return false }
        if let lastMeteringReadAt, now < lastMeteringReadAt + interval { return false }
        return true
    }
}
