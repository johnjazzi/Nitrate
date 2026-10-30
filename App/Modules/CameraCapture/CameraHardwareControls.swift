import AVFoundation

/// One light-press slider exposed through the hardware Camera Control button.
///
/// The engine is deliberately a *presentation and routing* layer only: every
/// value it reports is handed to the existing `CameraViewModel` setters, which
/// remain the single owners of device zoom/exposure. Nothing here writes to an
/// `AVCaptureDevice`, so shutter priority, photo development and persistence
/// keep their existing ownership.
///
/// Queue contract: one `CameraHardwareControls` instance is confined to the
/// capture session's serial queue. `apply(_:)`, `uninstall()` and every
/// `AVCaptureSlider` action/delegate callback run on that queue (the slider is
/// configured with `setActionQueue`), so the stored properties need no lock.

// MARK: - Request

/// What the view model asks the session for. Ranges are *not* part of the
/// request: the session resolves them from the live device, because a range
/// captured on the main actor can be stale after a lens switch.
struct CameraHardwareControlRequest: Equatable, Sendable {
    var adjustment: CameraControlAdjustment
    var isEnabled: Bool
    /// Displayed magnification (`CameraZoomSnapshot.displayFactor`).
    var displayZoom: Double
    var exposureBias: Float

    static let inactive = CameraHardwareControlRequest(
        adjustment: .off, isEnabled: false, displayZoom: 1, exposureBias: 0)
}

/// Fully resolved configuration, valid only for `cameraRevision`. The revision
/// is carried through the action callback so a value produced before a lens
/// switch can be rejected after the switch commits.
struct CameraHardwareControlConfiguration: Equatable, Sendable {
    var adjustment: CameraControlAdjustment
    var isEnabled: Bool
    var zoomRange: ClosedRange<Float>
    var zoomValue: Float
    var exposureRange: ClosedRange<Float>
    var exposureValue: Float
    var cameraRevision: UInt64

    static let inactive = CameraHardwareControlConfiguration(
        adjustment: .off, isEnabled: false,
        zoomRange: 1...1, zoomValue: 1,
        exposureRange: -3...3, exposureValue: 0,
        cameraRevision: 0)
}

// MARK: - Presentation

/// Everything the system needs to draw one slider. Pure value type so the
/// selection rules can be exercised without a capture session.
struct CameraHardwareControlSpec: Equatable, Sendable {
    let adjustment: CameraControlAdjustment
    let title: String
    let symbolName: String
    let accessibilityIdentifier: String
    /// `AVCaptureSlider.localizedValueFormat`; `%@` is the only valid
    /// placeholder.
    let valueFormat: String
}

/// Which slider transition the controller must perform.
enum CameraHardwareControlStep: Equatable, Sendable {
    case none
    case install(CameraControlAdjustment)
    case replace(CameraControlAdjustment)
    case remove
}

/// Pure selection/clamping rules for the hardware slider.
///
/// Two invariants live here:
/// * at most one slider is selected at a time (`.off`, an unsupported session,
///   or an unusable range selects none);
/// * a range is only shown when it is finite and non-degenerate, because
///   `AVCaptureSlider` throws for an inverted or empty range.
enum CameraHardwareControlPolicy {
    static let minimumRangeSpan: Float = 0.001
    static let writeEpsilon: Float = 0.0005

    static func spec(for adjustment: CameraControlAdjustment) -> CameraHardwareControlSpec? {
        switch adjustment {
        case .zoom:
            return CameraHardwareControlSpec(
                adjustment: .zoom, title: "Zoom", symbolName: "plus.magnifyingglass",
                accessibilityIdentifier: "cameraControl.zoom", valueFormat: "%@x")
        case .exposure:
            return CameraHardwareControlSpec(
                adjustment: .exposure, title: "Exposure", symbolName: "plusminus.circle",
                accessibilityIdentifier: "cameraControl.exposure", valueFormat: "%@ EV")
        case .off:
            return nil
        }
    }

    /// A range is usable only when both bounds are finite and it spans more
    /// than `minimumRangeSpan`. Tongue of the same rule in reverse: the
    /// controller shows no slider rather than a slider with one position.
    static func validated(_ range: ClosedRange<Float>) -> ClosedRange<Float>? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound - range.lowerBound >= minimumRangeSpan else { return nil }
        return range
    }

    /// Range the selected adjustment would present, or nil when the adjustment
    /// must not be shown.
    static func sliderRange(for adjustment: CameraControlAdjustment,
                            zoom: ClosedRange<Float>,
                            exposure: ClosedRange<Float>) -> ClosedRange<Float>? {
        switch adjustment {
        case .zoom: return validated(zoom)
        case .exposure: return validated(exposure)
        case .off: return nil
        }
    }

    /// Starting value, clamped into the presented range.
    static func sliderValue(for adjustment: CameraControlAdjustment,
                            zoomValue: Float,
                            exposureValue: Float,
                            zoomRange: ClosedRange<Float>,
                            exposureRange: ClosedRange<Float>) -> Float? {
        switch adjustment {
        case .zoom: return clamped(zoomValue, to: validated(zoomRange))
        case .exposure: return clamped(exposureValue, to: validated(exposureRange))
        case .off: return nil
        }
    }

    static func clamped(_ value: Float, to range: ClosedRange<Float>?) -> Float? {
        guard let range, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// True when pushing `desired` would visibly move the slider. Programmatic
    /// writes below one slider pixel would only fight the finger.
    static func needsWrite(current: Float, desired: Float) -> Bool {
        guard current.isFinite, desired.isFinite else { return false }
        return abs(current - desired) > writeEpsilon
    }

    /// The adjustment a session may actually present right now.
    static func selectedAdjustment(_ adjustment: CameraControlAdjustment,
                                   supportsControls: Bool,
                                   range: ClosedRange<Float>?) -> CameraControlAdjustment? {
        guard supportsControls, adjustment != .off, range != nil,
              spec(for: adjustment) != nil else { return nil }
        return adjustment
    }

    /// `AVCaptureSlider` bounds are immutable, so a slider built for one lens
    /// window must be rebuilt when the window itself moves (a lens or format
    /// switch changes the usable magnification span).
    static func needsRebuild(installed: CameraControlAdjustment?,
                             installedRange: ClosedRange<Float>?,
                             selected: CameraControlAdjustment?,
                             selectedRange: ClosedRange<Float>?) -> Bool {
        guard let installed, let selected, installed == selected,
              let selectedRange else { return false }
        return installedRange != selectedRange
    }

    /// Exactly one slider, or none.
    static func step(installed: CameraControlAdjustment?,
                     selected: CameraControlAdjustment?) -> CameraHardwareControlStep {
        switch (installed, selected) {
        case (nil, nil): return .none
        case (nil, .some(let adjustment)): return .install(adjustment)
        case (.some, nil): return .remove
        case (.some(let installed), .some(let selected)):
            return installed == selected ? .none : .replace(selected)
        }
    }
}

// MARK: - Controller

/// Owns the single `AVCaptureSlider` added to the capture session and is the
/// session's `AVCaptureSessionControlsDelegate`.
///
/// The delegate is mandatory for controls to become active and is held
/// *weakly* by `AVCaptureSession`, so `CameraSession` keeps this object alive.
@available(iOS 18.0, macOS 15.0, macCatalyst 18.0, tvOS 18.0, *)
final class CameraHardwareControls: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    /// Called on the session queue with the slider's value and the camera
    /// revision that was installed when the slider was last resolved.
    var onValueChange: (@Sendable (CameraControlAdjustment, Float, UInt64) -> Void)?
    /// Called on the session queue when the system controls become active or
    /// are dismissed. The parent UI uses it to clear its own chrome.
    var onInteractionChange: (@Sendable (Bool) -> Void)?

    private let session: AVCaptureSession
    private let queue: DispatchQueue
    private var slider: AVCaptureSlider?
    private(set) var installedAdjustment: CameraControlAdjustment?
    private var installedRevision: UInt64 = 0
    private var installedRange: ClosedRange<Float>?
    private var isDelegateAttached = false
    /// Bumped on every install/remove so a queued action from a slider that has
    /// already been retired is rejected instead of applied to its successor.
    private var generation: UInt64 = 0
    private(set) var isUserInteracting = false

    init(session: AVCaptureSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
        super.init()
    }

    /// Reconciles the installed slider with `configuration`. Runs on the
    /// session queue; safe to call on every zoom snapshot publish.
    func apply(_ configuration: CameraHardwareControlConfiguration) {
        dispatchPrecondition(condition: .onQueue(queue))
        let range = CameraHardwareControlPolicy.sliderRange(
            for: configuration.adjustment, zoom: configuration.zoomRange,
            exposure: configuration.exposureRange)
        // A control is only presented while its graph is running, so a slider
        // can never outlive the session it drives.
        let selected = CameraHardwareControlPolicy.selectedAdjustment(
            configuration.adjustment,
            supportsControls: session.supportsControls && session.isRunning,
            range: range)
        installedRevision = configuration.cameraRevision
        if CameraHardwareControlPolicy.needsRebuild(
            installed: installedAdjustment, installedRange: installedRange,
            selected: selected, selectedRange: range) {
            removeSlider()
        }

        switch CameraHardwareControlPolicy.step(installed: installedAdjustment, selected: selected) {
        case .none:
            break
        case .remove:
            removeSlider()
        case .install(let adjustment), .replace(let adjustment):
            removeSlider()
            if let range,
               let value = CameraHardwareControlPolicy.sliderValue(
                    for: adjustment, zoomValue: configuration.zoomValue,
                    exposureValue: configuration.exposureValue,
                    zoomRange: configuration.zoomRange,
                    exposureRange: configuration.exposureRange) {
                installSlider(adjustment: adjustment, range: range, value: value)
            }
        }

        guard let slider, let installedRange else { return }
        if let value = CameraHardwareControlPolicy.sliderValue(
            for: configuration.adjustment, zoomValue: configuration.zoomValue,
            exposureValue: configuration.exposureValue,
            zoomRange: configuration.zoomRange,
            exposureRange: configuration.exposureRange),
           CameraHardwareControlPolicy.needsWrite(current: slider.value, desired: value) {
            slider.value = min(max(value, installedRange.lowerBound), installedRange.upperBound)
        }
        slider.isEnabled = configuration.isEnabled && selected != nil
    }

    /// Removes the slider and drops the delegate. Called when the capture
    /// session tears down so a stale control cannot linger in the system UI.
    func uninstall() {
        dispatchPrecondition(condition: .onQueue(queue))
        removeSlider()
        if isDelegateAttached {
            session.setControlsDelegate(nil, queue: nil)
            isDelegateAttached = false
        }
        isUserInteracting = false
    }

    // MARK: Slider lifecycle

    private func installSlider(adjustment: CameraControlAdjustment,
                               range: ClosedRange<Float>,
                               value: Float) {
        guard let spec = CameraHardwareControlPolicy.spec(for: adjustment) else { return }
        generation &+= 1
        let generation = self.generation
        let slider = AVCaptureSlider(spec.title, symbolName: spec.symbolName, in: range)
        slider.accessibilityIdentifier = spec.accessibilityIdentifier
        slider.localizedValueFormat = spec.valueFormat
        slider.value = min(max(value, range.lowerBound), range.upperBound)
        // The action queue must share the session's exclusive execution
        // context, or the value it routes back would race device writes.
        // It must be set before `canAddControl`/`addControl`.
        slider.setActionQueue(queue) { [weak self] newValue in
            self?.handleActionValue(newValue, adjustment: adjustment, generation: generation)
        }
        guard session.canAddControl(slider) else {
            // A platform that reports support but refuses the control gets no
            // slider rather than a silently dead one.
            return
        }
        attachDelegateIfNeeded()
        session.addControl(slider)
        self.slider = slider
        installedAdjustment = adjustment
        installedRange = range
    }

    private func removeSlider() {
        generation &+= 1
        guard let slider else {
            installedAdjustment = nil
            installedRange = nil
            return
        }
        session.removeControl(slider)
        self.slider = nil
        installedAdjustment = nil
        installedRange = nil
    }

    private func attachDelegateIfNeeded() {
        guard !isDelegateAttached else { return }
        session.setControlsDelegate(self, queue: queue)
        isDelegateAttached = true
    }

    private func handleActionValue(_ value: Float,
                                   adjustment: CameraControlAdjustment,
                                   generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == self.generation,
              installedAdjustment == adjustment,
              let slider, slider.isEnabled,
              let range = installedRange,
              let clamped = CameraHardwareControlPolicy.clamped(value, to: range) else { return }
        onValueChange?(adjustment, clamped, installedRevision)
    }

    // MARK: AVCaptureSessionControlsDelegate

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        isUserInteracting = true
        onInteractionChange?(true)
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        onInteractionChange?(true)
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        onInteractionChange?(true)
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        isUserInteracting = false
        onInteractionChange?(false)
    }
}