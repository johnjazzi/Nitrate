import CoreGraphics
import Foundation
import Testing

/// The still's physical hold is frozen at the shutter tap and carried, as a
/// quarter-turn connection angle, to the photo request. The photo output is the
/// only place that can set it: `CIRAWFilter` already uprights the DNG's own EXIF
/// orientation, so the renderer must never rotate the image again.
@Suite("Still capture orientation")
struct PhotoCaptureOrientationTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func connectionAngleSnapsToAValidQuarterTurn() {
        // Only 0/90/180/270 are valid connection angles. A coordinator angle that
        // arrives a hair off, or negative, must still be applied as a quarter turn
        // rather than written back and refused by the framework.
        let cases: [(CGFloat, CGFloat)] = [
            (0, 0), (90, 90), (180, 180), (270, 270),
            (-90, 270), (359, 0), (271, 270), (45, 90)
        ]
        for (requested, expected) in cases {
            #expect(PhotoCaptureRotationPolicy.connectionAngle(requested) == expected,
                    "\(requested)° must normalize to \(expected)°")
        }
    }

    @Test func unusableAnglesAreNeverApplied() {
        #expect(PhotoCaptureRotationPolicy.connectionAngle(nil) == nil)
        #expect(PhotoCaptureRotationPolicy.connectionAngle(.nan) == nil)
        #expect(PhotoCaptureRotationPolicy.connectionAngle(.infinity) == nil)
    }

    @Test func manifestRecordsRequestedAppliedAndSupport() {
        #expect(PhotoCaptureRotationPolicy.evidence(requested: 90, applied: 90, supported: true)
            == ["rotationAngleRequested": "90", "rotationAngleApplied": "90",
                "rotationAngleSupported": "true"])
        // An unsupported request must be reported as such, with the angle that is
        // still actually installed, instead of looking like a successful turn.
        let rejected = PhotoCaptureRotationPolicy.evidence(requested: 270, applied: 0, supported: false)
        #expect(rejected["rotationAngleRequested"] == "270")
        #expect(rejected["rotationAngleApplied"] == "0")
        #expect(rejected["rotationAngleSupported"] == "false")
        // Smoke/debug callers pass no frozen angle and must still state that.
        #expect(PhotoCaptureRotationPolicy.evidence(requested: nil, applied: nil, supported: nil)
            == ["rotationAngleRequested": "none", "rotationAngleApplied": "none",
                "rotationAngleSupported": "unavailable"])
    }

    @Test func pendingRequestKeepsTheAngleFrozenAtTheTap() {
        // A tap that has to wait for an exposure write must keep the angle that was
        // frozen at the tap, not re-read the device when the write lands.
        let waiting = PendingPhotoCaptureRequest(rotationAngle: 270) { _ in }
        #expect(waiting.rotationAngle == 270)
        #expect(PendingPhotoCaptureRequest(rotationAngle: nil) { _ in }.rotationAngle == nil)
    }

    @Test func captureAppliesTheAngleImmediatelyBeforeTheRequest() throws {
        let capture = try source("App/Modules/CameraCapture/CameraPhotoCapture.swift")
        let applied = try #require(capture.range(of: "        applyCaptureRotation()"),
                                   "the photo connection must take the frozen angle")
        let request = try #require(capture.range(of: "output.capturePhoto(with: settings, delegate: self)"),
                                   "the capture request must still be issued")
        #expect(applied.lowerBound < request.lowerBound,
                "the connection angle must be installed before capturePhoto")
        #expect(capture.contains("isVideoRotationAngleSupported(requested)"),
                "the requested angle must be checked for support before it is written")
    }

    @Test func manifestAllowlistCarriesTheRotationEvidence() throws {
        let capture = try source("App/Modules/CameraCapture/CameraPhotoCapture.swift")
        let allowlist = try #require(capture.range(of: "private func writeManifest"))
        let tail = String(capture[allowlist.lowerBound...])
        for key in ["\"rotationAngleRequested\"", "\"rotationAngleApplied\"", "\"rotationAngleSupported\""] {
            #expect(tail.contains(key), "\(key) must survive into capture.json")
        }
    }

    @Test func everyPendingResumePathForwardsTheFrozenAngle() throws {
        let controller = try source("App/Modules/CameraCapture/DevelopmentPhotoController.swift")
        // The setter acknowledgement, the impatient force, and the exposure tick
        // are the three ways a waiting tap resumes; all must carry the angle.
        let forwarded = controller.components(separatedBy: "rotationAngle: pending.rotationAngle").count - 1
        #expect(forwarded >= 3,
                "setter, impatience and tick resume paths must all forward the frozen angle (found \(forwarded))")
        #expect(controller.contains("rotationAngle: rotationAngle"),
                "the controller must hand the angle to CameraPhotoCapture")
    }

    @Test func sessionResolvesTheFrozenOrientationIntoAConnectionAngle() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        #expect(session.contains("frozenOrientation: CameraSampleValidationPolicy.DeliveryOrientation? = nil"),
                "the still entry point must accept the orientation frozen at the tap")
        #expect(session.contains("captureRotationAngle(for: frozenOrientation ?? .unknown)"),
                "the frozen orientation must resolve through the existing session policy")
        #expect(session.contains("controller.capture(rotationAngle: rotationAngle"),
                "the resolved angle must reach the development controller")
    }

    @Test func shutterTapPassesTheObserverOrientation() throws {
        let viewModel = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(viewModel.contains("CameraOrientationObserver.shared.deliveryOrientation"),
                "the shutter tap must freeze the physical hold through the existing observer")
        #expect(viewModel.contains("session.captureDevelopmentPhoto(frozenOrientation: frozenOrientation)"),
                "the frozen orientation must reach the session")
        // Smoke/debug callers keep their existing no-argument form.
        #expect(viewModel.components(separatedBy: "session.captureDevelopmentPhoto {").count - 1 >= 2,
                "debug smoke capture callers must keep the default optional orientation")
    }
}
