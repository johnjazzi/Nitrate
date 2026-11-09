import XCTest

final class CameraInteractionUITests: XCTestCase {
    /// Whether the app under test was compiled with the experimental 120 fps
    /// control. The value comes from this test bundle's generated
    /// `Nitrate120FPSEnabled` Info.plist key; a missing or unparseable value is
    /// OFF, which is what a default build produces.
    ///
    /// This is the only gate that may skip a 120 fps expectation. When the key is
    /// ON the control is expected to exist, so a missing menu option fails.
    private static var is120FPSEnabledInBuild: Bool {
        guard let raw = Bundle(for: CameraInteractionUITests.self)
            .object(forInfoDictionaryKey: "Nitrate120FPSEnabled") else { return false }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            return ["YES", "TRUE", "1"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }
        return false
    }

    @MainActor func testHistoryHasTitleAndPullDownDismissal() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let lcd = app.descendants(matching: .any).matching(identifier: "camera.queueLCD").firstMatch
        waitUntilReady(lcd, in: app, named: "history-queue-ready")
        lcd.tap()
        let history = app.navigationBars["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertFalse(history.buttons["Done"].exists, "History dismisses using its native grabber, not an X")
        XCTAssertTrue(app.buttons["queue.options"].exists)
        let card = app.descendants(matching: .any).matching(identifier: "queue.receiptCard").firstMatch
        if card.exists {
            XCTAssertLessThanOrEqual(card.frame.height, 128, "A receipt is one compact row, not stacked controls")
            XCTAssertGreaterThanOrEqual(card.frame.height, 104, "Keep the larger preview")
        }
        app.buttons["queue.options"].tap()
        let allHistory = app.buttons["Show all"]
        XCTAssertTrue(allHistory.waitForExistence(timeout: 3))
        allHistory.tap()
        attachEvidence(app, named: "history-title-placeholder-handle")
        let more = app.buttons.matching(identifier: "queue.more").firstMatch
        if more.exists {
            more.tap()
            XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 3))
            attachEvidence(app, named: "history-overflow-actions")
            history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let handle = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        handle.press(forDuration: 0.05, thenDragTo: down)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: history)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        XCTAssertTrue(lcd.isHittable)
    }

    @MainActor func testDevelopMinimalChooser() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let develop = app.buttons["cameraMode.develop"]
        waitUntilReady(develop, in: app, named: "develop-mode-ready")
        develop.tap()
        let photo = app.buttons["develop.choosePhoto"]
        let video = app.buttons["develop.choose"]
        waitUntilReady(photo, in: app, named: "develop-photo-choice")
        waitUntilReady(video, in: app, named: "develop-video-choice")
        XCTAssertGreaterThanOrEqual(photo.frame.height, 80)
        XCTAssertGreaterThanOrEqual(video.frame.height, 80)
        XCTAssertEqual(photo.label, "Photo")
        XCTAssertEqual(video.label, "Video")
        XCTAssertFalse(app.staticTexts["Choose a raw photo or Apple Log 2 clip. Nothing develops until you review it."].exists)
        attachEvidence(app, named: "develop-minimal-chooser")
    }

    @MainActor func testDevelopMinimalRetainedReview() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let lcd = app.descendants(matching: .any).matching(identifier: "camera.queueLCD").firstMatch
        waitUntilReady(lcd, in: app, named: "develop-queue-ready")
        lcd.tap()
        let redevelop = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["queue.redevelopPhoto", "queue.redevelopVideo"])).firstMatch
        guard redevelop.waitForExistence(timeout: 10) else {
            throw XCTSkip("No retained original; this check never creates or deletes user media")
        }
        redevelop.tap()
        let preview = app.buttons["develop.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 45), "The original must genuinely decode and grade")
        XCTAssertTrue(preview.isHittable)
        XCTAssertGreaterThan(preview.frame.height, 210)
        XCTAssertTrue(app.buttons["develop.bulkCommit"].isHittable)
        attachEvidence(app, named: "develop-minimal-review")
        preview.tap()
        let done = app.buttons["develop.zoom.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        attachEvidence(app, named: "develop-minimal-enlarged")
        done.tap()
    }

    @MainActor func testManual60FPSRecordsTenSecondsThroughVisibleControls() throws {
        try recordManualRateThroughVisibleControls(fps: 60)
    }

    @MainActor func testManual120FPSRecordsTenSecondsThroughVisibleControls() throws {
        try recordManualRateThroughVisibleControls(fps: 120)
    }


    @MainActor func testManual120FPSRecordsThirtySecondsThroughVisibleControls() throws {
        try recordManualRateThroughVisibleControls(fps: 120, minimumSeconds: 30)
    }

    /// Exercise the normal view-model path: visible mode/lens/manual controls,
    /// native FPS menu, REC, confirmed timer progression, and STOP. No smoke FPS
    /// argument or direct session start is permitted in this regression.
    @MainActor private func recordManualRateThroughVisibleControls(
        fps: Int, minimumSeconds: Double = 10, arguments: [String] = []
    ) throws {
        // Compiled-out control: nothing to drive, so the run is skipped. In a
        // flag-ON build this branch is not taken and every selector below must
        // exist; a missing 120 fps menu option therefore fails the test.
        if fps == 120, !Self.is120FPSEnabledInBuild {
            throw XCTSkip("120 fps is compiled out of this test build (Nitrate120FPSEnabled OFF)")
        }
        continueAfterFailure = false
        let app = launchReadyCamera(arguments: arguments, hideDiagnosticButtons: true)
        selectVideo(in: app)
        selectWideLens(in: app)
        lockManualISO(in: app)
        let manual = app.buttons["Manual controls"]
        waitUntilReady(manual, in: app, named: "manual-fps-\(fps)-controls-ready")
        if manual.value as? String != "Expanded" { manual.tap() }
        let rate = app.buttons["Capture frame rate"]
        waitUntilReady(rate, in: app, named: "manual-fps-\(fps)-menu-ready")
        rate.tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@", "\(fps)FPS")).firstMatch
        waitUntilReady(option, in: app, named: "manual-fps-\(fps)-option-ready", timeout: 10)
        // Native-menu element.tap() attempted a failing scroll-to-visible and
        // left the menu open. Tap the row's own centre instead, resolved from
        // the element rather than from app-space coordinates, which can lag the
        // menu's presentation window.
        // A tap that lands during the menu's presentation animation is swallowed,
        // so the row is given a beat to settle and the tap is retried once before
        // the commit is judged.
        func tapRow() { option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        Thread.sleep(forTimeInterval: 0.6)
        tapRow()
        var commitResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "\(fps)FPS"), object: rate)], timeout: 8)
        if commitResult != .completed {
            tapRow()
            commitResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "\(fps)FPS"), object: rate)], timeout: 20)
        }
        if commitResult != .completed { attachEvidence(app, named: "failed-manual-fps-\(fps)-commit") }
        XCTAssertEqual(commitResult, .completed, "The visible FPS selector must commit the requested rate")
        attachEvidence(app, named: "manual-fps-\(fps)-selected-before-record")
        let start = app.buttons["Start recording"]
        waitUntilReady(start, in: app, named: "manual-fps-\(fps)-record-ready")
        start.tap()
        let stop = app.buttons["Stop recording"]
        waitUntilReady(stop, in: app, named: "manual-fps-\(fps)-writer-started")
        waitForConfirmedRecording(in: app, minimumSeconds: minimumSeconds, named: "manual-fps-\(fps)-duration")
        attachEvidence(app, named: "manual-fps-\(fps)-before-stop")
        stop.tap()
        waitUntilReady(start, in: app, named: "manual-fps-\(fps)-idle-after-stop", timeout: 40)
        XCTAssertFalse(app.alerts.firstMatch.exists, "A recording failure alert is not a successful stop")
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Recording failed:")).firstMatch
        XCTAssertFalse(failure.exists, "An inline recording failure is not a successful stop")
        XCTAssertEqual(rate.value as? String, "\(fps)FPS")
        attachEvidence(app, named: "manual-fps-\(fps)-stopped")
    }

    @MainActor private func waitForConfirmedRecording(in app: XCUIApplication,
                                                      minimumSeconds: Double, named name: String) {
        let status = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Recording status")).firstMatch
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard status.exists else { return false }
            guard let value = status.value as? String,
                  value.hasPrefix("Recording, capture confirmed. "),
                  let time = value.components(separatedBy: ". ").dropFirst().first else { return false }
            let clock = time.split(separator: ":").compactMap { Double($0) }
            return clock.count == 2 && clock[0] * 60 + clock[1] >= minimumSeconds
        }, object: nil)
        let result = XCTWaiter.wait(for: [elapsed], timeout: minimumSeconds + 10)
        if result != .completed { attachEvidence(app, named: "failed-\(name)") }
        XCTAssertEqual(result, .completed,
                       "Confirmed capture must advance beyond \(minimumSeconds) seconds, not merely acknowledge REC")
    }
    /// Exercise the real scene lifecycle, then prove capture rather than merely
    /// finding a still-visible preview after activation.
    @MainActor func testPhotoCaptureRecoversAcrossBackgroundRoundTrips() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectPhoto(in: app)
        for cycle in 1...3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10),
                          "The app must actually background before testing recovery")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            waitUntilReady(app.buttons["cameraMode.video"], in: app,
                           named: "foreground-mode-ready-\(cycle)", timeout: 25)
            selectVideo(in: app)
            selectPhoto(in: app)
            let shutter = app.buttons["photo.shutter"]
            waitUntilReady(shutter, in: app, named: "foreground-photo-ready-\(cycle)")
            shutter.tap()
            waitForPhotoSaved(in: app)
            attachEvidence(app, named: "foreground-photo-saved-\(cycle)")
        }
    }

    @MainActor func testPreviewAppearanceAcrossVideoPhotoVideo() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let preview = app.otherElements["camera.preview"]
        let originalFrame = preview.frame
        attachEvidence(app, named: "shared-idle-video-before")
        // Exercise repeated real mode selections, not the smoke-launch graph.
        for cycle in 1...2 {
            selectPhoto(in: app)
            XCTAssertEqual(preview.frame, originalFrame, "Photo must preserve the shared idle preview framing")
            attachEvidence(app, named: "shared-idle-photo-\(cycle)")
            selectVideo(in: app)
            XCTAssertEqual(preview.frame, originalFrame, "Video must return to the identical idle preview framing")
            attachEvidence(app, named: "shared-idle-video-after-\(cycle)")
        }
        // Screenshots are appearance evidence for review, not a pixel-parity assertion:
        // the live scene can move. Profile/codec validation remains device-owned;
        // capture-profile/exposure readout supplements, but does not replace, media validation.
    }

    /// Normal UI capture plus copied capture manifests establish actual native
    /// flash firing; the UI assertion alone establishes only the requested state.
    @MainActor func testNativePhotoFlashCapturesOffOnAndManualWithoutChangingVideoLamp() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectVideo(in: app)
        let flash = app.descendants(matching: .any).matching(identifier: "camera.flash").firstMatch
        waitUntilReady(flash, in: app, named: "native-flash-control-ready")
        let videoLamp = flash.value as? String
        selectPhoto(in: app)
        selectWideLens(in: app)
        let originallyOn = flash.value as? String == "Photo flash on"
        flash.press(forDuration: 0.5)
        XCTAssertTrue(app.segmentedControls["camera.photoFlashMode"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Intensity"].exists, "Native flash must not offer a fictitious power slider")
        XCTAssertFalse(app.staticTexts["Duration"].exists, "Native flash timing is owned by the camera")
        attachEvidence(app, named: "native-photo-flash-on-off-popover")
        app.otherElements["camera.preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        defer {
            if app.state == .runningForeground, app.buttons["photo.shutter"].exists,
               (flash.value as? String == "Photo flash on") != originallyOn {
                flash.tap()
            }
        }
        for enabled in [false, true] {
            if (flash.value as? String == "Photo flash on") != enabled { flash.tap() }
            XCTAssertEqual(flash.value as? String, enabled ? "Photo flash on" : "Photo flash off")
            app.buttons["photo.shutter"].tap()
            waitForPhotoSaved(in: app)
            attachEvidence(app, named: enabled ? "native-photo-flash-on-saved" : "native-photo-flash-off-saved")
        }
        // Pin both axes through the existing controls, not a direct session probe.
        lockManualISO(in: app)
        let shutterLock = app.buttons["photo.shutterLock"]
        waitUntilReady(shutterLock, in: app, named: "native-flash-manual-shutter")
        if shutterLock.value as? String != "Lock" { shutterLock.tap() }
        XCTAssertEqual(shutterLock.value as? String, "Lock")
        XCTAssertEqual(flash.value as? String, "Photo flash on")
        app.buttons["photo.shutter"].tap()
        waitForPhotoSaved(in: app)
        attachEvidence(app, named: "native-photo-flash-manual-saved")
        if (flash.value as? String == "Photo flash on") != originallyOn { flash.tap() }
        selectVideo(in: app)
        XCTAssertEqual(flash.value as? String, videoLamp, "Still flash must not alter the saved video lamp level")
    }

    @MainActor func testVideoRecordStopThenPhotoCaptureThroughVisibleControls() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        // First toggle modes so recording must still work after a Photo selection.
        selectPhoto(in: app)
        selectVideo(in: app)
        let start = app.buttons["Start recording"]
        waitUntilReady(start, in: app, named: "video-record-ready")
        start.tap()
        // "Cancel starting recording" is deliberately NOT accepted as success.
        let stop = app.buttons["Stop recording"]
        waitUntilReady(stop, in: app, named: "video-writer-started")
        XCTAssertFalse(app.buttons["cameraMode.photo"].isEnabled,
                       "Mode changes must remain blocked during a real take")
        waitForConfirmedRecording(in: app, minimumSeconds: 2, named: "video-timer-advance")
        attachEvidence(app, named: "video-recording-before-stop")
        stop.tap()
        waitUntilReady(start, in: app, named: "video-stop-restored-idle", timeout: 40)
        waitUntilReady(app.buttons["cameraMode.photo"], in: app, named: "photo-ready-after-video-stop")
        attachEvidence(app, named: "shared-idle-after-video-stop")
        selectPhoto(in: app)
        let shutter = app.buttons["photo.shutter"]
        shutter.tap()
        waitForPhotoSaved(in: app)
        attachEvidence(app, named: "photo-saved-after-normal-video-record-stop")
        selectVideo(in: app)
    }

    /// The video exposure index must survive a manual lock, a return to auto and
    /// the mode switches around a take.
    ///
    /// This is the regression for the device crash of 2026-10-27 21:46: the
    /// shared idle camera held a custom exposure that the incoming Log 2 format
    /// rejects, and AVFoundation re-applied it inside its own frame-duration
    /// setter, raising an exception Swift cannot catch. A crash fails this test
    /// outright, so surviving the sequence is the assertion.
    @MainActor func testVideoExposureIndexLocksThenSurvivesTakeAndModeSwitches() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectVideo(in: app)
        let exposure = exposureControl(in: app, manual: false)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: exposure)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                       "The video exposure control must be present before its EI is locked")

        lockManualISO(in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ISO '")).firstMatch.exists,
                      "A locked EI must read back its ISO value")
        attachEvidence(app, named: "video-ei-locked")

        // Leave for auto and come back: the control must track the committed
        // mode both ways rather than latching.
        unlockManualISO(in: app)
        lockManualISO(in: app)

        // A take is the transition into the Apple Log 2 recorder graph, which is
        // where the stale custom exposure was re-applied.
        let start = app.buttons["Start recording"]
        waitUntilReady(start, in: app, named: "video-record-ready-with-locked-ei")
        start.tap()
        let stop = app.buttons["Stop recording"]
        waitUntilReady(stop, in: app, named: "video-writer-started-with-locked-ei")
        stop.tap()
        waitUntilReady(start, in: app, named: "video-idle-after-take-with-locked-ei", timeout: 40)

        // Mode switches with an EI intent held on the shared idle camera.
        selectPhoto(in: app)
        XCTAssertEqual(app.state, .runningForeground, "Photo entry must not abort the process")
        selectVideo(in: app)
        // The EI was locked when Photo was entered, and Video keeps its own
        // exposure intent across the round trip: the control must come back in
        // the mode the operator left it, not silently reset to auto.
        attachEvidence(app, named: "video-ei-after-mode-switch")
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                object: exposureControl(in: app, manual: true))
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 20), .completed,
                       "A locked video EI must survive a Photo round trip")

        unlockManualISO(in: app)
        XCTAssertTrue(exposureControl(in: app, manual: false).exists,
                      "Unlocking must commit auto exposure")
    }

    /// Holding the Photo ISO surfaces the shutter rail on its own — the manual
    /// panel is shut on entry (`showInlineManualControls` starts false), which is
    /// what makes this a real stickiness check — but it must *not* hold the
    /// shutter with it: the shutter stays free to satisfy the compensation until
    /// the operator holds it himself.
    @MainActor func testPhotoISOLockSurfacesTheShutterRailAndLeavesTheShutterFree() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectPhoto(in: app)

        // The shutter is never disabled, whatever the camera is doing: a tap may
        // fail, but it must never be refused by a dead control.
        XCTAssertTrue(app.buttons["photo.shutter"].isEnabled,
                      "The Photo shutter must always accept a tap")

        XCTAssertFalse(app.otherElements["photo.shutterRail"].exists,
                       "The Photo rail belongs to the manual panel until the ISO is pinned")

        lockManualISO(in: app)

        let rail = app.otherElements["photo.shutterRail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 15),
                      "A pinned ISO must surface the shutter rail without the manual panel")
        attachEvidence(app, named: "photo-iso-lock-shutter-rail")

        let lock = app.buttons["photo.shutterLock"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertEqual(lock.value as? String, "Float",
                       "Holding the ISO holds the sensitivity only: the shutter floats so the "
                       + "compensation can be reached by raising the shutter speed")

        let duration = app.descendants(matching: .any)
            .matching(identifier: "photo.shutterDuration").firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 5))

        // The operator can still hold it, one tap, right there on the rail.
        lock.tap()
        let held = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            lock.value as? String == "Lock"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [held], timeout: 5), .completed,
                       "The held shutter stays an explicit choice on the rail")
        attachEvidence(app, named: "photo-iso-lock-shutter-held")
    }

    // MARK: - Video exposure-index helpers

    /// The exposure column is identified by the mode it has committed, not by a
    /// fixed identifier: one control, whose label names the current mode.
    @MainActor private func exposureControl(in app: XCUIApplication, manual: Bool) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", manual ? "Manual ISO" : "Auto exposure bias"))
            .firstMatch
    }

    @MainActor private func lockManualISO(in app: XCUIApplication) {
        guard !exposureControl(in: app, manual: true).exists else { return }
        let auto = exposureControl(in: app, manual: false)
        XCTAssertTrue(auto.waitForExistence(timeout: 10),
                      "The auto-exposure control must be present before locking")
        // The long press can land while the session is still settling, so it is
        // retried rather than treated as one-shot.
        var result: XCTWaiter.Result = .timedOut
        for _ in 0..<3 {
            auto.press(forDuration: 0.7)
            let locked = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                self?.allowPendingPrivacyAlert(in: app)
                return self?.exposureControl(in: app, manual: true).exists == true
            }, object: nil)
            result = XCTWaiter.wait(for: [locked], timeout: 10)
            if result == .completed { break }
        }
        if result != .completed { attachEvidence(app, named: "failed-ei-lock") }
        XCTAssertEqual(result, .completed, "A long press must commit a manual exposure index")
    }

    @MainActor private func unlockManualISO(in app: XCUIApplication) {
        let manual = exposureControl(in: app, manual: true)
        guard manual.exists else { return }
        manual.press(forDuration: 0.7)
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.allowPendingPrivacyAlert(in: app)
            return self?.exposureControl(in: app, manual: false).exists == true
        }, object: nil)
        let result = XCTWaiter.wait(for: [unlocked], timeout: 15)
        if result != .completed { attachEvidence(app, named: "failed-ei-unlock") }
        XCTAssertEqual(result, .completed, "A long press must return to auto exposure")
    }

    /// Separate probe: does the Video profile still come up after a background
    /// cycle, independent of any Photo capture?
    @MainActor func testVideoModeSwitchAfterBackgroundingAndReturning() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        selectPhoto(in: app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitUntilReady(app.buttons["cameraMode.video"], in: app, named: "return-video-mode-ready")
        app.buttons["cameraMode.video"].tap()
        waitUntilReady(app.buttons["Start recording"], in: app, named: "return-video-rec-ready", timeout: 40)
        attachEvidence(app, named: "return-video-mode")
    }

    /// Backgrounding and returning must leave a live camera, not a frozen one.
    /// A stale shared-graph lease or a stopped session that never restarts shows
    /// up here as an unreachable shutter or a take that never saves.
    @MainActor func testCameraStillCapturesAfterBackgroundingAndReturning() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        selectPhoto(in: app)
        attachEvidence(app, named: "lifecycle-before-background")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                      "Nitrate must return to the foreground")
        waitUntilReady(app.buttons["photo.shutter"], in: app, named: "lifecycle-photo-shutter-ready")
        attachEvidence(app, named: "lifecycle-after-return")
        app.buttons["photo.shutter"].tap()
        waitForPhotoSaved(in: app)
        attachEvidence(app, named: "lifecycle-photo-saved-after-return")
        // Video must also recover, not just the Photo intent.
        selectVideo(in: app)
        let start = app.buttons["Start recording"]
        waitUntilReady(start, in: app, named: "lifecycle-video-ready-after-return")
        start.tap()
        waitUntilReady(app.buttons["Stop recording"], in: app, named: "lifecycle-video-started-after-return")
        app.buttons["Stop recording"].tap()
        waitUntilReady(start, in: app, named: "lifecycle-video-stopped-after-return", timeout: 40)
        attachEvidence(app, named: "lifecycle-video-after-return")
    }

    @MainActor func testPhotoLCDOpensCompletedRenderPreviewInQueue() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        selectPhoto(in: app)
        app.buttons["photo.shutter"].tap()
        let lcd = app.descendants(matching: .any).matching(identifier: "camera.queueLCD").firstMatch
        XCTAssertTrue(lcd.waitForExistence(timeout: 5))
        lcd.tap()
        let preview = app.buttons["queue.photoPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 45), "The completed Photo job must expose its local developed image")
        preview.tap()
        let image = app.images["queue.photoFullPreview"]
        XCTAssertTrue(image.waitForExistence(timeout: 5), "A JPEG preview, not a video player or Photos deep link, must open")
        attachEvidence(app, named: "photo-LCD-queue-developed-preview")
    }

    /// Video's ISO control must reach the device, not only its own readout.
    ///
    /// The shared idle profile deferred every manual exposure write to Photo's
    /// controller — which does not exist in Video, whose idle runs on that same
    /// idle profile. The ruler moved and the device never did. The device trace
    /// (`--trace-photo-exposure`, always on for these runs) records which side
    /// applied the write, so this run leaves the evidence on the phone.
    @MainActor func testVideoISODragReachesTheDevice() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectVideo(in: app)
        lockManualISO(in: app)
        let readout = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ISO '")).firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "A locked video EI must read back its ISO")
        let ruler = app.descendants(matching: .any).matching(identifier: "camera.isoRuler").firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 10), "The ISO chooser must exist once the EI is locked")
        XCTAssertTrue(ruler.isHittable)
        attachEvidence(app, named: "video-iso-before-drag")
        let before = ruler.value as? String
        let readoutBefore = readout.label
        // The chooser is a vertical, relative drag: the travel has to stay on its
        // own axis and cross several detents. Measured on the device tree the
        // element is ~120pt tall, so a swipe that stays inside it lands back on the
        // value it started from and proves nothing.
        func chooserMoved() -> Bool { (ruler.value as? String) != before }
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2,
                    thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4.0)))
        if !chooserMoved() {
            // The chooser sits near the bottom of the screen, so the only travel
            // with room is upward: a slower second pass, then a reversed one.
            start.press(forDuration: 0.5,
                        thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2.0)))
        }
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in chooserMoved() },
                                              object: nil)
        let movedResult = XCTWaiter.wait(for: [moved], timeout: 5)
        if movedResult != .completed { attachEvidence(app, named: "failed-video-iso-drag") }
        XCTAssertEqual(movedResult, .completed, "A physical drag must move the video ISO chooser")
        // The device is the only source of truth for what was applied: the readout
        // is fed by the exposure poll, so wait for the camera to report the value
        // the operator just asked for.
        let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            readout.label != readoutBefore
        }, object: nil)
        let installedResult = XCTWaiter.wait(for: [installed], timeout: 8)
        if installedResult != .completed { attachEvidence(app, named: "failed-video-iso-installed") }
        attachEvidence(app, named: "video-iso-after-drag")
        XCTAssertEqual(installedResult, .completed,
                       "The video ISO write must reach the device, not only the chooser")
    }

    /// Photo's ISO chooser must stay where the finger put it.
    ///
    /// The presented ISO used to be written straight from the device snapshot on
    /// every publish, so the ruler was pulled out from under the drag and each new
    /// delta was measured from a position the operator never chose: the slider
    /// stuttered and read as seconds behind the touch. The chooser now holds the
    /// operator's value until the camera reports it back, so the value must move on
    /// a drag and *stay* there across the snapshot traffic.
    @MainActor func testPhotoISOChooserHoldsTheOperatorValueAcrossSnapshots() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectPhoto(in: app)
        lockManualISO(in: app)
        let ruler = app.descendants(matching: .any).matching(identifier: "camera.isoRuler").firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 15), "The ISO chooser must exist once the EI is locked")
        XCTAssertTrue(ruler.isHittable)
        let before = ruler.value as? String
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2,
                    thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4.0)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (ruler.value as? String) != before
        }, object: nil)
        let movedResult = XCTWaiter.wait(for: [moved], timeout: 5)
        if movedResult != .completed { attachEvidence(app, named: "failed-photo-iso-drag") }
        XCTAssertEqual(movedResult, .completed, "A physical drag must move the photo ISO chooser")
        let dragged = ruler.value as? String
        // Two seconds of snapshot traffic: the value the operator chose must survive it.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(ruler.value as? String, dragged,
                       "A device snapshot must not pull the chooser away from the operator's own value")
        attachEvidence(app, named: "photo-iso-after-drag")
    }

    @MainActor func testPhotoManualKeyExposesResponsiveShutterWithoutExtraToggle() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        XCTAssertTrue(app.buttons["cameraMode.photo"].waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["cameraMode.photo"])
        waitForExpectations(timeout: 20)
        app.buttons["cameraMode.photo"].tap()
        XCTAssertTrue(app.buttons["photo.shutter"].waitForExistence(timeout: 20))
        let manual = app.buttons["Manual controls"]
        XCTAssertTrue(manual.isHittable)
        if manual.value as? String == "Collapsed" { manual.tap() }
        let mode = app.buttons["photo.shutterLock"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.isHittable)
        let preview = app.otherElements["camera.preview"]
        let originalPreview = preview.frame
        let ruler = app.descendants(matching: .any).matching(identifier: "photo.shutterDuration").firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        XCTAssertTrue(ruler.isHittable)
        let rail = app.descendants(matching: .any).matching(identifier: "photo.shutterRail").firstMatch
        XCTAssertTrue(rail.exists)
        XCTAssertGreaterThan(rail.frame.width, rail.frame.height)
        XCTAssertGreaterThanOrEqual(ruler.frame.height, 44)
        XCTAssertGreaterThanOrEqual(mode.frame.width, 44)
        XCTAssertGreaterThanOrEqual(mode.frame.height, 44)
        XCTAssertTrue(originalPreview.contains(rail.frame), "The horizontal rail stays inside the unchanged preview")
        XCTAssertLessThan(rail.frame.maxY, originalPreview.midY, "Shutter belongs at the preview top, not beside the right manual stack")
        XCTAssertFalse(rail.frame.intersects(app.buttons["Camera lens"].frame))
        let before = ruler.value as? String
        let left = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let right = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        left.press(forDuration: 0.05, thenDragTo: right)
        if ruler.value as? String == before { right.press(forDuration: 0.05, thenDragTo: left) }
        XCTAssertNotEqual(ruler.value as? String, before, "A horizontal physical drag must change shutter intent")
        XCTAssertEqual(mode.value as? String, "Lock", "Dragging locks the latest shutter intent immediately")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "Float")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "Lock")
        XCTAssertEqual(preview.frame, originalPreview, "Showing and dragging the rail cannot crop or resize preview")
        manual.tap()
        XCTAssertFalse(mode.exists, "Keep the existing manual-key visibility semantics")
        XCTAssertEqual(preview.frame, originalPreview)
        manual.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Photo horizontal top shutter rail after physical drag"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testPhotoLensSelectionAndExitThroughVisibleControls() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let photo = app.buttons["cameraMode.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "Photo entry must be visible")
        photo.tap()
        XCTAssertTrue(app.buttons["photo.shutter"].waitForExistence(timeout: 20))
        let lens = app.buttons["Camera lens"]
        XCTAssertTrue(lens.exists && lens.isHittable, "Toolbar lens key must accept taps in Photo")
        lens.tap()
        let tele = app.buttons["96 mm"]
        let ultra = app.buttons["13 mm"]
        XCTAssertTrue(ultra.waitForExistence(timeout: 5), "Lens popover must open")
        ultra.tap()
        let changed = NSPredicate(format: "value == %@", "13 mm")
        expectation(for: changed, evaluatedWith: lens)
        waitForExpectations(timeout: 25)
        lens.tap()
        XCTAssertTrue(tele.waitForExistence(timeout: 5))
        tele.tap()
        expectation(for: NSPredicate(format: "value == %@", "96 mm"), evaluatedWith: lens)
        waitForExpectations(timeout: 25)
        let video = app.buttons["cameraMode.video"]
        XCTAssertTrue(video.exists && video.isHittable, "Video exit must remain tappable")
        video.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["photo.shutter"])
        waitForExpectations(timeout: 25)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testPhotoFrontCameraCapabilityOrExplicitUnsupportedState() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let photo = app.buttons["cameraMode.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()
        XCTAssertTrue(app.buttons["photo.shutter"].waitForExistence(timeout: 20))
        app.buttons["Camera lens"].tap()
        let front = app.buttons["Front"]
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        front.tap()
        expectation(for: NSPredicate(format: "value == %@", "Front"), evaluatedWith: app.buttons["Camera lens"])
        waitForExpectations(timeout: 25)
        let shutter = app.buttons["photo.shutter"]
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        waitForPhotoSaved(in: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testSlowPhotoRemainsLiveAndCaptureAndExitWork() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(arguments: ["--ui-slow-photo"])
        let photo = app.buttons["cameraMode.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()
        let shutter = app.buttons["photo.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        let preview = app.otherElements["camera.preview"]
        let slowApplied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = preview.value as? String,
                  let exposure = value.components(separatedBy: "exposure=").last,
                  let seconds = Double(exposure) else { return false }
            return value.hasPrefix("Idle SDR") && seconds >= 0.95 && seconds <= 1.05
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [slowApplied], timeout: 15), .completed,
                       "The hardware exposure readout must reach one second before this test claims slow capture coverage")
        XCTAssertFalse(app.staticTexts["Live preview paused · slow shutter"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Slow Photo native live preview and exposure indicator"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        waitForPhotoSaved(in: app)
        app.buttons["cameraMode.video"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: shutter)
        waitForExpectations(timeout: 25)
        XCTAssertFalse(app.staticTexts["Live preview paused · slow shutter"].exists)
    }

    @MainActor func testVideoPinchCrossesPhysicalLensBoundary() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectWideLens(in: app)
        let lens = app.buttons["Camera lens"]
        let preview = app.otherElements["camera.preview"]
        attachEvidence(app, named: "video-before-physical-pinch")
        preview.pinch(withScale: 0.25, velocity: -1)
        waitForLens("13 mm", in: app)
        attachEvidence(app, named: "video-pinch-ultrawide")
        preview.pinch(withScale: 3, velocity: 1)
        waitForLens("24 mm", in: app)
        XCTAssertTrue(lens.isHittable)
        attachEvidence(app, named: "video-pinch-wide-restored")
    }

    @MainActor func testPhotoPinchCrossesPhysicalLensBoundary() throws {
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectPhoto(in: app)
        selectWideLens(in: app)
        let preview = app.otherElements["camera.preview"]
        attachEvidence(app, named: "photo-before-physical-pinch")
        preview.pinch(withScale: 0.25, velocity: -1)
        waitForLens("13 mm", in: app)
        attachEvidence(app, named: "photo-pinch-ultrawide")
        // FocalPinchZoom applies pow(scale, 0.65): 13 * 3^0.65 = 26.55 mm.
        // The old 2.2 scale requested only 21.70 mm and cannot cross back to wide.
        preview.pinch(withScale: 3, velocity: 1)
        waitForLens("24 mm", in: app)
        waitUntilReady(app.buttons["photo.shutter"], in: app, named: "photo-ready-after-pinch")
        app.buttons["photo.shutter"].tap()
        waitForPhotoSaved(in: app)
        attachEvidence(app, named: "photo-saved-after-physical-pinch")
    }

    /// Regression: taps used to be swallowed. A tap queued behind the exposure
    /// loop left the control live-looking but unresponsive (nothing said why), and
    /// a second tap during a capture returned in silence. Every tap must now be
    /// answered — a capture or a readable reason — and the last tap of a burst
    /// must still deliver a photo.
    @MainActor func testPhotoShutterAnswersEveryTapInARow() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        selectPhoto(in: app)
        let shutter = app.buttons["photo.shutter"]
        waitUntilReady(shutter, in: app, named: "photo-shutter-ready")

        XCTAssertTrue(shutter.isHittable,
                      "The shutter must be hittable where it is drawn (the donut's hole is not a tap target; "
                      + "the control declares its own round content shape)")
        for index in 0..<6 {
            XCTAssertTrue(shutter.isEnabled, "The shutter must never be disabled: tap \(index)")
            shutter.tap()
            // A burst is what an operator does when a tap looks ignored. Every tap
            // is accepted, so the control must still be live 150 ms later — the
            // window in which the exposure loop is writing.
            usleep(150_000)
            XCTAssertTrue(shutter.isEnabled, "Tap \(index) must leave a usable shutter")
        }
        attachEvidence(app, named: "photo-shutter-after-tap-burst")

        // The burst must not have left the control unable to capture. Asserting on
        // the shutter's own state (rather than the delivery) keeps this a test of
        // the control: with several RAWs queued, development is the queue's clock,
        // not the shutter's.
        // "Ready · experimental photo color" is the idle status: reaching it means
        // the taps never got past the control, which is the bug this locks down.
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = shutter.value as? String ?? ""
            return value.contains("Capturing RAW") || value.contains("queued")
                || value.contains("saved")
        }, object: nil)
        let result = XCTWaiter.wait(for: [captured], timeout: 20)
        if result != .completed { attachEvidence(app, named: "failed-photo-shutter-burst") }
        XCTAssertEqual(result, .completed,
                       "A tap burst must leave the shutter able to capture; value=\(shutter.value as? String ?? "nil")")
        XCTAssertTrue(shutter.isEnabled, "The shutter must still be enabled after a burst")
    }

    @MainActor func testPhotoZoomChangesPreviewAndCaptures() throws {
        continueAfterFailure = false
        let app = launchReadyCamera()
        let photo = app.buttons["cameraMode.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()
        let shutter = app.buttons["photo.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20))
        let before = app.screenshot()
        app.otherElements["camera.preview"].pinch(withScale: 2, velocity: 1)
        let zoomed = app.screenshot()
        let beforeAttachment = XCTAttachment(screenshot: before)
        beforeAttachment.name = "Photo before zoom"
        beforeAttachment.lifetime = .keepAlways
        add(beforeAttachment)
        let afterAttachment = XCTAttachment(screenshot: zoomed)
        afterAttachment.name = "Photo after zoom"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        waitForPhotoSaved(in: app)
        let video = app.buttons["cameraMode.video"]
        XCTAssertTrue(video.isHittable)
        video.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: shutter)
        waitForExpectations(timeout: 25)
    }

    // MARK: - Real-app launch, permissions and evidence

    @MainActor private func launchReadyCamera(arguments: [String] = [],
                                              hideDiagnosticButtons: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        if hideDiagnosticButtons {
            // Exact keys from DebugControlPreferences. Argument-domain defaults
            // affect only these buttons, not persisted settings or session setup.
            // XCTest's original first finger (56.9443, 136.4957) was inside the
            // DEBUG circle (38, 142), radius 22. Keep the normal camera graph.
            app.launchArguments += ["-debug.showsDebugButton", "NO", "-debug.showsFaultButton", "NO"]
        }
        app.launchArguments += ["--trace-photo-exposure"]
        // A long-press on the exposure column commits the mode *and* can select a
        // detent, so an automated run must not read or write the operator's saved
        // compensation: it would leave the app opening at whatever end of the EV
        // ruler the synthetic finger landed on.
        // Exact string of `CameraExposureBiasPreference.isolationArgument`: the UI
        // test target cannot import the app module.
        app.launchArguments += ["--ui-isolated-defaults"]
        app.launch()
        // The prior pre-pinch failures recorded a chess app in the foreground
        // while Nitrate's background accessibility tree still exposed its toolbar.
        // Activate once at launch; never fight an interruption by reactivating
        // repeatedly during a test or weakening the enabled-mode requirement.
        app.activate()
        if !app.wait(for: .runningForeground, timeout: 10) {
            attachEvidence(app, named: "failed-camera-launch-foreground")
            XCTFail("Nitrate must own the foreground before camera readiness is evaluated")
        }
        // First-launch Camera/Microphone grants can also deactivate the scene.
        // Service those alerts, then require the real active camera to be ready.
        waitUntilReady(app.buttons["cameraMode.photo"], in: app, named: "camera-launch-ready")
        waitUntilReady(app.otherElements["camera.preview"], in: app, named: "camera-preview-ready")
        if hideDiagnosticButtons {
            // The diagnostics mount with the camera chrome rather than the
            // scene, so their absence is waited for instead of sampled once.
            for identifier in ["DEBUG", "FAULT"] {
                let button = app.buttons[identifier]
                let gone = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: button)
                XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed,
                               "Launch defaults must actually remove the intercepting \(identifier) target")
            }
        }
        return app
    }

    @MainActor private func selectPhoto(in app: XCUIApplication) {
        let photo = app.buttons["cameraMode.photo"]
        waitUntilReady(photo, in: app, named: "photo-mode-entry-ready")
        photo.tap()
        waitUntilReady(app.buttons["photo.shutter"], in: app, named: "photo-shutter-ready")
        XCTAssertTrue(photo.isSelected, "Photo selection must commit, not merely expose a shutter")
    }

    @MainActor private func selectVideo(in app: XCUIApplication) {
        let video = app.buttons["cameraMode.video"]
        waitUntilReady(video, in: app, named: "video-mode-entry-ready")
        video.tap()
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.buttons["photo.shutter"])
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 25), .completed)
        waitUntilReady(app.buttons["cameraMode.photo"], in: app, named: "video-idle-mode-ready")
        waitUntilReady(app.buttons["Start recording"], in: app, named: "video-idle-rec-ready")
        XCTAssertTrue(video.isSelected, "Video selection must commit")
    }

    @MainActor private func selectWideLens(in app: XCUIApplication) {
        let lens = app.buttons["Camera lens"]
        waitUntilReady(lens, in: app, named: "lens-menu-ready")
        lens.tap()
        let wide = app.buttons["24 mm"]
        waitUntilReady(wide, in: app, named: "wide-lens-selection-ready", timeout: 5)
        wide.tap()
        waitForLens("24 mm", in: app)
    }

    @MainActor private func waitForLens(_ name: String, in app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name),
                                                object: app.buttons["Camera lens"])
        let result = XCTWaiter.wait(for: [expected], timeout: 20)
        if result != .completed { attachEvidence(app, named: "failed-lens-boundary-\(name)") }
        XCTAssertEqual(result, .completed, "A physical lens change to \(name) must commit")
        waitUntilReady(app.buttons["Camera lens"], in: app, named: "lens-switch-settled")
        // A debug-sheet interception must never be mistaken for a camera gesture.
        XCTAssertFalse(app.navigationBars["Debug · Single Frame"].exists)
    }

    @MainActor private func waitUntilReady(_ element: XCUIElement, in app: XCUIApplication,
                                          named name: String, timeout: TimeInterval = 20) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.allowPendingPrivacyAlert(in: app)
            return app.state == .runningForeground && element.exists && element.isEnabled && element.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: timeout)
        if result != .completed { attachEvidence(app, named: "failed-\(name)") }
        XCTAssertEqual(result, .completed,
                       "\(name): expected foreground app and existing, enabled, hittable target; state=\(app.state.rawValue); "
                       + "exists=\(element.exists), enabled=\(element.isEnabled), hittable=\(element.isHittable)")
    }

    /// The delivery status lives on the shutter as its accessibility value: the
    /// on-screen text over the shutter was removed, and this is the same signal
    /// VoiceOver reads.
    @MainActor private func waitForPhotoSaved(in app: XCUIApplication) {
        let shutter = app.buttons["photo.shutter"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            self?.allowPendingPrivacyAlert(in: app)
            return (shutter.value as? String) == "Photo saved to Photos"
        }, object: nil)
        let result = XCTWaiter.wait(for: [saved], timeout: 40)
        if result != .completed { attachEvidence(app, named: "failed-photo-save") }
        XCTAssertEqual(result, .completed, "The normal shutter path must save a photo")
    }

    @MainActor private func allowPendingPrivacyAlert(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let alert = owner.alerts.firstMatch
            guard alert.exists else { continue }
            // Limit automatic grants to the three resources used by this suite.
            // Never dismiss a camera/configuration error just to advance readiness.
            let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
            guard message.contains("camera") || message.contains("microphone") || message.contains("photos") else { continue }
            let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            guard deny.exists else { continue } // A system privacy choice, not an app error's OK button.
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@",
                ["Allow", "OK", "Allow Access to All Photos", "Add Photos Only"])).firstMatch
            guard allow.exists else { continue }
            allow.tap()
        }
    }

    @MainActor private func attachEvidence(_ app: XCUIApplication, named name: String) {
        // The app-only screenshot can hide which app actually owns the screen.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let hierarchy = XCTAttachment(string: "launchArguments=\(app.launchArguments)\nstate=\(app.state.rawValue)\n"
                                      + "Capture profile is not exposed by this app's accessibility API.\n"
                                      + app.debugDescription)
        hierarchy.name = "\(name)-launch-and-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }




    /// The experimental 120 fps option must stay hidden in the normal app. Launch
    /// defaults only — no feature or diagnostic override may enable it.
    @MainActor func testDefaultFPSMenuHidesExperimental120() throws {
        if Self.is120FPSEnabledInBuild {
            throw XCTSkip("This build compiles the experimental 120 fps control in; the default-OFF menu test does not apply")
        }
        continueAfterFailure = false
        let app = launchReadyCamera(hideDiagnosticButtons: true)
        selectVideo(in: app)
        lockManualISO(in: app)
        let manual = app.buttons["Manual controls"]
        waitUntilReady(manual, in: app, named: "default-fps-controls-ready")
        if manual.value as? String != "Expanded" { manual.tap() }
        let rate = app.buttons["Capture frame rate"]
        waitUntilReady(rate, in: app, named: "default-fps-menu-ready")
        rate.tap()
        let twentyFour = fpsOption(24, in: app)
        let sixty = fpsOption(60, in: app)
        XCTAssertTrue(twentyFour.waitForExistence(timeout: 10), "24 fps must remain offered by the normal app")
        XCTAssertTrue(sixty.waitForExistence(timeout: 10), "60 fps must remain offered by the normal app")
        let oneTwenty = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "120FPS")).firstMatch
        XCTAssertFalse(oneTwenty.exists, "The experimental 120 fps rate must not be offered in the normal app")
        attachEvidence(app, named: "default-fps-menu-without-120")
    }

    @MainActor private func fpsOption(_ fps: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(fps)FPS")).firstMatch
    }





}
