import AVFoundation
import Foundation

/// What the LED did when it was asked for a level.
///
/// Every level is a *request*: the hardware refuses on its own terms (the phone
/// too hot, most often) and a refusal is reported, never worked around. There is
/// deliberately no "try a dimmer value" case — a silently dimmer lamp would make
/// the file's metadata a lie.
enum FlashTorchResult: Equatable, Sendable {
    case lit(level: Double)
    case off
    /// This camera has no lamp, or the lamp cannot be turned on at all.
    case unavailable(reason: String)
    /// The hardware rejected the request.
    case refused(reason: String)

    var isLit: Bool {
        if case .lit = self { return true }
        return false
    }

    var refusalReason: String? {
        switch self {
        case .lit, .off: return nil
        case .unavailable(let reason), .refused(let reason): return reason
        }
    }
}

/// The one seam between the app and the LED.
protocol FlashTorchDriving: AnyObject {
    var isAvailable: Bool { get }
    @discardableResult func setLevel(_ level: Double) -> FlashTorchResult
    func turnOff()
}

/// The only place in the app that touches the torch.
///
/// Video uses this adjustable continuous torch. Stills use native photo flash
/// instead, with the torch extinguished before submitting their request.
///
/// The device is locked for the write and unlocked immediately; `turnOff` is
/// idempotent and safe to call from any of the lifecycle points that must
/// guarantee the lamp is dark (take stop, take failure, capture completion,
/// view disappear, deinit).
final class FlashTorchController: FlashTorchDriving {
    private let device: AVCaptureDevice

    init(device: AVCaptureDevice) {
        self.device = device
    }

    /// A lens without a lamp is not a disabled control, it is no control.
    var isAvailable: Bool { device.hasTorch && device.isTorchModeSupported(.on) }

    @discardableResult
    func setLevel(_ level: Double) -> FlashTorchResult {
        guard isAvailable else { return .unavailable(reason: FlashTorchController.noLampReason) }
        guard level.isFinite else {
            return .refused(reason: "The lamp level was not a number.")
        }
        let clamped = min(max(level, 0), 1)
        guard clamped > 0 else {
            turnOff()
            return .off
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return .refused(reason: "The camera could not be locked for the lamp.")
        }
        defer { device.unlockForConfiguration() }
        do {
            try device.setTorchModeOn(level: Float(clamped))
            return .lit(level: clamped)
        } catch {
            // The request was refused. Put the lamp out and say so: substituting
            // a lower level would deliver a file whose intensity is not the one
            // it records.
            device.torchMode = .off
            return .refused(reason: Self.refusalReason(error, requested: clamped))
        }
    }

    /// Unconditional, except when the lamp is already out. Errors are swallowed
    /// on purpose: the caller is a teardown path, and a throw here would leave
    /// the torch on rather than off.
    func turnOff() {
        guard device.hasTorch, device.torchMode != .off else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.torchMode = .off
    }

    deinit {
        turnOff()
    }

    static let noLampReason = "This camera has no lamp."

    private static func refusalReason(_ error: Error, requested: Double) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain,
           nsError.code == AVError.Code.torchLevelUnavailable.rawValue {
            return "The lamp is too hot to run at \(Int((requested * 100).rounded()))%. "
                + "Let the phone cool, then try again."
        }
        return "The camera refused the lamp: \(error.localizedDescription)"
    }
}
