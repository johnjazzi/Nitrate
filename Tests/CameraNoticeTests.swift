import Foundation
import Testing

/// The notice contract: severity decides how long it stands and what it looks
/// like. The view and the timer both read these values, so they cannot drift.
struct CameraNoticeTests {

    @Test func aWarningStandsTenSecondsAndAnErrorTwenty() {
        #expect(CameraNotice.Severity.warning.lifetime == 10)
        #expect(CameraNotice.Severity.error.lifetime == 20)
        let warning = CameraNotice(severity: .warning, message: "Switching to UHD.")
        let error = CameraNotice(severity: .error, message: "Recording failed.")
        #expect(warning.lifetime == 10)
        #expect(error.lifetime == 20)
    }

    @Test func severityDrivesTheFlagAndTheTitle() {
        #expect(CameraNotice.Severity.warning.title == "Warning")
        #expect(CameraNotice.Severity.error.title == "Error")
        #expect(CameraNotice.Severity.warning.symbolName.contains("triangle"))
        #expect(CameraNotice.Severity.error.symbolName.contains("octagon"))
    }

    @Test func aNoticeCarriesTheOperatorsTextVerbatim() {
        let message = "That capture format is unavailable: no 1920x1440 10-bit 4:2:2 Apple Log 2 format supports 24 fps on this device."
        let notice = CameraNotice(severity: .warning, message: message)
        #expect(notice.message == message)
        #expect(notice.id != CameraNotice(severity: .warning, message: message).id,
                "each notice is distinct, so a replacement resets the timer")
    }
}
