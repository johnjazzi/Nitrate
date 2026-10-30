import AVFoundation
import Foundation
import Testing

/// Pure-policy coverage for the hardware Camera Control slider.
///
/// These are source-contract tests: they pin the rules the controller relies on
/// (`AVCaptureSlider` throws on an inverted or empty range, accepts exactly one
/// control per session, and needs an action + queue before `canAddControl`).
/// Anything that needs a live `AVCaptureSession` — delegate activation, the
/// slider's own appearance, the Camera Control button gesture — is runtime and
/// is not asserted here.
struct CameraHardwareControlsTests {
    // MARK: Presentation

    @Test func zoomSelectionPresentsOneZoomSlider() throws {
        let spec = try #require(CameraHardwareControlPolicy.spec(for: .zoom))
        #expect(spec.adjustment == .zoom)
        #expect(spec.title == "Zoom")
        #expect(spec.symbolName == "plus.magnifyingglass")
        #expect(spec.accessibilityIdentifier == "cameraControl.zoom")
        #expect(spec.valueFormat.contains("%@"))
    }

    @Test func exposureSelectionPresentsOneExposureSlider() throws {
        let spec = try #require(CameraHardwareControlPolicy.spec(for: .exposure))
        #expect(spec.adjustment == .exposure)
        #expect(spec.title == "Exposure")
        #expect(spec.accessibilityIdentifier == "cameraControl.exposure")
    }

    /// Negative control: `.off` never presents a slider, so the screen cannot
    /// end up with two controls — or a leftover one — after the preference is
    /// set back to Off.
    @Test func offSelectionPresentsNoSlider() {
        #expect(CameraHardwareControlPolicy.spec(for: .off) == nil)
        #expect(CameraHardwareControlPolicy.sliderRange(for: .off, zoom: 1...5, exposure: -3...3) == nil)
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .off, zoomValue: 2, exposureValue: 0, zoomRange: 1...5, exposureRange: -3...3) == nil)
    }

    /// Every selectable adjustment maps to exactly one spec, and Off to none.
    @Test func exactlyOneSliderPerSelectedAdjustment() {
        // Enumerated explicitly: the settings module owns `CaseIterable`, and the
        // slider must stay exactly-one-per-selection even if it is not conformed.
        let adjustments: [CameraControlAdjustment] = [.zoom, .exposure, .off]
        let specs = adjustments.compactMap(CameraHardwareControlPolicy.spec(for:))
        #expect(specs.count == 2)
        #expect(Set(specs.map(\.accessibilityIdentifier)).count == specs.count)
        #expect(Set(specs.map(\.adjustment)).count == specs.count)
    }

    // MARK: Range validation

    @Test func finiteNonDegenerateRangeIsAccepted() throws {
        let range = try #require(CameraHardwareControlPolicy.validated(1...5))
        #expect(range == 1...5)
    }

    /// `AVCaptureSlider` throws `NSInvalidArgumentException` when minimum is not
    /// less than maximum, so an empty or inverted range must select no slider.
    /// `ClosedRange` itself cannot represent an inverted or NaN range (its own
    /// initializer traps), so the "min must be less than max" contract of
    /// `AVCaptureSlider` is already enforced by the type upstream. What remains
    /// ours to guard is a range that is ordered but has no usable span: the
    /// slider would be a single dead position.
    @Test func zeroSpanRangeIsRejected() {
        #expect(CameraHardwareControlPolicy.validated(2...2) == nil)
        #expect(CameraHardwareControlPolicy.validated(1...(1 + 0.0001)) == nil)
        #expect(CameraHardwareControlPolicy.validated(1...(1.01)) == 1...1.01)
    }

    @Test func rangeFollowsTheSelectedAdjustment() {
        #expect(CameraHardwareControlPolicy.sliderRange(for: .zoom, zoom: 1...5, exposure: -2...2) == 1...5)
        #expect(CameraHardwareControlPolicy.sliderRange(for: .exposure, zoom: 1...5, exposure: -2...2) == -2...2)
        // A degenerate zoom window must not fall back to the exposure range.
        #expect(CameraHardwareControlPolicy.sliderRange(for: .zoom, zoom: 1...1, exposure: -2...2) == nil)
    }

    // MARK: Values

    @Test func valueIsClampedIntoThePresentedRange() throws {
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .zoom, zoomValue: 9, exposureValue: 0, zoomRange: 1...5, exposureRange: -3...3) == 5)
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .zoom, zoomValue: 0.2, exposureValue: 0, zoomRange: 1...5, exposureRange: -3...3) == 1)
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .exposure, zoomValue: 1, exposureValue: -9, zoomRange: 1...5, exposureRange: -3...3) == -3)
    }

    @Test func nonFiniteValueIsNotPushedToTheSlider() {
        #expect(CameraHardwareControlPolicy.sliderValue(
            for: .zoom, zoomValue: .nan, exposureValue: 0,
            zoomRange: 1...5, exposureRange: -3...3) == nil)
        #expect(CameraHardwareControlPolicy.clamped(.infinity, to: 1...5) == nil)
    }

    /// Programmatic sync must not fight the finger: sub-pixel differences are
    /// not written back to the system slider.
    @Test func onlyVisibleChangesAreWritten() {
        #expect(CameraHardwareControlPolicy.needsWrite(current: 2.0, desired: 2.1))
        #expect(!CameraHardwareControlPolicy.needsWrite(current: 2.0, desired: 2.0001))
        #expect(!CameraHardwareControlPolicy.needsWrite(current: .nan, desired: 2))
        #expect(!CameraHardwareControlPolicy.needsWrite(current: 2, desired: .nan))
    }

    // MARK: Selection / reconciliation

    @Test func unsupportedSessionSelectsNothing() {
        #expect(CameraHardwareControlPolicy.selectedAdjustment(
            .zoom, supportsControls: false, range: 1...5) == nil)
        #expect(CameraHardwareControlPolicy.selectedAdjustment(
            .zoom, supportsControls: true, range: 1...5) == .zoom)
    }

    @Test func offOrUnusableRangeSelectsNothingEvenWhenSupported() {
        #expect(CameraHardwareControlPolicy.selectedAdjustment(
            .off, supportsControls: true, range: 1...5) == nil)
        #expect(CameraHardwareControlPolicy.selectedAdjustment(
            .exposure, supportsControls: true, range: nil) == nil)
    }

    // MARK: Interaction state

    /// A user's finger owns the slider while the controls are active: the
    /// controller must not write a value underneath it. The moment the
    /// preference is switched off, that ownership is gone, so the state must
    /// reset or every later sync would be suppressed forever.
    @Test func disablingTheControlResetsInteraction() {
        var interaction = CameraHardwareControlInteraction()
        interaction.becameActive()
        #expect(interaction.isUserInteracting)
        #expect(!interaction.allowsProgrammaticWrite)

        let reset = interaction.applyConfiguration(isEnabled: false, hasInstalledControl: true)
        #expect(reset)
        #expect(!interaction.isUserInteracting)
        #expect(interaction.allowsProgrammaticWrite)
    }

    /// Removing or uninstalling the slider also ends the interaction, even if
    /// the system never sends `didBecomeInactive` (for example on session
    /// teardown or a lens rebuild that retires the control).
    @Test func removingTheControlResetsInteraction() {
        var interaction = CameraHardwareControlInteraction()
        interaction.becameActive()
        let reset = interaction.applyConfiguration(isEnabled: true, hasInstalledControl: false)
        #expect(reset)
        #expect(!interaction.isUserInteracting)
        #expect(interaction.allowsProgrammaticWrite)

        interaction.becameActive()
        interaction.reset()
        #expect(!interaction.isUserInteracting)
    }

    /// An enabled configuration that still has its control must preserve the
    /// active interaction; a routine zoom publish must not release the finger.
    @Test func enabledConfigurationKeepsAnActiveInteraction() {
        var interaction = CameraHardwareControlInteraction()
        interaction.becameActive()
        let reset = interaction.applyConfiguration(isEnabled: true, hasInstalledControl: true)
        #expect(!reset)
        #expect(interaction.isUserInteracting)
        #expect(!interaction.allowsProgrammaticWrite)
    }

    /// Leaving fullscreen restores app chrome but must not claim the controls
    /// are inactive: the system sends `didBecomeInactive` afterwards, and a
    /// value write while the finger is still down would fight it.
    @Test func leavingFullscreenDoesNotEndTheActiveInteraction() {
        let queue = DispatchQueue(label: "test.hardwareControls.fullscreen")
        let controls = CameraHardwareControls(session: AVCaptureSession(), queue: queue)
        let reported = BoolRecorder()
        controls.onInteractionChange = { reported.append($0) }
        let session = AVCaptureSession()

        controls.sessionControlsDidBecomeActive(session)
        controls.sessionControlsWillExitFullscreenAppearance(session)

        #expect(controls.isUserInteracting)
        #expect(reported.values == [true, false])
    }

    /// Switching the preference off (or tearing the session down) must clear
    /// the finger-owned state even when the system never sends
    /// `didBecomeInactive`, or every later sync stays suppressed.
    @Test func disablingOrUninstallingEndsTheInteraction() {
        let queue = DispatchQueue(label: "test.hardwareControls.reset")
        let controls = CameraHardwareControls(session: AVCaptureSession(), queue: queue)
        let reported = BoolRecorder()
        controls.onInteractionChange = { reported.append($0) }

        controls.sessionControlsDidBecomeActive(AVCaptureSession())
        queue.sync { controls.apply(.inactive) }
        #expect(!controls.isUserInteracting)
        #expect(reported.values == [true, false])

        controls.sessionControlsDidBecomeActive(AVCaptureSession())
        queue.sync { controls.uninstall() }
        #expect(!controls.isUserInteracting)
        #expect(reported.values == [true, false, true, false])
    }

    @Test func reconciliationInstallsReplacesRemovesOrLeavesAlone() {
        #expect(CameraHardwareControlPolicy.step(installed: nil, selected: nil) == .none)
        #expect(CameraHardwareControlPolicy.step(installed: nil, selected: .zoom) == .install(.zoom))
        #expect(CameraHardwareControlPolicy.step(installed: .zoom, selected: .zoom) == .none)
        #expect(CameraHardwareControlPolicy.step(installed: .zoom, selected: .exposure) == .replace(.exposure))
        #expect(CameraHardwareControlPolicy.step(installed: .exposure, selected: nil) == .remove)
    }

    /// A lens switch moves the magnification window. The installed slider's
    /// bounds are immutable, so the same selection at new bounds must be rebuilt
    /// rather than kept at the old rail.
    @Test func sliderIsRebuiltWhenTheLensWindowMoves() {
        #expect(CameraHardwareControlPolicy.needsRebuild(
            installed: .zoom, installedRange: 1...5, selected: .zoom, selectedRange: 1...16))
        #expect(!CameraHardwareControlPolicy.needsRebuild(
            installed: .zoom, installedRange: 1...5, selected: .zoom, selectedRange: 1...5))
        // A different adjustment is already a replace, not a rebuild.
        #expect(!CameraHardwareControlPolicy.needsRebuild(
            installed: .zoom, installedRange: 1...5, selected: .exposure, selectedRange: -3...3))
        #expect(!CameraHardwareControlPolicy.needsRebuild(
            installed: .zoom, installedRange: 1...5, selected: .zoom, selectedRange: nil))
    }

    /// Enabled is a property of the request, never of the selection: a disabled
    /// slider stays installed so the same control reappears after a transition.
    @Test func requestCarriesTheSelectionIndependentlyOfEnabled() {
        let request = CameraHardwareControlRequest(
            adjustment: .zoom, isEnabled: false, displayZoom: 2.5, exposureBias: -0.5)
        #expect(request.adjustment == .zoom)
        #expect(!request.isEnabled)
        #expect(CameraHardwareControlPolicy.selectedAdjustment(
            request.adjustment, supportsControls: true, range: 1...5) == .zoom)
        #expect(CameraHardwareControlRequest.inactive.adjustment == .off)
        #expect(!CameraHardwareControlRequest.inactive.isEnabled)
    }
}

/// Synchronous recorder for the controller's interaction callback. The callback
/// is invoked on the queue that drives the controller, which the tests call
/// synchronously, so no locking is needed.
private final class BoolRecorder: @unchecked Sendable {
    private(set) var values: [Bool] = []

    func append(_ value: Bool) { values.append(value) }
}
