import Foundation
import Testing

/// Native still flash, independent video torch preferences, and legacy lamp records.
struct FlashControlTests {
    // MARK: - Timing

    @Test func frontSyncLightsTheLeadingEdgeOfTheWindow() throws {
        let timing = FlashTimingPolicy.timing(exposure: 1.0 / 4.0, durationPercent: 40, sync: .front)
        #expect(timing == .lit(start: 0, end: 0.4))
        #expect(timing.durationPercent == 40)
        let seconds = try #require(timing.seconds(in: 1.0 / 4.0))
        #expect(abs(seconds.lowerBound - 0) < 1e-9)
        #expect(abs(seconds.upperBound - 0.1) < 1e-9, "40 % of 250 ms is 100 ms")
    }

    @Test func rearSyncIsExactlyTheMirrorOfFront() throws {
        // Not shipped, but the model must be right before it is offered: a rear
        // interval that is not the exact mirror is a different exposure.
        for duration in [5.0, 25, 40, 100] {
            let front = FlashTimingPolicy.timing(exposure: 1.0 / 8.0, durationPercent: duration, sync: .front)
            let rear = FlashTimingPolicy.timing(exposure: 1.0 / 8.0, durationPercent: duration, sync: .rear)
            let f = try #require(front.interval)
            let r = try #require(rear.interval)
            #expect(abs(f.lowerBound - (1 - r.upperBound)) < 1e-9, "rear start must mirror front end at \(duration)%")
            #expect(abs(f.upperBound - (1 - r.lowerBound)) < 1e-9, "rear end must mirror front start at \(duration)%")
            #expect(abs(r.upperBound - 1) < 1e-9, "rear always ends at the closing edge")
        }
    }

    @Test func durationIsClampedIntoTheShippableRange() {
        let under = FlashTimingPolicy.timing(exposure: 1.0 / 4.0, durationPercent: 0, sync: .front)
        #expect(under == .lit(start: 0, end: 0.05))
        let over = FlashTimingPolicy.timing(exposure: 1.0 / 4.0, durationPercent: 400, sync: .front)
        #expect(over == .lit(start: 0, end: 1))
        // A non-finite duration is not a shorter exposure, it is a missing value.
        let nan = FlashTimingPolicy.timing(exposure: 1.0 / 4.0, durationPercent: .nan, sync: .front)
        #expect(nan == .lit(start: 0, end: 1))
    }

    @Test func anUnshapedLampCoversTheWholeWindow() {
        #expect(FlashTimingPolicy.timing(exposure: 1.0 / 4.0, durationPercent: 40, sync: .off)
            == .lit(start: 0, end: 1))
    }

    @Test func belowTheShapingFloorTheIntervalIsUnshapableNotClamped() {
        // The floor is provisional (unmeasured), but the rule it encodes is not:
        // a lamp that cannot be shaped must say so instead of pretending.
        let fast = FlashTimingPolicy.timing(exposure: 1.0 / 500.0, durationPercent: 40, sync: .front)
        #expect(fast.isLit == false)
        #expect(fast.interval == nil, "a clamped interval here would be a control that lies")
        #expect(fast.disabledReason == FlashTimingPolicy.unshapableReason)

        #expect(FlashTimingPolicy.timing(exposure: 0, durationPercent: 40, sync: .front).isLit == false)
        #expect(FlashTimingPolicy.timing(exposure: .nan, durationPercent: 40, sync: .front).isLit == false)
        // Exactly at the floor is shapable, and so is everything slower.
        #expect(FlashTimingPolicy.timing(exposure: FlashTimingPolicy.minimumShapableExposure,
                                         durationPercent: 40, sync: .front).isLit)
        #expect(FlashTimingPolicy.timing(exposure: 0.5, durationPercent: 40, sync: .front).isLit)
    }

    @Test func theLitIntervalNeverLeavesTheWindow() {
        for exposure in [1.0 / 30.0, 1.0 / 8.0, 0.25, 2.0] {
            for duration in [5.0, 40, 100] {
                for sync in FlashSync.allCases {
                    guard let interval = FlashTimingPolicy.timing(exposure: exposure,
                                                                  durationPercent: duration,
                                                                  sync: sync).interval else { continue }
                    #expect(interval.lowerBound >= 0)
                    #expect(interval.upperBound <= 1)
                }
            }
        }
    }

    // MARK: - Settings

    @Test func settingsDefaultToALampThatIsOff() {
        let standard = FlashSettings.standard
        #expect(standard.videoLevel == 0)
        #expect(standard.photoIntensity == 0)
        #expect(standard.photoDurationPercent == 100)
        #expect(!standard.isVideoLampOn)
        #expect(!standard.isPhotoLampOn)
        #expect(standard.pillText(photoMode: false) == "OFF")
        #expect(standard.pillText(photoMode: true) == "OFF")
    }

    @Test func settingsClampEveryValueIntoItsRange() {
        let low = FlashSettings(videoLevel: -3, photoIntensity: -1, photoDurationPercent: 1)
        #expect(low.videoLevel == 0)
        #expect(low.photoIntensity == 0)
        #expect(low.photoDurationPercent == 5)
        let high = FlashSettings(videoLevel: 4, photoIntensity: 9, photoDurationPercent: 400)
        #expect(high.videoLevel == 1)
        #expect(high.photoIntensity == 1)
        #expect(high.photoDurationPercent == 100)
        // A non-finite value falls back to the setting's own default rather than
        // to an edge of the range, so a corrupt read cannot become full power.
        let nan = FlashSettings(videoLevel: .nan, photoIntensity: .infinity,
                                photoDurationPercent: .nan)
        #expect(nan.videoLevel == 0)
        #expect(nan.photoIntensity == 0)
        #expect(nan.photoDurationPercent == 100)
    }

    @Test func thePillReadsTheLevelInVideoAndOnOffInPhoto() {
        let video = FlashSettings(videoLevel: 0.4)
        #expect(video.pillText(photoMode: false) == "40%")
        #expect(video.pillText(photoMode: true) == "OFF")
        let photo = FlashSettings(photoIntensity: 0.5, photoDurationPercent: 25)
        #expect(photo.pillText(photoMode: true) == "ON")
        #expect(photo.accessibilityValue(photoMode: true) == "Photo flash on")
        #expect(FlashSettings.standard.accessibilityValue(photoMode: true) == "Photo flash off")
        #expect(video.accessibilityValue(photoMode: false) == "Lamp at 40 percent for the take")
        #expect(photo.pillText(photoMode: false) == "OFF", "a photo setting cannot light a take")
        // Intensity zero is the switch: nothing fires and the pill says so.
        let off = FlashSettings(photoIntensity: 0, photoDurationPercent: 40)
        #expect(off.pillText(photoMode: true) == "OFF")
    }

    // MARK: - Persistence

    @Test func settingsRoundTripThroughTheStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "flash-tests-\(UUID().uuidString)"))
        let store = FlashSettingsStore(userDefaults: defaults)
        #expect(store.settings == .standard, "an empty store is the standard setting, never a guess")

        let chosen = FlashSettings(videoLevel: 0.35, photoIntensity: 0.6,
                                   photoDurationPercent: 40)
        store.settings = chosen
        #expect(store.settings == chosen, "a fresh read must return exactly what was written")
        // A second store over the same domain reads the same value: this is one
        // global setting, not a per-view copy.
        #expect(FlashSettingsStore(userDefaults: defaults).settings == chosen)
    }

    @Test func theStoreClampsWhatAnotherBuildWrote() throws {
        let defaults = try #require(UserDefaults(suiteName: "flash-tests-\(UUID().uuidString)"))
        defaults.set(7.5, forKey: FlashSettingsStore.Key.videoLevel)
        defaults.set(-2.0, forKey: FlashSettingsStore.Key.photoIntensity)
        defaults.set(900.0, forKey: FlashSettingsStore.Key.photoDurationPercent)
        let settings = FlashSettingsStore(userDefaults: defaults).settings
        #expect(settings.videoLevel == 1)
        #expect(settings.photoIntensity == 0)
        #expect(settings.photoDurationPercent == 100)
    }

    // MARK: - The record a file carries

    @Test func aVideoTakeRecordsContinuousAtTheLockedLevel() {
        let record = FlashRecord.video(level: 0.25, exposureSeconds: 1.0 / 48.0, refusalReason: nil)
        #expect(record.mode == .continuous)
        #expect(record.intensityPercent == 25)
        #expect(record.durationPercent == nil, "video has no window to shape, so no duration")
        #expect(record.wasRefused == false)

        let off = FlashRecord.video(level: 0, exposureSeconds: 1.0 / 48.0, refusalReason: nil)
        #expect(off.mode == .off)
        #expect(off.intensityPercent == 0)
    }

    @Test func aRefusedLevelRecordsOffWithTheReasonTheHardwareGave() {
        let record = FlashRecord.video(level: 1.0, exposureSeconds: 0.02,
                                       refusalReason: "The lamp is too hot to run at 100%.")
        #expect(record.mode == .off, "nothing lit, so the file must not claim a lit take")
        #expect(record.wasRefused)
        #expect(record.intensityPercent == 100, "it records what was asked and that it was refused")
        #expect(record.metadataValues[FlashRecord.refusedKey] == "true")
        #expect(record.metadataValues[FlashRecord.refusedReasonKey] == record.refusalReason)
    }

    @Test func aPhotoRecordsFrontWithTheDurationItActuallyCovered() {
        let settings = FlashSettings(photoIntensity: 0.4, photoDurationPercent: 40)
        let timing = FlashTimingPolicy.timing(exposure: 0.25, durationPercent: 40, sync: .front)
        let record = FlashRecord.photo(settings: settings, timing: timing,
                                       exposureSeconds: 0.25, refusalReason: nil)
        #expect(record.mode == .front)
        #expect(record.intensityPercent == 40)
        #expect(record.durationPercent == 40)
        #expect(record.exposureSeconds == 0.25)
        #expect(record.didFire)
    }

    @Test func belowTheFloorAPhotoRecordsTheWholeWindowBecauseThatIsWhatHappened() {
        let settings = FlashSettings(photoIntensity: 0.4, photoDurationPercent: 40)
        let timing = FlashTimingPolicy.timing(exposure: 1.0 / 500.0, durationPercent: 40, sync: .front)
        // The controller holds the lamp for the whole exposure in this case and
        // passes `durationPercent: 100`; the record must agree with the light.
        let record = FlashRecord(mode: .front, intensityPercent: settings.photoPercent,
                                 durationPercent: 100, exposureSeconds: 1.0 / 500.0)
        #expect(!timing.isLit)
        #expect(record.durationPercent == 100)
    }

    @Test func theMetadataPayloadRoundTripsThroughAFile() {
        let record = FlashRecord(mode: .front, intensityPercent: 40, durationPercent: 25,
                                 exposureSeconds: 0.25)
        let values = record.metadataValues
        #expect(values[FlashRecord.modeKey] == "front")
        #expect(values[FlashRecord.intensityKey] == "40")
        #expect(values[FlashRecord.durationKey] == "25")
        #expect(values[FlashRecord.exposureKey] == "0.250000")
        #expect(values[FlashRecord.refusedKey] == "false")
        #expect(FlashRecord.decode(values) == record, "a file must read back as the record it came from")
        // A file with no lamp keys is not a lamp that was off: it is no record.
        #expect(FlashRecord.decode([:]) == nil)
    }

    // MARK: - The rule that must never regress

    @Test func nativeFlashRecordsResolvedFiringWithoutInventingPowerOrDuration() throws {
        let record = FlashRecord.nativePhoto(requested: true, resolved: true)
        #expect(record.mode == .native)
        #expect(record.didFire)
        #expect(!record.wasRefused)
        #expect(record.intensityPercent == nil)
        #expect(record.durationPercent == nil)
        #expect(record.exposureSeconds == nil)
        #expect(record.metadataValues[FlashRecord.intensityKey] == nil)
        #expect(record.metadataValues[FlashRecord.durationKey] == nil)
        #expect(record.metadataValues[FlashRecord.requestedKey] == "true")
        #expect(record.metadataValues[FlashRecord.resolvedKey] == "true")
        // The sidecar and JPEG payload both transport string dictionaries.
        let data = try JSONSerialization.data(withJSONObject: record.metadataValues)
        let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(FlashRecord.decode(values) == record)
        #expect(record.summary == "native photo flash fired (power and duration unmeasured)")
    }

    @Test func nativeFlashRefusalDoesNotClaimFiringOrMeasuredPower() {
        for reason in [nil, "Native photo flash is not supported by this camera output.", "The flash is too hot."] as [String?] {
            let record = FlashRecord.nativePhoto(requested: true, resolved: false, refusalReason: reason)
            #expect(record.mode == .off)
            #expect(!record.didFire)
            #expect(record.wasRefused)
            #expect(record.refusalReason != nil)
            if let reason { #expect(record.refusalReason == reason) }
            #expect(record.intensityPercent == nil)
            #expect(record.durationPercent == nil)
            #expect(record.metadataValues[FlashRecord.intensityKey] == nil)
            #expect(record.metadataValues[FlashRecord.durationKey] == nil)
            #expect(record.metadataValues[FlashRecord.requestedKey] == "true")
            #expect(record.metadataValues[FlashRecord.resolvedKey] == "false")
            #expect(FlashRecord.decode(record.metadataValues) == record)
        }
    }

    @Test func nativeFlashIntentAloneIsNotEvidenceOfFiring() {
        let pending = FlashRecord.nativePhoto(requested: true, resolved: nil)
        #expect(!pending.didFire)
        #expect(!pending.wasRefused)
        #expect(pending.metadataValues[FlashRecord.resolvedKey] == nil)
        #expect(FlashRecord.decode(pending.metadataValues) == pending)
        let off = FlashRecord.nativePhoto(requested: false, resolved: false)
        #expect(!off.didFire)
        #expect(!off.wasRefused)
        #expect(FlashRecord.decode(off.metadataValues) == off)
        // Resolution, not intent, controls the delivered EXIF fired bit.
        #expect(FlashRecord.nativePhoto(requested: false, resolved: true).didFire)
    }

    @Test func historicTorchMetadataStillDecodesUnchanged() {
        for mode in [FlashMode.front, .rear, .continuous, .off] {
            var values = ["flash-mode": mode.rawValue, "flash-intensity-percent": "40",
                          "flash-duration-percent": "25", "flash-exposure-seconds": "0.250000",
                          "flash-refused": "false"]
            let record = FlashRecord(mode: mode, intensityPercent: 40, durationPercent: 25, exposureSeconds: 0.25)
            #expect(FlashRecord.decode(values) == record)
            #expect(record.metadataValues == values)
            values["flash-refused"] = "true"
            values["flash-refused-reason"] = "The lamp was too hot."
            #expect(FlashRecord.decode(values)?.refusalReason == "The lamp was too hot.")
        }
        #expect(FlashRecord.decode(["flash-mode": "off"]) == .off)
    }

    @Test func legacySettingsDecodeAndPhotoToggleLeavesVideoPreferencesIndependent() throws {
        let data = Data(#"{"videoLevel":0.35,"photoIntensity":0.6,"photoDurationPercent":40}"#.utf8)
        var settings = try JSONDecoder().decode(FlashSettings.self, from: data)
        #expect(settings.pillText(photoMode: true) == "ON")
        #expect(settings.photoDurationPercent == 40)
        let defaults = try #require(UserDefaults(suiteName: "native-flash-tests-\(UUID().uuidString)"))
        let store = FlashSettingsStore(userDefaults: defaults)
        for level in [0.0, 1.0] {
            settings.photoIntensity = level
            store.settings = settings
            #expect(store.settings.videoLevel == 0.35)
            #expect(store.settings.pillText(photoMode: false) == "35%")
            #expect(store.settings.photoDurationPercent == 40)
            #expect(store.settings.isPhotoLampOn == (level > 0))
        }
        #expect(FlashRecord.video(level: store.settings.videoLevel, exposureSeconds: nil,
                                  refusalReason: nil).intensityPercent == 35)
    }

    @Test func captureBridgeUsesResolvedFlashInsideItsExistingTransactionFence() throws {
        let builder = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraPhotoCapture.swift"),
                                 encoding: .utf8)
        #expect(builder.contains("flashRequested: Bool = false"), "old direct smoke callers remain off")
        #expect(builder.contains("photo.resolvedSettings.isFlashEnabled"))
        #expect(builder.contains("resolvedSettings.isFlashEnabled"))
        #expect(builder.contains("guard self.accept(id) else { return }"))
        #expect(builder.contains("state.uniqueID == id"))
        #expect(builder.contains("self.recordResolvedFlash(flashEnabled)"))
        #expect(builder.contains("FlashRecord.requestedKey, FlashRecord.resolvedKey"), "manifest allowlist carries both facts")
        #expect(builder.contains("data.count <= 4096"))
    }

    @Test func normalStillsUseNativeFlashWithoutPhotoTorchLevels() throws {
        let builder = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/CameraPhotoCapture.swift"),
                                 encoding: .utf8)
        let controller = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/DevelopmentPhotoController.swift"),
                                    encoding: .utf8)
        #expect(builder.range(of: #"raw\.flashMode\s*=(?!=)"#, options: .regularExpression) != nil,
                "the normal RAW helper must explicitly assign native flash mode")
        #expect(builder.contains("supportedFlashModes"), "unsupported native flash must be refused")
        #expect(controller.contains("flashRequested: flash.isPhotoLampOn"))
        #expect(!controller.contains("torch.setLevel("), "Photo must not substitute continuous torch for native flash")
        #expect(!controller.contains("armFlashOff("), "Photo must not time a software torch pulse")
        #expect(controller.contains("torch.turnOff()"), "retain torch teardown safety")
        #expect(builder.contains("output.capturePhoto(with: settings, delegate: self)"))
    }

    /// The torch is touched in exactly one type: a second caller is how a lamp
    /// gets left on.
    @Test func onlyTheTorchControllerTouchesTheTorch() throws {
        let files = [
            "App/Modules/CameraCapture/CameraPhotoCapture.swift",
            "App/Modules/CameraCapture/DevelopmentPhotoController.swift",
            "App/Modules/CameraCapture/CameraSession.swift",
            "App/Modules/CameraCapture/CameraViewModel.swift"
        ]
        for path in files {
            let source = try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
            #expect(!source.contains("setTorchModeOn"),
                    "\(path) drives the LED directly instead of through FlashTorchController")
            #expect(!source.contains("torchMode ="), "\(path) sets torchMode directly")
        }
        let controller = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/FlashTorchController.swift"),
                                    encoding: .utf8)
        #expect(controller.contains("device.setTorchModeOn(level:"))
        // A refusal is surfaced, never worked around with a dimmer lamp.
        #expect(controller.contains("AVError.Code.torchLevelUnavailable"))
        #expect(!controller.contains("level / 2"), "a refused level must not be silently halved")
    }
}
