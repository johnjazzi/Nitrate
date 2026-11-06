import CoreGraphics
import Foundation
import Testing

/// The capture-format preference and the selector that honours it. Pure values
/// only: the AVFoundation question ("does this phone have the format") lives in
/// `CaptureFormatAvailability` and is answered by the hardware, not here.
struct CaptureFormatTests {

    // MARK: - Preference

    @Test func theShippingCaptureIsTheDefault() {
        #expect(CaptureFormat.defaultValue == .uhd16x9)
        #expect(CaptureFormat.resolved(nil) == .uhd16x9)
        #expect(CaptureFormat.resolved("") == .uhd16x9)
        #expect(CaptureFormat.resolved("open-gate-3k") == .uhd16x9,
                "an unknown stored value must never invent a geometry")
    }

    @Test func openGateIsTheNativeTwoKReadout() {
        #expect(CaptureFormat.openGate2K.width == 1920)
        #expect(CaptureFormat.openGate2K.height == 1440)
        #expect(CaptureFormat.openGate2K.isOpenGate)
        #expect(CaptureFormat.openGate2K.requiresTenBit422,
                "open gate is contracted to the 4:2:2 readout, never the 4:2:0 one")
        #expect(!CaptureFormat.uhd16x9.isOpenGate)
    }

    @Test func theStoredStringIsTheMetadataString() {
        // The Settings row writes `rawValue`; the delivered metadata records the
        // same string, so a file can be traced back to the choice unambiguously.
        #expect(CaptureFormat.openGate2K.rawValue == "open-gate-2k")
        #expect(CaptureFormat.uhd16x9.rawValue == "uhd-16x9")
    }

    @Test func aStoredSelectionRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "capture-format-\(UUID().uuidString)"))
        #expect(CaptureFormat.load(from: defaults) == .uhd16x9)
        defaults.set(CaptureFormat.openGate2K.rawValue, forKey: CaptureFormat.preferenceKey)
        #expect(CaptureFormat.load(from: defaults) == .openGate2K)
        defaults.set("bogus", forKey: CaptureFormat.preferenceKey)
        #expect(CaptureFormat.load(from: defaults) == .uhd16x9)
    }

    // MARK: - Format selection

    private func candidates() -> [CameraCaptureFormatPolicy.Candidate] {
        [
            // The shipping UHD 4:2:0 and 4:2:2 formats.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true),
            // Open gate: the real one, plus an 8-bit-shaped trap and a 4:2:0 one.
            .init(width: 1920, height: 1440, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true),
            .init(width: 1920, height: 1440, supportsAppleLog2: false, supports24FPS: true,
                  isTenBitBiPlanar420: true),
            .init(width: 1920, height: 1440, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true)
        ]
    }

    @Test func openGateSelectsOnlyTheTenBit422LogFormat() {
        let candidates = candidates()
        let indexes = CameraCaptureFormatPolicy.eligibleCandidateIndexes(
            in: candidates, format: .openGate2K, fps: 24)
        #expect(indexes == [2], "only the 4:2:2 Log 2 1920x1440 format is open gate")
        #expect(candidates[indexes[0]].isTenBitBiPlanar422)
        #expect(candidates[indexes[0]].supportsAppleLog2)
    }

    @Test func uhdKeepsItsShippingPreference() {
        let candidates = candidates()
        let indexes = CameraCaptureFormatPolicy.eligibleCandidateIndexes(
            in: candidates, format: .uhd16x9, fps: 24)
        #expect(indexes == [0, 1], "4:2:0 first, then 4:2:2 — unchanged")
    }

    @Test func aDeviceWithoutTheFormatPublishesNoOpenGateOption() {
        let uhdOnly = candidates().filter { $0.width == 3840 }
        #expect(!CameraCaptureFormatPolicy.supports(.openGate2K, in: uhdOnly))
        #expect(CameraCaptureFormatPolicy.availableFormats(in: uhdOnly) == [.uhd16x9])
    }

    @Test func aCapableDevicePublishesBothFormats() {
        #expect(CameraCaptureFormatPolicy.availableFormats(in: candidates()) == [.uhd16x9, .openGate2K])
    }

    @Test func aMissingFrameRateIsARefusalNotADowngrade() {
        let sixtyOnly = [
            CameraCaptureFormatPolicy.Candidate(width: 1920, height: 1440,
                                                supportsAppleLog2: true, supports24FPS: false,
                                                isTenBitBiPlanar422: true, supports60FPS: true)
        ]
        #expect(!CameraCaptureFormatPolicy.supports(.openGate2K, in: sixtyOnly, fps: 24))
        #expect(CameraCaptureFormatPolicy.supports(.openGate2K, in: sixtyOnly, fps: 60))
    }

    // MARK: - Interaction with delivery framing

    @Test func openGateIsNotCroppedAgainByAFourThreeDelivery() {
        let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 1920, height: 1440))
        #expect(!delivery.isCropped, "a 4:3 source has nothing left to crop")
        #expect(delivery.deliveredWidth == 1920)
        #expect(delivery.deliveredHeight == 1440)
    }

    @Test func fourTwoTwoIsPreferredOnlyWhenTheFormatCarriesIt() {
        let available: [UInt32] = [0x78343230, 0x78343232] // x420, x422
        #expect(CameraSampleValidationPolicy.preferredTenBitPixelFormats(
            from: available).first == 0x78343230,
                "the shipping path keeps 4:2:0 first")
        #expect(CameraSampleValidationPolicy.preferredTenBitPixelFormats(
            from: available, preferFourTwoTwo: true).first == 0x78343232,
                "a 4:2:2 capture format feeds a 4:2:2 source buffer")
    }

    @Test func theValidatorAcceptsTheOpenGateCodedDimensions() {
        // The writer negotiates against the active format; the validator has to
        // admit the 2K pair or a 1920x1440 take is rejected after it started.
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 1920, height: 1440) != nil)
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 1440, height: 1920) != nil)
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 1920, height: 1080) == nil)
    }

    @Test func aWidescreenDeliveryStillCropsWhenUhdIsRecorded() {
        let delivery = DeliveryFraming.fourThree.delivery(forSourceSize: CGSize(width: 3840, height: 2160))
        #expect(delivery.isCropped)
        #expect(delivery.deliveredWidth == 2880)
        #expect(delivery.deliveredHeight == 2160)
    }
}
