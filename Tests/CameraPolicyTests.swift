import Foundation
import AVFoundation
import CoreVideo
import CoreImage

import Testing

@Suite("Camera lifecycle and recording policies")
struct CameraPolicyTests {
    @Test func apertureStopsAreFiniteBoundedAndDescribeFixedOrVariableHardware() {
        let stops = CameraAperturePolicy.recommendedStops(
            [2.8, .nan, 1.4, 8, .infinity, 1.4], minimum: 1.4, maximum: 5.6)
        #expect(stops == [1.4, 2.8])
        #expect(CameraAperturePolicy.capability(
            recommended: [2.8], minimum: 1.4, maximum: 5.6) == .fixed(2.8))
        #expect(CameraAperturePolicy.capability(
            recommended: [1.4, 2.8], minimum: 1.4, maximum: 5.6) == .variable([1.4, 2.8]))
        #expect(CameraAperturePolicy.capability(
            recommended: [.nan, 8], minimum: 1.4, maximum: 5.6) == .unavailable)
        #expect(CameraAperturePolicy.recommendedStops([1, 2], minimum: 3, maximum: 2).isEmpty)
    }

    @Test func apertureSelectionReconcilesToNearestSupportedStopAfterLensChange() {
        let variable: CameraAperturePolicy.Capability = .variable([1.4, 2, 2.8, 4])
        #expect(CameraAperturePolicy.reconcile(2.5, with: variable) == 2.8)
        #expect(CameraAperturePolicy.reconcile(1.2, with: .fixed(2)) == 2)
        #expect(CameraAperturePolicy.reconcile(nil, with: variable) == nil)
        #expect(CameraAperturePolicy.reconcile(2, with: .unavailable) == nil)
    }

    @Test func apertureExposureCompositionPreservesManualISOAndAutomaticISO() {
        let duration = CMTime(value: 1, timescale: 48)
        let shutterPriority = CameraAperturePolicy.exposureParameters(
            selectedAperture: 2.8, heldAperture: -1, mode: .shutterPriority,
            manualISO: 640, autoISO: -2, minISO: 25, maxISO: 6400, duration: duration)
        #expect(shutterPriority?.aperture == 2.8)
        #expect(shutterPriority?.duration == duration)
        #expect(shutterPriority?.iso == -2)

        let manual = CameraAperturePolicy.exposureParameters(
            selectedAperture: nil, heldAperture: -1, mode: .manual,
            manualISO: 7000, autoISO: -2, minISO: 25, maxISO: 6400, duration: duration)
        #expect(manual?.aperture == -1)
        #expect(manual?.iso == 6400)
        #expect(CameraAperturePolicy.exposureParameters(
            selectedAperture: .infinity, heldAperture: -1, mode: .manual,
            manualISO: 100, autoISO: -2, minISO: 25, maxISO: 6400, duration: duration) == nil)
    }

    @Test func unsupportedExactApertureCombinationDoesNotRunTheDeviceMutation() throws {
        let parameters = try #require(CameraAperturePolicy.exposureParameters(
            selectedAperture: 2.8, heldAperture: -1, mode: .manual,
            manualISO: 400, autoISO: -2, minISO: 25, maxISO: 6400,
            duration: CMTime(value: 1, timescale: 48)))
        var mutationCount = 0
        let rejected = CameraAperturePolicy.performIfSupported(parameters, supports: { _ in false }) {
            mutationCount += 1
        }
        #expect(!rejected)
        #expect(mutationCount == 0)

        let accepted = CameraAperturePolicy.performIfSupported(parameters, supports: { $0 == parameters }) {
            mutationCount += 1
        }
        #expect(accepted)
        #expect(mutationCount == 1)
    }

    @Test func shutterPriorityEVScalesMeteredISOAndManualISOStaysPinned() throws {
        let positiveEV = try #require(CameraAperturePolicy.evCompensatedISO(
            meteredISO: 100, ev: 1, minimum: 25, maximum: 6400))
        let negativeEV = try #require(CameraAperturePolicy.evCompensatedISO(
            meteredISO: 100, ev: -1, minimum: 25, maximum: 6400))
        #expect(positiveEV == 200)
        #expect(negativeEV == 50)

        let manual = try #require(CameraAperturePolicy.exposureParameters(
            selectedAperture: 2.8, heldAperture: -1, mode: .manual,
            manualISO: 640, autoISO: -2, minISO: 25, maxISO: 6400,
            duration: CMTime(value: 1, timescale: 48)))
        #expect(manual.iso == 640)
        #expect(manual.aperture == 2.8)
    }

    @Test func recordingPinFreezesMeasuredAutoApertureAndRestoresChoice() throws {
        let autoPin = try #require(CameraAperturePolicy.recordingPin(
            selectedAperture: nil, measuredAperture: 2.4))
        #expect(autoPin.aperture == 2.4)
        #expect(autoPin.restoresAuto)
        #expect(CameraAperturePolicy.selectedApertureAfterRecording(pin: autoPin) == nil)
        // Start failure and normal writer completion share this terminal policy.
        #expect(CameraAperturePolicy.selectedApertureAfterRecording(pin: autoPin) == nil)

        let explicitPin = try #require(CameraAperturePolicy.recordingPin(
            selectedAperture: 2.8, measuredAperture: 2.4))
        #expect(explicitPin.aperture == 2.8)
        #expect(!explicitPin.restoresAuto)
        #expect(CameraAperturePolicy.selectedApertureAfterRecording(pin: explicitPin) == 2.8)
        #expect(CameraAperturePolicy.recordingPin(selectedAperture: nil, measuredAperture: .nan) == nil)
    }

    @Test func captureFormatSearchFindsLog2AlternativeAndRejectsUnsupportedLens() {
        let unsupported: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: false, supports24FPS: true),
            .init(width: 1920, height: 1080, supportsAppleLog2: true, supports24FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: false,
                  isTenBitBiPlanar420: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: unsupported) == nil)
        let candidates = unsupported + [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: candidates) == 3)
        let eightBit = CameraCaptureFormatPolicy.Candidate(
            width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true)
        #expect(CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: [eightBit]).isEmpty)
    }

    @Test func preferredTenBitLog2FormatIsFirstAndAllEligibleCandidatesRemainAvailable() {
        let formats: [CameraCaptureFormatPolicy.Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: formats) == [1, 0])
        #expect(CameraCaptureFormatPolicy.appleLog2Index(in: [formats[0]]) == 0)
    }

    @Test func outputPixelNegotiationKeepsAdvertisedTenBitFallbacksAndReportsFourCCs() {
        let x420: UInt32 = 0x78343230
        let xf20: UInt32 = 0x78663230
        let x422: UInt32 = 0x78343232
        let result = CameraSampleValidationPolicy.preferredTenBitPixelFormats(
            from: [0x42475241, x422, 0x3231564e, xf20, x420]
        )
        #expect(result == [xf20, x420, x422])
        #expect(CameraSampleValidationPolicy.preferredTenBitPixelFormats(from: [0x42475241]).isEmpty)
        #expect(CameraSampleValidationPolicy.fourCCListDescription([xf20, x420, x422]) == "xf20, x420, x422")
        #expect(CameraSampleValidationPolicy.fourCCListDescription([]) == "none")
        var attempted: [UInt32] = []
        let selected = CameraSampleValidationPolicy.firstUsableTenBitPixelFormat(
            from: [x422, xf20, x420]
        ) { pixelFormat in
            attempted.append(pixelFormat)
            return pixelFormat == x422
        }
        #expect(attempted == [xf20, x420, x422])
        #expect(selected == x422)
        #expect(CameraSampleValidationPolicy.hasHEVCEncoder(["apcs", "apcn"]) == false)
        #expect(CameraSampleValidationPolicy.hasHEVCEncoder(["hvc1"]))
        let profile = "Main10_AutoLevel"
        // Bind as AVVideoCodecType: AVFoundation boxes AVVideoCodecKey that way,
        // so a String cast silently yields nil and rejects valid HEVC settings.
        #expect(CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: .hevc, width: 3840, height: 2160, profile: profile, expectedProfile: profile
        ))
        #expect(CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: .hevc, width: 2160, height: 3840, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: .proRes422, width: 3840, height: 2160, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: .hevc, width: 1920, height: 1080, profile: profile, expectedProfile: profile
        ))
        #expect(!CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: .hevc, width: 3840, height: 2160, profile: "Main_AutoLevel", expectedProfile: profile
        ))
    }

    @Test func recordedOriginalRequestsAACAudioRatherThanTheDeviceRecommendation() {
        let settings = CameraSampleValidationPolicy.aacAudioSettings(
            sampleRate: 48_000, channels: 1, averageBitRate: 192_000)
        #expect((settings[AVFormatIDKey] as? UInt32) == kAudioFormatMPEG4AAC)
        #expect((settings[AVSampleRateKey] as? Double) == 48_000)
        #expect((settings[AVNumberOfChannelsKey] as? Int) == 1)
        #expect((settings[AVEncoderBitRateKey] as? Int) == 192_000)
        // lpcm must never survive as the recorded codec.
        #expect(settings[AVFormatIDKey] as? UInt32 != kAudioFormatLinearPCM)
    }

    @Test func aacSampleRateIsCoercedToASupportedValue() {
        #expect(CameraSampleValidationPolicy.normalizedAACSampleRate(48_000) == 48_000)
        #expect(CameraSampleValidationPolicy.normalizedAACSampleRate(44_100) == 44_100)
        #expect(CameraSampleValidationPolicy.normalizedAACSampleRate(0) == 48_000)
        #expect(CameraSampleValidationPolicy.normalizedAACSampleRate(22_050) == 48_000)
    }

    @Test func explicitMain10SettingsDoNotDependOnCaptureOutputCodecRecommendation() throws {
        let captureOutputCodecs = ["apch", "apcn", "apcs", "apco"]
        #expect(!CameraSampleValidationPolicy.hasHEVCEncoder(captureOutputCodecs))

        let profile = "Main10_AutoLevel"
        let logTransferKey = "AVVideoLogTransferFunctionKey"
        let logTransferValue = "AVVideoLogTransferFunction_AppleLog2"
        let matrixKey = "AVVideoYCbCrMatrixKey"
        let matrixValue = "AVVideoYCbCrMatrix_ITU_R_2020"
        let settings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(
            profile: profile,
            averageBitRate: 96_000_000,
            colorProperties: [logTransferKey: logTransferValue, matrixKey: matrixValue]
        )

        let settingCodec = try #require(settings[AVVideoCodecKey] as? AVVideoCodecType)
        #expect(settingCodec == .hevc)
        #expect(!captureOutputCodecs.contains(settingCodec.rawValue))
        // Production reads the codec back with the same bridging; this is the
        // guard that silently rejected valid settings on device when it cast
        // AVVideoCodecKey to String instead of AVVideoCodecType.
        #expect(CameraSampleValidationPolicy.acceptsHEVCMain10Settings(
            codec: settingCodec, width: 3840, height: 2160, profile: profile, expectedProfile: profile
        ))
        #expect((settings[AVVideoWidthKey] as? NSNumber)?.intValue == 3840)
        #expect((settings[AVVideoHeightKey] as? NSNumber)?.intValue == 2160)
        let portraitSettings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(
            width: 2160, height: 3840, profile: profile,
            averageBitRate: 96_000_000, colorProperties: [logTransferKey: logTransferValue, matrixKey: matrixValue]
        )
        #expect((portraitSettings[AVVideoWidthKey] as? NSNumber)?.intValue == 2160)
        #expect((portraitSettings[AVVideoHeightKey] as? NSNumber)?.intValue == 3840)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoProfileLevelKey] as? String == profile)
        #expect((compression[AVVideoAverageBitRateKey] as? NSNumber)?.intValue == 96_000_000)
        #expect((compression[AVVideoMaxKeyFrameIntervalKey] as? NSNumber)?.intValue == 48)
        let colors = try #require(settings[AVVideoColorPropertiesKey] as? [String: String])
        #expect(colors == [logTransferKey: logTransferValue, matrixKey: matrixValue])
        #expect(colors[AVVideoColorPrimariesKey] == nil)
        #expect(colors[AVVideoTransferFunctionKey] == nil)
    }

    @Test func sampleValidationRejectsWrongColorDomainPixelFormatAndGeometry() {
        let x420: UInt32 = 0x78343230
        let accepted: Set<UInt32> = [x420]
        func valid(width: Int = 3840, height: Int = 2160, pixel: UInt32 = x420,
                   log: String? = CameraSampleValidationPolicy.appleLog2Identifier,
                   matrix: String? = "ITU_R_2020", primaries: String? = nil,
                   transfer: String? = nil) -> Bool {
            CameraSampleValidationPolicy.accepts(width: width, height: height, pixelFormat: pixel,
                acceptedPixelFormats: accepted, logTransfer: log, matrix: matrix,
                primaries: primaries, transfer: transfer)
        }
        #expect(valid())
        #expect(valid(width: 2160, height: 3840))
        #expect(!valid(pixel: 0x42475241))
        #expect(!valid(log: "AppleLog2"))
        #expect(CameraSampleValidationPolicy.isAppleLog2(CameraSampleValidationPolicy.appleLog2Identifier))
        #expect(!valid(matrix: "ITU_R_709_2"))
        #expect(!valid(width: 1920, height: 1080))
        #expect(!valid(width: 3840, height: 3840))
        #expect(!valid(primaries: "ITU_R_2020"))
        #expect(!valid(transfer: "ITU_R_2020"))
    }

    @Test func sampleValidationReportsEachRejectedFrontFrameField() {
        let reasons = CameraSampleValidationPolicy.rejectionReasons(
            width: 1920, height: 1080, pixelFormat: 0x42475241,
            acceptedPixelFormats: [0x78343230], logTransfer: "AppleLog2",
            matrix: nil, primaries: "ITU_R_2020", transfer: "ITU_R_2020"
        )
        #expect(reasons == [
            "format dimensions are 1920x1080, expected 3840x2160 or 2160x3840",
            "pixel format BGRA was not negotiated",
            "Log transfer is AppleLog2, expected Apple Log 2",
            "YCbCr matrix is missing, expected ITU_R_2020",
            "color primaries is ITU_R_2020, expected missing or Unspecified",
            "transfer function is ITU_R_2020, expected missing or Unspecified"
        ])
    }

    @Test func sampleClockRejectsPrerollAndNonIncreasingTimestamps() {
        #expect(!CameraSampleValidationPolicy.audioIsAfterSessionStart(sampleTime: 0.99, sessionStart: 1))
        #expect(CameraSampleValidationPolicy.audioIsAfterSessionStart(sampleTime: 1, sessionStart: 1))
        #expect(CameraSampleValidationPolicy.timestampIsIncreasing(current: 1, previous: nil))
        #expect(CameraSampleValidationPolicy.timestampIsIncreasing(current: 2, previous: 1))
        #expect(!CameraSampleValidationPolicy.timestampIsIncreasing(current: 1, previous: 1))
        #expect(!CameraSampleValidationPolicy.timestampIsIncreasing(current: .infinity, previous: nil))
        #expect(!CameraSampleValidationPolicy.shouldFailForFrameDrops(recentDropCount: 2))
        #expect(CameraSampleValidationPolicy.shouldFailForFrameDrops(recentDropCount: 3))
        #expect(CameraSampleValidationPolicy.dropTimesWithinWindow([0, 1.9], now: 3.8) == [1.9, 3.8])
    }

    @Test func cancelledStartRetainsRecorderEpochUntilItsTerminalCallback() throws {
        var bridge = CameraRecorderCompletionBridge()
        let firstStarted = bridge.begin(epoch: 41)
        #expect(firstStarted)
        bridge.cancelUserStart(epoch: 41)
        #expect(!bridge.acceptsStarted(epoch: 41))
        let firstTerminal: Bool? = bridge.consumeTerminal(epoch: 41)
        let userWasNotified = try #require(firstTerminal)
        #expect(!userWasNotified)
        #expect(bridge.activeEpoch == nil)

        let secondStarted = bridge.begin(epoch: 42)
        #expect(secondStarted)
        let staleTerminal: Bool? = bridge.consumeTerminal(epoch: 41)
        #expect(staleTerminal == nil)
        #expect(bridge.activeEpoch == 42)
        #expect(bridge.acceptsStarted(epoch: 42))
    }

    @Test func portraitTrackMatrixKeepsCodedLandscapeAndDisplaysPortrait() {
        let transform = CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: 3840, codedHeight: 2160)
        #expect(CameraSampleValidationPolicy.displayDimensions(
            codedWidth: 3840, codedHeight: 2160, transform: transform
        ).0 == 2160)
        #expect(CameraSampleValidationPolicy.displayDimensions(
            codedWidth: 3840, codedHeight: 2160, transform: transform
        ).1 == 3840)
        #expect(transform.a == 0 && transform.b == 1 && transform.c == -1 && transform.d == 0)
        #expect(transform.tx == 2160 && transform.ty == 0)
        let nativePortrait = CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: 2160, codedHeight: 3840)
        #expect(nativePortrait == .identity)
        #expect(CameraSampleValidationPolicy.displayDimensions(
            codedWidth: 2160, codedHeight: 3840, transform: nativePortrait
        ) == (2160, 3840))
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 3840, height: 2160)
            == .landscape4K)
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 2160, height: 3840)
            == .portrait4K)
        #expect(CameraSampleValidationPolicy.CodedDimensions(width: 3840, height: 3840) == nil)
    }

    @Test func portraitTrackMatrixRoundTripsThroughAVAssetWriter() async throws {
        let width = 64
        let height = 32
        let transform = CameraSampleValidationPolicy.portraitTrackTransform(codedWidth: width, codedHeight: height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("track-transform-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        try #require(writer.canApply(outputSettings: settings, forMediaType: .video))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        try #require(writer.canAdd(input))
        writer.add(input)

        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &optionalBuffer)
        let buffer = try #require(pixelStatus == kCVReturnSuccess ? optionalBuffer : nil)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
        )
        let videoFormat = try #require(formatStatus == noErr ? format : nil)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: videoFormat,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        let videoSample = try #require(sampleStatus == noErr ? sample : nil)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try #require(input.append(videoSample))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        try #require(writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let track = try #require(asset.tracks(withMediaType: .video).first)
        #expect(track.preferredTransform == transform)
    }

    @Test func recorderLifecycleHandlesEarlyStopFailureAndClipRecovery() throws {
        var state = CameraSampleBufferRecorderState.idle
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .begin))
        #expect(state == .awaitingVideo)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .failure))
        #expect(state == .failed)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop) == nil)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .reset))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .begin))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .firstVideoAppend))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop))
        #expect(state == .finishing)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .stop) == nil)
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .finishSuccess))
        state = try #require(CameraSampleBufferRecorderLifecyclePolicy.transition(state, on: .reset))
        #expect(state == .idle)
        #expect(CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 9, activeGeneration: 9
        ))
        #expect(!CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 8, activeGeneration: 9
        ))
        #expect(!CameraSampleBufferRecorderLifecyclePolicy.acceptsCompletion(
            callbackGeneration: 9, activeGeneration: nil
        ))
    }

    @Test func lifecycleActivationIsIdempotentAndBackgroundInvalidatesPendingConfigure() throws {
        var gate = CameraLifecycleGate()
        let firstActivation = gate.activate()
        let firstGeneration = try #require(firstActivation)
        let duplicateActivation = gate.activate()
        #expect(duplicateActivation == nil)
        #expect(gate.accepts(firstGeneration))

        gate.deactivate()
        #expect(!gate.accepts(firstGeneration))
        let resumedActivation = gate.activate()
        let resumedGeneration = try #require(resumedActivation)
        #expect(resumedGeneration != firstGeneration)
        #expect(gate.accepts(resumedGeneration))
    }

    @Test func terminalTimerGenerationRejectsAlreadyQueuedTicksAndReplacementTicks() throws {
        var state = RecordingTimerGeneration()
        let first = state.begin()
        #expect(state.accepts(first))
        state.end()
        #expect(!state.accepts(first))

        let second = state.begin()
        #expect(second != first)
        #expect(!state.accepts(first))
        #expect(state.accepts(second))
    }

    @Test func shutterMeterCallbacksAreInvalidatedAtCameraModeBoundaries() {
        for _ in ["recording", "manual exposure", "lens change", "session stop"] {
            var generation = CameraMeteringGeneration()
            let queuedMeter = generation.issue()
            #expect(generation.accepts(queuedMeter))
            generation.invalidate()
            #expect(!generation.accepts(queuedMeter))
        }
    }

    @Test func recordingCompletionUsesTheRealNSErrorPlayableFlag() {
        let key = AVErrorRecordingSuccessfullyFinishedKey as String
        let playable = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                               userInfo: [key: NSNumber(value: true)])
        let unplayable = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                 userInfo: [key: NSNumber(value: false)])
        let missingFlag = NSError(domain: "AVFoundationErrorDomain", code: -11800)

        #expect(RecordingCompletionPolicy.shouldPublish(errorExists: false, finishedPlayable: nil))
        #expect(RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((playable as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
        #expect(!RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((unplayable as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
        #expect(!RecordingCompletionPolicy.shouldPublish(
            errorExists: true,
            finishedPlayable: ((missingFlag as NSError).userInfo[key] as? NSNumber)?.boolValue
        ))
    }

    @Test func deliveryOrientationMirrorsUIDeviceRawValuesAndDefaultsToPortrait() {
        let mapping: [(Int, CameraSampleValidationPolicy.DeliveryOrientation)] = [
            (0, .unknown), (1, .portrait), (2, .portraitUpsideDown),
            (3, .landscapeLeft), (4, .landscapeRight),
            (5, .faceUp), (6, .faceDown), (99, .unknown)
        ]
        for (raw, expected) in mapping {
            #expect(CameraSampleValidationPolicy.DeliveryOrientation(
                deviceOrientationRawValue: raw) == expected)
        }
        #expect(!CameraSampleValidationPolicy.DeliveryOrientation.portrait.isLandscape)
        #expect(CameraSampleValidationPolicy.DeliveryOrientation.landscapeLeft.isLandscape)
        #expect(CameraSampleValidationPolicy.DeliveryOrientation.landscapeRight.isLandscape)
        #expect(!CameraSampleValidationPolicy.DeliveryOrientation.faceUp.isLandscape)
        for hold in [CameraSampleValidationPolicy.DeliveryOrientation.portrait, .portraitUpsideDown,
                     .landscapeLeft, .landscapeRight] { #expect(hold.isPhysicalHold) }
        for flat in [CameraSampleValidationPolicy.DeliveryOrientation.unknown, .faceUp, .faceDown] {
            #expect(!flat.isPhysicalHold)
        }
    }

    @Test func landscapeHoldDeliversLandscapeAndPortraitHoldStaysPortraitForBothSensorBuffers() {
        let landscape = CameraSampleValidationPolicy.CodedDimensions.landscape4K
        let portrait = CameraSampleValidationPolicy.CodedDimensions.portrait4K

        // Landscape sensor buffer (the real capture buffer) at 3840x2160.
        let left = CameraSampleValidationPolicy.deliveryGeometry(for: .landscapeLeft, coded: landscape)
        #expect(left.transform == .identity)
        #expect(left.displayWidth == 3840 && left.displayHeight == 2160)
        let right = CameraSampleValidationPolicy.deliveryGeometry(for: .landscapeRight, coded: landscape)
        #expect(right.displayWidth == 3840 && right.displayHeight == 2160)
        #expect(right.transform == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 3840, ty: 2160))
        let upright = CameraSampleValidationPolicy.deliveryGeometry(for: .portrait, coded: landscape)
        #expect(upright.transform == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0))
        #expect(upright.displayWidth == 2160 && upright.displayHeight == 3840)

        // Unknown and flat holds default to portrait; upside-down preserves the opposite matrix.
        let portraitDefaults: [CameraSampleValidationPolicy.DeliveryOrientation] =
            [.unknown, .faceUp, .faceDown, .portraitUpsideDown]
        for orientation in portraitDefaults {
            let geometry = CameraSampleValidationPolicy.deliveryGeometry(for: orientation, coded: landscape)
            #expect(geometry.displayWidth == 2160 && geometry.displayHeight == 3840)
        }

        // Native portrait sensor buffer at 2160x3840.
        let nativePortrait = CameraSampleValidationPolicy.deliveryGeometry(for: .portrait, coded: portrait)
        #expect(nativePortrait.transform == .identity)
        #expect(nativePortrait.displayWidth == 2160 && nativePortrait.displayHeight == 3840)
        let nativeLandscape = CameraSampleValidationPolicy.deliveryGeometry(for: .landscapeLeft, coded: portrait)
        #expect(nativeLandscape.transform == CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 2160))
        #expect(nativeLandscape.displayWidth == 3840 && nativeLandscape.displayHeight == 2160)
    }

    @Test func oppositeHoldsHaveDistinctExactMatricesForBothCodedSizes() {
        let holds: [CameraSampleValidationPolicy.DeliveryOrientation] =
            [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
        let landscapeMatrices = [
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 3840),
            CGAffineTransform.identity,
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 3840, ty: 2160)
        ]
        let portraitMatrices = [
            CGAffineTransform.identity,
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 2160, ty: 3840),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 2160),
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 3840, ty: 0)
        ]
        for (coded, matrices) in [(CameraSampleValidationPolicy.CodedDimensions.landscape4K, landscapeMatrices),
                                  (.portrait4K, portraitMatrices)] {
            for (hold, expected) in zip(holds, matrices) {
                let actual = CameraSampleValidationPolicy.deliveryGeometry(for: hold, coded: coded)
                #expect(actual.transform == expected)
                #expect(actual.transform.a * actual.transform.d - actual.transform.b * actual.transform.c == 1)
                let bounds = CGRect(x: 0, y: 0, width: coded.width, height: coded.height)
                    .applying(actual.transform)
                #expect(bounds.minX == 0 && bounds.minY == 0)
                #expect(Int(bounds.width) == actual.displayWidth && Int(bounds.height) == actual.displayHeight)
            }
        }
    }

    @Test func captureAngleOverridesPhysicalFallbackWithoutDoubleRotatingNativePortrait() {
        let native = CameraSampleValidationPolicy.deliveryGeometry(
            for: .portrait, coded: .portrait4K, captureRotationAngle: 0)
        #expect(native.transform == .identity)
        let opposite = CameraSampleValidationPolicy.deliveryGeometry(
            for: .landscapeLeft, coded: .landscape4K, captureRotationAngle: 180)
        #expect(opposite.transform == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 3840, ty: 2160))
        let invalid = CameraSampleValidationPolicy.deliveryGeometry(
            for: .portraitUpsideDown, coded: .landscape4K, captureRotationAngle: .nan)
        #expect(invalid.transform == CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 3840))
    }

    @Test func flatCaptureKeepsLastStableCameraAngleAndFreshCaptureFallsBackToPortrait() {
        var state = CameraCaptureRotationPolicy()
        #expect(state.snapshot(for: .unknown, liveAngle: 0) == nil)
        #expect(state.snapshot(for: .landscapeRight, liveAngle: 180) == 180)
        #expect(state.snapshot(for: .faceUp, liveAngle: 0) == 180)
        #expect(state.snapshot(for: .faceDown, liveAngle: 90) == 180)
        #expect(state.snapshot(for: .unknown, liveAngle: 270) == 180)
        #expect(state.snapshot(for: .portrait, liveAngle: 90) == 90)
        #expect(state.snapshot(for: .portraitUpsideDown, liveAngle: .nan) == 90)
        // A camera switch replaces the policy state; mounting angles must not leak.
        state = CameraCaptureRotationPolicy()
        #expect(state.snapshot(for: .faceUp, liveAngle: 180) == nil)
    }

    @Test func frozenFrameRotationChangesPixelsAndNotOnlyDisplayAspect() throws {
        // Asymmetric 3x2 source with midtones and saturated colors. Exact BGRA
        // bytes detect opposite rotations, mirroring, and extra color conversion.
        let pixels: [UInt8] = [
            17, 89, 153, 255, 0, 255, 0, 255, 255, 0, 0, 255,
            181, 47, 109, 255, 0, 255, 255, 255, 255, 0, 255, 255
        ]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let orders = [[0, 1, 2, 3, 4, 5], [3, 0, 4, 1, 5, 2],
                      [5, 4, 3, 2, 1, 0], [2, 5, 1, 4, 0, 3]]
        for turns in 0..<4 {
            let oriented = try #require(CameraFrozenFrameOrientationPolicy.orient(image, quarterTurns: turns))
            #expect(oriented.width == (turns % 2 == 0 ? 3 : 2))
            #expect(oriented.height == (turns % 2 == 0 ? 2 : 3))
            let data = try #require(oriented.dataProvider?.data)
            let actual = try #require(CFDataGetBytePtr(data))
            // CI's explicit BGRA8 output is read row by row (rows may be padded).
            for (index, sourceIndex) in orders[turns].enumerated() {
                let offset = (index / oriented.width) * oriented.bytesPerRow + (index % oriented.width) * 4
                #expect(Array(UnsafeBufferPointer(start: actual + offset, count: 4)) ==
                    Array(pixels[(sourceIndex * 4)..<(sourceIndex * 4 + 4)]))
            }
        }
    }

    @Test func frozenCaptureOrientationAttachmentDoesNotAlterSourcePixelsOrColorMetadata() throws {
        var optionalBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_32BGRA,
            nil, &optionalBuffer) == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        memset(base, 0x5A, count)
        let before = Data(bytes: base, count: count)
        CameraFrozenFrameOrientationPolicy.setQuarterTurns(3, on: buffer)
        #expect(Data(bytes: base, count: count) == before)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(CameraFrozenFrameOrientationPolicy.quarterTurns(in: buffer) == 3)
        #expect(CVPixelBufferGetWidth(buffer) == 3 && CVPixelBufferGetHeight(buffer) == 2)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == "ITU_R_2020")
    }

    @Test func deliveryGeometryDisplayMatchesTheTrackMatrixHelperForEveryHold() {
        let sizes: [CameraSampleValidationPolicy.CodedDimensions] = [.landscape4K, .portrait4K]
        let orientations: [CameraSampleValidationPolicy.DeliveryOrientation] = [
            .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight, .unknown, .faceUp, .faceDown
        ]
        for coded in sizes {
            for orientation in orientations {
                let geometry = CameraSampleValidationPolicy.deliveryGeometry(for: orientation, coded: coded)
                let display = CameraSampleValidationPolicy.displayDimensions(
                    codedWidth: coded.width, codedHeight: coded.height, transform: geometry.transform)
                #expect(display.0 == geometry.displayWidth && display.1 == geometry.displayHeight,
                    "coded \(coded.width)x\(coded.height) hold \(orientation)")
            }
        }
    }

    @Test(arguments: [CameraSampleValidationPolicy.DeliveryOrientation.portrait, .portraitUpsideDown,
                      .landscapeLeft, .landscapeRight],
          [CameraSampleValidationPolicy.CodedDimensions.landscape4K, .portrait4K])
    func everyDeliveryMatrixRoundTripsThroughAVAssetWriter(
        orientation: CameraSampleValidationPolicy.DeliveryOrientation,
        coded: CameraSampleValidationPolicy.CodedDimensions
    ) async throws {
        let geometry = CameraSampleValidationPolicy.deliveryGeometry(for: orientation, coded: coded)
        // Preserve exactly the same rotation and proportional translation, while
        // keeping the real encoder round trip small enough for the test suite.
        let width = coded.width / 60
        let height = coded.height / 60
        let expectedTransform = CGAffineTransform(a: geometry.transform.a, b: geometry.transform.b,
            c: geometry.transform.c, d: geometry.transform.d,
            tx: geometry.transform.tx / 60, ty: geometry.transform.ty / 60)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("landscape-transform-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        try #require(writer.canApply(outputSettings: settings, forMediaType: .video))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = expectedTransform
        try #require(writer.canAdd(input))
        writer.add(input)

        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &optionalBuffer)
        let buffer = try #require(pixelStatus == kCVReturnSuccess ? optionalBuffer : nil)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
        )
        let videoFormat = try #require(formatStatus == noErr ? format : nil)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: videoFormat,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        let videoSample = try #require(sampleStatus == noErr ? sample : nil)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try #require(input.append(videoSample))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        try #require(writer.status == .completed)
        let asset = AVURLAsset(url: url)
        let track = try #require(asset.tracks(withMediaType: .video).first)
        #expect(track.preferredTransform == expectedTransform)
        let display = CameraSampleValidationPolicy.displayDimensions(
            codedWidth: width, codedHeight: height, transform: track.preferredTransform)
        #expect(display.0 == geometry.displayWidth / 60 && display.1 == geometry.displayHeight / 60)
    }

}
