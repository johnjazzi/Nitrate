import Observation
import SwiftUI
import UIKit

/// Physical orientation for camera glyphs; the interface remains portrait-locked.
/// Scene orientation cannot supply this value because a locked scene never turns.
@MainActor
@Observable
final class CameraOrientationObserver {
    static let shared = CameraOrientationObserver()

    private(set) var deviceOrientation: UIDeviceOrientation = .portrait
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        refresh()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIDevice.orientationDidChangeNotification,
            UIApplication.didBecomeActiveNotification
        ]
        // Shared for the app lifetime; notification tokens live with the observer.
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func refresh() {
        let next = UIDevice.current.orientation
        switch next {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            deviceOrientation = next
        default:
            // Laying the phone flat or an unavailable sensor reading must not
            // reset the last stable portrait/landscape glyph orientation.
            break
        }
    }
}

private struct CameraDeviceOrientationKey: EnvironmentKey {
    static let defaultValue: UIDeviceOrientation = .portrait
}

extension EnvironmentValues {
    var cameraDeviceOrientation: UIDeviceOrientation {
        get { self[CameraDeviceOrientationKey.self] }
        set { self[CameraDeviceOrientationKey.self] = newValue }
    }
}

/// Presentation only: neither control placement nor its touch rectangle changes.
enum CameraGlyphRotation {
    /// Apple defines device landscapeLeft as the front camera/device top on the
    /// left, i.e. the phone turned counterclockwise. SwiftUI positive rotation
    /// is clockwise, so +90 cancels that physical turn; right needs -90.
    /// See UIDeviceOrientation.landscapeLeft and View.rotationEffect docs.
    static func degrees(for orientation: UIDeviceOrientation) -> Double {
        switch orientation {
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portraitUpsideDown: return 180
        default: return 0
        }
    }
}

private struct CameraUprightModifier: ViewModifier {
    @Environment(\.cameraDeviceOrientation) private var orientation

    func body(content: Content) -> some View {
        let degrees = CameraGlyphRotation.degrees(for: orientation)
        // A long readout cannot simply turn inside a shallow cell: fit its
        // rendered glyphs back into that same cell, without changing layout.
        content.visualEffect { effect, geometry in
            let size = geometry.size
            let isQuarterTurn = abs(degrees) == 90
            let fit = isQuarterTurn && size.width > 0 && size.height > 0
                ? min(1, min(size.width / size.height, size.height / size.width)) : 1
            return effect
                .rotationEffect(.degrees(degrees))
                .scaleEffect(fit)
        }
    }
}

extension View {
    /// Apply only to glyphs, before their panel/background, never to a control.
    func cameraUpright() -> some View {
        modifier(CameraUprightModifier())
    }
}
