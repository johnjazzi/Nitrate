import Foundation
import Testing

/// Autofocus at the selected circle.
///
/// The operator's contract is that a focus request starts a focus that keeps
/// correcting itself as the scene distance changes, and that tapping again is
/// not required. A committed manual focus must stay held, and a successful
/// lens/mode switch must still recentre the point. The device cannot be driven
/// from this target, so the suite has two halves: the pure mode decision
/// (`CameraAutofocusPolicy`) and a source contract for the one writer in
/// `CameraSession` that every request goes through.
@Suite("Autofocus point mode and session wiring")
struct CameraAutofocusPolicyTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func sessionSource() throws -> String {
        try source("App/Modules/CameraCapture/CameraSession.swift")
    }

    /// The body of one declaration, from its signature to the closing brace at
    /// method indentation. Nested blocks close deeper, so the first match ends
    /// the method.
    private func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature), "missing declaration: \(signature)")
        let remainder = source[start.lowerBound...]
        let end = try #require(remainder.range(of: "\n    }\n"), "unterminated declaration: \(signature)")
        return String(remainder[..<end.upperBound])
    }

    // MARK: - Mode decision

    @Test func continuousAutofocusIsPreferredAtTheSelectedPoint() {
        // Continuous autofocus keeps hunting at the chosen point; the one-shot
        // mode is what made the camera focus only on the tap.
        #expect(CameraAutofocusPolicy.mode(supportsContinuous: true, supportsSingle: true) == .continuous)
        #expect(CameraAutofocusPolicy.mode(supportsContinuous: true, supportsSingle: false) == .continuous)
    }

    @Test func oneShotAutofocusSurvivesOnlyAsTheFallback() {
        #expect(CameraAutofocusPolicy.mode(supportsContinuous: false, supportsSingle: true) == .single)
        // Neither mode means the caller must leave the device alone rather than
        // write a mode the device rejects.
        #expect(CameraAutofocusPolicy.mode(supportsContinuous: false, supportsSingle: false) == nil)
    }

    // MARK: - Shared writer

    @Test func theSharedWriterInstallsThePointThenTheContinuousMode() throws {
        let writer = try body(of: "private func writeFocusAndExposurePoint(", in: try sessionSource())
        #expect(writer.contains("Self.autofocusMode(for: device)"))
        #expect(writer.contains("device.focusMode = mode"))
        // The point must be installed first, so the mode targets the circle the
        // operator picked rather than wherever the lens was last focusing.
        let point = try #require(writer.range(of: "device.focusPointOfInterest = point"))
        let mode = try #require(writer.range(of: "device.focusMode = mode"))
        #expect(point.lowerBound < mode.lowerBound)
    }

    @Test func theModeDecisionMapsOntoTheDevicesOwnFocusModes() throws {
        let helper = try body(of: "private static func autofocusMode(for device: AVCaptureDevice)",
                              in: try sessionSource())
        #expect(helper.contains("CameraAutofocusPolicy.mode("))
        #expect(helper.contains("supportsContinuous: device.isFocusModeSupported(.continuousAutoFocus)"))
        #expect(helper.contains("supportsSingle: device.isFocusModeSupported(.autoFocus)"))
        #expect(helper.contains("case .continuous: return .continuousAutoFocus"))
        #expect(helper.contains("case .single: return .autoFocus"))
    }

    @Test func aCommittedManualFocusStillBlocksOnlyTheFocusWrite() throws {
        let writer = try body(of: "private func writeFocusAndExposurePoint(", in: try sessionSource())
        #expect(writer.contains("CameraManualFocusPolicy.allowsAutofocusOnTap("))
        #expect(writer.contains("committedLensPosition: committedManualFocusLensPosition"))
        // Metering still follows the point; the held exposure's ISO and duration
        // are not reopened here.
        #expect(writer.contains("device.exposurePointOfInterest = point"))
    }

    @Test func theFocusWriterLeavesExposureAndWhiteBalanceAlone() throws {
        let writer = try body(of: "private func writeFocusAndExposurePoint(", in: try sessionSource())
        #expect(!writer.contains("exposureMode"))
        #expect(!writer.contains("setExposureModeCustom"))
        #expect(!writer.contains("whiteBalanceMode"))
        #expect(!writer.contains("lensPosition"))
    }

    @Test func tapAndSwitchRecenterShareTheOneWriter() throws {
        let session = try sessionSource()
        for signature in ["func setFocusAndExposurePoint(_ point: CGPoint)",
                          "func recenterFocusAndExposurePoint()"] {
            let handled = try body(of: signature, in: session)
            #expect(handled.contains("self.writeFocusAndExposurePoint("),
                    "\(signature) must go through the shared writer")
            // The point-of-interest and mode writes live in one place only.
            #expect(!handled.contains("device.focusMode ="))
            #expect(!handled.contains("device.focusPointOfInterest ="))
        }
        // A successful switch recentres, which is the path that re-asserts the
        // mode on the new graph.
        #expect(try body(of: "func recenterFocusAndExposurePoint()", in: session)
            .contains("writeFocusAndExposurePoint(CameraSession.focusPointCenter, on: device)"))
    }

    @Test func leavingManualFocusUsesTheSameModeDecision() throws {
        let reset = try body(of: "func resetAutoFocus()", in: try sessionSource())
        #expect(reset.contains("Self.autofocusMode(for: device)"))
        #expect(reset.contains("device.focusMode = mode"))
        // No hard requirement on continuous support: a single-shot-only device
        // still leaves manual focus instead of silently ignoring the reset.
        #expect(!reset.contains("device.isFocusModeSupported(.continuousAutoFocus)"))
    }

    // MARK: - Debug capability trace

    @Test func autofocusRequestsTraceTheFormatsTrackingCapability() throws {
        let writer = try body(of: "private func writeFocusAndExposurePoint(", in: try sessionSource())
        #expect(writer.contains("#if DEBUG"))
        #expect(writer.contains("--trace-camera-control"))
        // One line per request: the installed/requested mode, whether a manual
        // focus gate was held, and what this format reports about tracking.
        #expect(writer.contains("isContinuousAutoFocusTrackingSupported"))
        #expect(writer.contains("manualHeld="))
        #expect(writer.contains("focusMode.rawValue"))
    }

    @Test func subjectTrackingStaysDisabled() throws {
        // Feasibility evidence only: this fix must not switch tracking on.
        let session = try sessionSource()
        #expect(!session.contains("continuousAutoFocusTrackingEnabled = true"))
        #expect(!session.contains("isContinuousAutoFocusTrackingEnabled = true"))
    }
}
