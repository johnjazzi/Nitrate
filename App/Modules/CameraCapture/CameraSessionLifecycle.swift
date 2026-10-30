import Foundation

/// Delivery identity is captured before the queue -> main hop, never on receipt.
struct CameraSessionDeliveryContext: Equatable, Sendable {
    let lifecycle: UInt64
    let controller: UInt64
}

struct CameraSessionDeliveryOwnership {
    private var lifecycle: UInt64?
    private var controller: UInt64 = 0
    mutating func activate(_ epoch: UInt64) { lifecycle = epoch; controller = 0 }
    mutating func deactivate() { lifecycle = nil }
    mutating func accepts(_ context: CameraSessionDeliveryContext) -> Bool {
        guard lifecycle == context.lifecycle, context.controller >= controller else { return false }
        controller = context.controller
        return true
    }
}

/// A deadline retires a callback token, NOT hardware. New writers remain blocked
/// until the session has explicitly stopped and reconciled the device graph.
struct CameraVideoStartupOwnership: Sendable {
    enum Kind: String, Sendable { case bias, exposure }
    struct Token: Equatable, Sendable { let epoch: UInt64; let kind: Kind }
    private var epoch: UInt64 = 0
    private(set) var active: Token?
    private(set) var requiresRecovery = false
    mutating func begin(_ kind: Kind) -> Token? {
        guard active == nil, !requiresRecovery else { return nil }
        epoch &+= 1
        let token = Token(epoch: epoch, kind: kind)
        active = token
        return token
    }
    @discardableResult mutating func finish(_ token: Token) -> Bool {
        guard active == token else { return false }
        active = nil
        return true
    }
    mutating func expire(_ token: Token) -> Bool {
        guard finish(token) else { return false }
        requiresRecovery = true
        return true
    }
    mutating func didResetStoppedSession() { active = nil; requiresRecovery = false }
}

/// This owns only UI result/watchdog delivery. It never releases a RAW sensor
/// transaction; that remains owned by the real framework terminal callback.
struct CameraPhotoResultOwnership {
    private var epoch: UInt64 = 0
    private var active: UInt64?
    mutating func begin() -> UInt64 { epoch &+= 1; active = epoch; return epoch }
    func owns(_ token: UInt64) -> Bool { active == token }
    mutating func finish(_ token: UInt64) -> Bool {
        guard owns(token) else { return false }
        active = nil
        return true
    }
    mutating func invalidate() { active = nil }
}
