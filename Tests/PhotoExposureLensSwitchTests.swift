import Foundation
import Testing

/// A take that was never in trouble, reported as though it were.
///
/// Changing the aperture and then switching lens left the old lens's stop in the
/// photo exposure intent. The next write asked the new lens for a stop it does
/// not report, threw `unsupportedMode`, and surfaced at the top of the camera as
/// "Apple Log 2 HEVC Main10 recording is unavailable. Photo exposure update
/// failed: unsupportedMode" — a recording error for a live preview with nothing
/// wrong with it.
struct PhotoExposureLensSwitchTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }

    /// The intent crosses lenses; a stop does not. Restoring it is where the
    /// stale value used to reach the device unexamined.
    @Test func theRestoredIntentIsReconciledToTheLensThatWillHoldIt() throws {
        let controller = try source("App/Modules/CameraCapture/DevelopmentPhotoController.swift")
        #expect(!controller.contains("apertureIntent = intent.aperture"))
        #expect(controller.contains("apertureIntent = heldAperture(intent.aperture)"))
        #expect(controller.contains("CameraAperturePolicy.heldAperture(requested,"))
        // A deliberate choice goes through the same reconciliation.
        #expect(controller.contains("apertureIntent = heldAperture(aperture)"))
    }

    /// The session prints and applies the aperture it holds, so the shared idle
    /// install and the camera change both reconcile the carried-over stop.
    @Test func theSessionReconcilesTheApertureItCarriesAcrossLenses() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        #expect(session.contains(
            "selectedLensAperture = heldPhotoAperture(sharedPhotoIntent?.aperture, on: device)"))
        #expect(session.contains(
            "selectedLensAperture = heldPhotoAperture(selectedLensAperture, on: device)"))
        // The Photo lens switch is the reported path: the new input replaces the
        // old sensor in place, and the stop has to be re-held against it.
        let switches = session.components(separatedBy: "heldPhotoAperture(").count - 1
        #expect(switches == 4, "idle install, photo lens switch, camera change, definition")
        #expect(!session.contains("selectedLensAperture = sharedPhotoIntent?.aperture"))
    }

    /// A refused photo exposure is not a recording failure, and must not claim to
    /// be one. Both controller callbacks report the photo-specific error.
    @Test func aPhotoExposureFailureIsNotReportedAsARecordingFailure() throws {
        let session = try source("App/Modules/CameraCapture/CameraSession.swift")
        let photoReports = session.components(
            separatedBy: "reportDevelopmentPhotoError(CameraError.photoExposureUnavailable(message))").count - 1
        #expect(photoReports == 2)
        #expect(!session.contains("reportDevelopmentPhotoError(CameraError.writerUnavailable(message))"))
        #expect(session.contains("case .photoExposureUnavailable(let detail):"))
        #expect(session.contains(#"return "Photo exposure could not be updated: \(detail).""#))
        // The recording wording stays with the recording error it belongs to.
        #expect(session.contains(#"return "Apple Log 2 HEVC Main10 recording is unavailable. \(detail)""#))
    }

    /// The banner text is the operator's sentence, not a Swift case name.
    @Test func theReportedReasonIsPlainSpeech() throws {
        let controller = try source("App/Modules/CameraCapture/DevelopmentPhotoController.swift")
        #expect(!controller.contains("Photo exposure update failed: \\(error)"))
        #expect(controller.contains("var reason: String"))
        #expect(controller.contains("this lens does not support that exposure"))
    }
}
