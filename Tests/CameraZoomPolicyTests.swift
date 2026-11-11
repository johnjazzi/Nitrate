import Foundation
import Testing

struct CameraZoomPolicyTests {
    @Test func multiplierConvertsDisplayToPhysicalZoomAndCapsAtFive() throws {
        let bounds = try #require(CameraZoomPolicy.bounds(multiplier: 2, effectiveMinimum: 1,
                                                           effectiveMaximum: 12, formatMaximum: 20))
        #expect(bounds.minimumDisplay == 2)
        #expect(bounds.maximumDisplay == 5)
        #expect(bounds.target(4) == 2)
        #expect(bounds.target(10) == 2.5)
        #expect(bounds.target(2) == 1)
    }

    @Test func telephotoFourTimesDisplayScaleCanReachSixteen() throws {
        // At the tele camera's 4x display multiplier, fourfold device crop is 16x displayed.
        let bounds = try #require(CameraZoomPolicy.bounds(multiplier: 4, effectiveMinimum: 1,
                                                           effectiveMaximum: 12, formatMaximum: 20,
                                                           displayCeiling: 16))
        #expect(bounds.minimumDisplay == 4)
        #expect(bounds.maximumDisplay == 16)
        #expect(bounds.target(16) == 4)
        #expect(bounds.target(100) == 4)
    }

    @Test func wideDisplayCeilingRemainsFive() throws {
        let bounds = try #require(CameraZoomPolicy.bounds(multiplier: 1, effectiveMinimum: 1,
                                                           effectiveMaximum: 20, formatMaximum: 20,
                                                           displayCeiling: 5))
        #expect(bounds.minimumDisplay == 1)
        #expect(bounds.maximumDisplay == 5)
        #expect(bounds.target(16) == 5)
    }

    @Test func mainWideDisplayCeilingReaches150MillimetersUsingRealMultiplier() throws {
        // Display factor includes a device-specific multiplier; native crop does not.
        for multiplier in [0.8, 1.0, 2.0] {
            let ceiling = CameraZoomPolicy.mainWideDisplayCeiling(multiplier: multiplier)
            let bounds = try #require(CameraZoomPolicy.bounds(multiplier: multiplier, effectiveMinimum: 1,
                                                               effectiveMaximum: 12, formatMaximum: 20,
                                                               displayCeiling: ceiling))
            #expect(abs(bounds.maximumDisplay - ceiling) < 0.0001)
            #expect(abs(bounds.maximumDevice - 6.25) < 0.0001)
            #expect(abs(bounds.maximumDevice * 24 - 150) < 0.0001)
            #expect(bounds.target(ceiling) == 6.25)
            #expect(bounds.target(100) == 6.25)
        }
    }

    @Test func mainWideCeilingIntersectsLowerHardwareAndFormatLimits() throws {
        let hardware = try #require(CameraZoomPolicy.bounds(multiplier: 2, effectiveMinimum: 1,
                                                              effectiveMaximum: 2.5, formatMaximum: 20,
                                                              displayCeiling: 12.5))
        #expect(hardware.maximumDisplay == 5)
        #expect(hardware.maximumDevice * 24 == 60)
        let format = try #require(CameraZoomPolicy.bounds(multiplier: 2, effectiveMinimum: 1,
                                                            effectiveMaximum: 20, formatMaximum: 2.75,
                                                            displayCeiling: 12.5))
        #expect(format.maximumDisplay == 5.5)
        #expect(format.maximumDevice * 24 == 66)
    }

    @Test func mainWideCeilingIsUnavailableWhenHardwareCannotReachItsMinimum() {
        #expect(CameraZoomPolicy.bounds(multiplier: 2, effectiveMinimum: 7,
                                        effectiveMaximum: 12, formatMaximum: 20,
                                        displayCeiling: 12.5) == nil)
    }

    @Test func mainWideCeilingIsSelectedOnlyForRearWideDevice() throws {
        let session = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraSession.swift"),
                                 encoding: .utf8)
        let start = try #require(session.range(of: "private func zoomBounds(for device:"))
        let end = try #require(session.range(of: "func observeZoom", range: start.upperBound..<session.endIndex))
        let bounds = String(session[start.lowerBound..<end.lowerBound])
        #expect(bounds.contains("device.position == .back && device.deviceType == .builtInWideAngleCamera"))
        #expect(bounds.contains("CameraZoomPolicy.mainWideDisplayCeiling(multiplier: multiplier)"))
        #expect(bounds.contains("CameraZoomPolicy.telephotoDisplayCeiling"))
        #expect(bounds.contains("CameraZoomPolicy.defaultDisplayCeiling"))
    }

    @Test func telephotoCeilingIntersectsDeviceAndFormatMaximums() throws {
        let effectiveLimit = try #require(CameraZoomPolicy.bounds(multiplier: 4, effectiveMinimum: 1,
                                                                   effectiveMaximum: 2.5, formatMaximum: 10,
                                                                   displayCeiling: 16))
        #expect(effectiveLimit.maximumDisplay == 10)
        #expect(effectiveLimit.target(16) == 2.5)
        let formatLimit = try #require(CameraZoomPolicy.bounds(multiplier: 4, effectiveMinimum: 1,
                                                                effectiveMaximum: 10, formatMaximum: 3,
                                                                displayCeiling: 16))
        #expect(formatLimit.maximumDisplay == 12)
        #expect(formatLimit.target(16) == 3)
    }

    @Test func rejectsInvalidExplicitDisplayCeilings() {
        for invalid: Double in [0, -1, .nan, .infinity, -.infinity] {
            #expect(CameraZoomPolicy.bounds(multiplier: 4, effectiveMinimum: 1,
                                            effectiveMaximum: 10, formatMaximum: 10,
                                            displayCeiling: invalid) == nil)
        }
        #expect(CameraZoomPolicy.bounds(multiplier: 4, effectiveMinimum: 2,
                                        effectiveMaximum: 10, formatMaximum: 10,
                                        displayCeiling: 7) == nil)
    }

    @Test func effectiveBoundsOverrideFormatAndPreservePerLensMinimum() throws {
        let bounds = try #require(CameraZoomPolicy.bounds(multiplier: 0.5, effectiveMinimum: 1.5,
                                                           effectiveMaximum: 4, formatMaximum: 20))
        #expect(bounds.minimumDisplay == 0.75)
        #expect(bounds.maximumDisplay == 2)
        #expect(bounds.target(0.1) == 1.5)
        #expect(bounds.target(5) == 4)
    }

    @Test func rejectsInvalidMultiplierLimitsAndCommands() throws {
        for invalid: Double in [0, -1, .nan, .infinity, -.infinity] {
            #expect(CameraZoomPolicy.bounds(multiplier: invalid, effectiveMinimum: 1,
                                            effectiveMaximum: 10, formatMaximum: 10) == nil)
        }
        #expect(CameraZoomPolicy.bounds(multiplier: 1, effectiveMinimum: 6,
                                        effectiveMaximum: 10, formatMaximum: 10) == nil)
        #expect(CameraZoomPolicy.bounds(multiplier: 1, effectiveMinimum: 2,
                                        effectiveMaximum: 1, formatMaximum: 10) == nil)
        let bounds = try #require(CameraZoomPolicy.bounds(multiplier: 1, effectiveMinimum: 1,
                                                           effectiveMaximum: 10, formatMaximum: 10))
        for invalid: Double in [0, -1, .nan, .infinity, -.infinity] { #expect(bounds.target(invalid) == nil) }
        #expect(bounds.target(100) == 5)
    }

    @Test func staleRevisionsCannotBeginOrStopNewRamp() {
        var state = CameraZoomRampLifecycle()
        state.cameraChanged()
        let firstBegin = state.begin(revision: 1)
        #expect(firstBegin)
        #expect(state.isRamping)
        state.cameraChanged()
        let staleEnd = state.end(revision: 1)
        let staleBegin = state.begin(revision: 1)
        #expect(!staleEnd && !staleBegin)
        let secondBegin = state.begin(revision: 2)
        #expect(secondBegin)
        #expect(state.isRamping)
        let oldRelease = state.end(revision: 1)
        #expect(!oldRelease)
        #expect(state.isRamping)
        let finalEnd = state.end(revision: 2)
        #expect(finalEnd)
        #expect(!state.isRamping)
        let duplicateEnd = state.end(revision: 2)
        #expect(!duplicateEnd)
        #expect(!CameraZoomPolicy.accepts(commandRevision: 1, cameraRevision: 2))
    }

    @Test func lensSwitchPublishesActualNewReadbackWithoutOptimisticReset() {
        let old = CameraZoomSnapshot(cameraRevision: 1, displayFactor: 4.2,
                                     minimumDisplayFactor: 1, maximumDisplayFactor: 5,
                                     isRamping: false, isPerLens: false)
        let new = CameraZoomSnapshot(cameraRevision: 2, displayFactor: 2.5,
                                     minimumDisplayFactor: 2, maximumDisplayFactor: 5,
                                     isRamping: false, isPerLens: false)
        #expect(old.accepting(new) == new)
        #expect(new.accepting(old) == new)
    }
}
