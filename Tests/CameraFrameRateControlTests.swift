import SwiftUI
import Testing

/// The manual Video block's frame-rate key: one native menu that offers the
/// actual 24/60/120 rates, disables what the session cannot deliver, and is
/// locked while the session is recording or transitioning.
///
/// Every assertion is either pure presentation, a guard on the real control, or
/// a source contract over the wiring, so the menu can be inspected without a
/// camera. Physical rate selection and capture still need device validation.
struct CameraFrameRateControlTests {
    // MARK: - Offered rates

    @Test func offeredRatesAreCanonicalAndAscending() {
        let options = CameraFrameRateControlPresentation.options(availableFPS: [24, 60, 120])
        #expect(options.map(\.fps) == [24, 60, 120])
        #expect(options.map(\.faceValue) == ["24", "60", "120"])
    }

    @Test func unavailableRatesStayListedSoNothingIsHidden() {
        // A device that cannot run 120 still shows it, disabled, rather than
        // pretending the rate does not exist.
        let options = CameraFrameRateControlPresentation.options(availableFPS: [24, 60])
        #expect(options.map(\.fps) == [24, 60, 120])
        #expect(CameraFrameRateControlPresentation.isSupported(120, availableFPS: [24, 60]) == false)
        #expect(CameraFrameRateControlPresentation.canSelect(120, availableFPS: [24, 60], canChange: true) == false)
        #expect(CameraFrameRateControlPresentation.canSelect(24, availableFPS: [24, 60], canChange: true))
    }

    @Test func duplicateAndExtraRatesCollapseToOneOrderedList() {
        let options = CameraFrameRateControlPresentation.options(availableFPS: [120, 24, 120, 30])
        #expect(options.map(\.fps) == [24, 30, 60, 120])
        #expect(Set(options.map(\.id)).count == options.count)
    }

    // MARK: - Locking

    @Test func everyRateIsBlockedWhileTheSessionCannotChange() {
        for fps in [24, 60, 120] {
            #expect(CameraFrameRateControlPresentation.canSelect(
                fps, availableFPS: [24, 60, 120], canChange: false) == false)
        }
    }

    // MARK: - Honest face

    @Test func faceNeverRelabelsAnotherRateAsSixty() {
        #expect(CameraFrameRateOption(fps: 120).faceValue == "120")
        #expect(CameraFrameRateOption(fps: 24).faceValue == "24")
        #expect(CameraFrameRateControlPresentation.accessibilityValue(currentFPS: 120)
                == "120 frames per second")
        #expect(CameraFrameRateControlPresentation.rowTitle(fps: 60, currentFPS: 120)
                == "60 frames per second")
        #expect(CameraFrameRateControlPresentation.rowTitle(fps: 120, currentFPS: 120)
                == "120 frames per second, current")
    }

    @Test func standardRateIsNeutralAndHigherRatesAreOrange() {
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 24) == .white.opacity(0.85))
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 60)
                == InlineManualControlPresentation.activeOrange)
        #expect(CameraFrameRateControlPresentation.faceColor(currentFPS: 120)
                == InlineManualControlPresentation.activeOrange)
    }

    // MARK: - Layout

    @Test func frameRateKeyKeepsItsFortyFourPointTargetAndGrowsTheStackByOneRow() {
        #expect(CameraFrameRateControlPresentation.optionHeight == 44)
        // Video: focus, aperture, rate, stabilization.
        let videoHeight: CGFloat = 188
        #expect(InlineManualControlPresentation.stackHeight(showsFrameRate: true) == videoHeight)
        // Photo keeps its committed height and hides the rate key.
        #expect(InlineManualControlPresentation.stackHeight(showsFrameRate: false) == 140)
        #expect(InlineManualControlPresentation.showsFrameRateKey(isPhotoMode: false, isDevelopMode: false))
        #expect(InlineManualControlPresentation.showsFrameRateKey(isPhotoMode: true, isDevelopMode: false) == false)
        #expect(InlineManualControlPresentation.showsFrameRateKey(isPhotoMode: false, isDevelopMode: true) == false)
    }

    // MARK: - Guards on the real control

    @Test @MainActor func choosingASupportedRateCallsTheSingleWriterOnce() {
        var written: [Int] = []
        let control = CameraFrameRateControl(availableFPS: [24, 60, 120], currentFPS: 24,
                                             canChange: true, select: { written.append($0) })
        control.choose(120)
        #expect(written == [120])
    }

    @Test @MainActor func choosingAnUnsupportedOrLockedRateWritesNothing() {
        var written: [Int] = []
        let unsupported = CameraFrameRateControl(availableFPS: [24, 60], currentFPS: 24,
                                                 canChange: true, select: { written.append($0) })
        unsupported.choose(120)
        let locked = CameraFrameRateControl(availableFPS: [24, 60, 120], currentFPS: 120,
                                            canChange: false, select: { written.append($0) })
        locked.choose(60)
        #expect(written.isEmpty)
    }

    // MARK: - Existing daylight compatibility

    @Test func armed120IsNeverPresentedOrSpokenAsDaylightSixty() {
        let face = RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                       frameRateFPS: 120)
        #expect(face.modeStatusLabel == "REC · 120FPS")
        let spoken = face.spokenStatus
        #expect(spoken.contains("120 fps armed"))
        #expect(!spoken.contains("Daylight 60"))
    }

    @Test func legacyDaylightSixtyFaceIsUnchanged() {
        let armed = RecordingStatusFace(presentation: .recording, text: "00:01.00",
                                        daylight60Active: true)
        #expect(armed.modeStatusLabel == "REC · 60FPS")
        #expect(armed.spokenStatus.contains("Daylight 60 fps armed."))
        let standard = RecordingStatusFace(presentation: .recording, text: "00:01.00")
        #expect(standard.modeStatusLabel == "REC")
        #expect(standard.spokenStatus.contains("armed") == false)
    }

    // MARK: - Source contracts over the wiring

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func contentViewWiresOneWriterFromTheSessionRates() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("availableFrameRates: availableInlineFrameRates"))
        #expect(screen.contains("cameraViewModel.availableSessionFrameRates.map(\\.rawValue)"))
        #expect(screen.contains("canChangeFrameRate: cameraViewModel.canChangeSessionFrameRate"))
        #expect(screen.contains("cameraViewModel.setSessionFrameRate(mode)"))
        #expect(screen.contains("InlineManualControlPresentation.stackHeight("))
        // The too-bright rescue is the daylight 60 flow; a manual 120 must not
        // be offered it.
        #expect(screen.contains("daylightRescueSuppressedByHighRate"))
        #expect(screen.contains("cameraViewModel.sessionFrameRate == .high120"))
    }

    @Test func inlineStackHostsTheRateKeyInVideoOnly() throws {
        let stack = try source("App/Modules/CameraCapture/InlineManualControls.swift")
        #expect(stack.contains("CameraFrameRateControl(availableFPS: availableFrameRates"))
        #expect(stack.contains("if !isPhotoMode {"))
        // One shared component, one guard: the parent's callback is not called
        // straight from the menu.
        #expect(stack.contains("select: { chooseFrameRate($0) }"))
        #expect(stack.contains("func chooseFrameRate(_ fps: Int)"))
        #expect(stack.contains("selectFrameRate(fps)"))
    }
}
