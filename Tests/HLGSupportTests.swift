import AVFoundation
import CoreVideo
import Foundation
import Metal
import Testing
import VideoToolbox

struct HLGSupportTests {
    @Test func sourceGateDoesNotTreatLogOneAsNonLog() {
        #expect(CameraSourceProfile.permitted(supportsAppleLog: false, supportsAppleLog2: false) == .hlgBT2020)
        #expect(CameraSourceProfile.permitted(supportsAppleLog: true, supportsAppleLog2: false) == nil)
        #expect(CameraSourceProfile.permitted(supportsAppleLog: false, supportsAppleLog2: true) == .appleLog2)
        #expect(CameraSourceProfile.permitted(supportsAppleLog: true, supportsAppleLog2: true) == .appleLog2)
    }

    @Test func geometryPreferenceUsesMainOwnerAndDefault() {
        #expect(CaptureFormat.preferenceKey == "capture.format")
        #expect(CaptureFormat.resolved(nil) == .openGate2K)
        #expect(CaptureFormat.resolved("open-gate-2k") == .openGate2K)
        #expect(CaptureFormat.resolved("uhd-16x9") == .uhd16x9)
        #expect(CaptureFormat.clamped("open-gate-2k", to: [.uhd16x9]) == .uhd16x9)
        #expect(CaptureFormat.clamped(nil, to: [.uhd16x9, .openGate2K]) == .openGate2K)
    }

    @Test func nativeTenBitSelectionHonorsGeometryRateAndGate() {
        typealias Candidate = CameraCaptureFormatPolicy.Candidate
        let candidates = [
            Candidate(width: 1920, height: 1440, supportsAppleLog2: false, supports24FPS: true,
                      isTenBitBiPlanar420: true, supports60FPS: true, supportsHLG: true),
            Candidate(width: 3840, height: 2160, supportsAppleLog2: false, supports24FPS: true,
                      isTenBitBiPlanar420: true, supportsHLG: true),
            Candidate(width: 1920, height: 1440, supportsAppleLog2: false, supports24FPS: true,
                      isTenBitBiPlanar422: true, supports60FPS: true, supportsHLG: true),
            Candidate(width: 3840, height: 2880, supportsAppleLog2: false, supports24FPS: true,
                      isTenBitBiPlanar420: true, supports60FPS: true, supportsHLG: true),
            Candidate(width: 1920, height: 1440, supportsAppleLog2: false, supports24FPS: true,
                      supports60FPS: true, supportsHLG: true)
        ]
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: candidates, requested: .openGate2K,
            fps: 24, permittedProfile: .hlgBT2020) == [0])
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: candidates, requested: .uhd16x9,
            fps: 24, permittedProfile: .hlgBT2020) == [1])
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: candidates, requested: .uhd16x9,
            fps: 60, permittedProfile: .hlgBT2020).isEmpty)
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: candidates, requested: .openGate2K,
            fps: 60, permittedProfile: .appleLog2).isEmpty)
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: candidates, requested: .openGate2K,
            fps: 60, permittedProfile: nil).isEmpty)
    }

    @Test func missingCapabilityOffersNoGeometryAndNoUnsupportedRate() {
        #expect(CameraCaptureFormatPolicy.availableFormats(in: []).isEmpty)
        let candidate = CameraCaptureFormatPolicy.Candidate(width: 1920, height: 1440,
            supportsAppleLog2: false, supports24FPS: true, isTenBitBiPlanar420: true,
            supports60FPS: true, supports120FPS: true, supportsHLG: true)
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: [candidate], requested: .openGate2K,
            fps: 120, permittedProfile: .hlgBT2020).isEmpty)
        #expect(CameraCaptureFormatPolicy.hlgCandidateIndexes(in: [candidate], requested: .uhd16x9,
            fps: 24, permittedProfile: .hlgBT2020).isEmpty)
    }

    private func evidence(primaries: String? = kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                          transfer: String? = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                          log: String? = nil, bits: String? = "10") -> RenderInputColorProvenance.FormatEvidence {
        .init(logTransferFunction: log, colorPrimaries: primaries, transferFunction: transfer,
              yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String, bitDepth: bits)
    }

    @Test func hlgEvidenceIsExplicitAndImportDefaultRemainsLogTwoOnly() throws {
        try RenderInputColorProvenance.validate([evidence()], expectedProfile: .hlgBT2020)
        #expect(throws: RenderInputColorContractError.self) {
            try RenderInputColorProvenance.validate([evidence()])
        }
        for bad in [evidence(primaries: nil), evidence(primaries: "ITU_R_709_2"),
                    evidence(transfer: nil), evidence(transfer: "SMPTE_ST_2084_PQ"),
                    evidence(log: CameraSampleValidationPolicy.appleLog2Identifier), evidence(bits: "8")] {
            #expect(throws: RenderInputColorContractError.self) {
                try RenderInputColorProvenance.validate([bad], expectedProfile: .hlgBT2020)
            }
        }
        #expect(throws: RenderInputColorContractError.self) {
            try RenderInputColorProvenance.validate([], expectedProfile: .hlgBT2020)
        }
    }

    @Test func samplesRequireNativeX420AndSourceSpecificTags() {
        func rejections(_ pixel: UInt32, transfer: String?, source: CameraSourceProfile) -> [String] {
            CameraSampleValidationPolicy.rejectionReasons(width: 1920, height: 1440, pixelFormat: pixel,
                acceptedPixelFormats: [pixel], logTransfer: nil, matrix: "ITU_R_2020", primaries: "ITU_R_2020",
                transfer: transfer, sourceProfile: source)
        }
        let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        #expect(rejections(0x78343230, transfer: hlg, source: .hlgBT2020).isEmpty)
        #expect(!rejections(0x78343232, transfer: hlg, source: .hlgBT2020).isEmpty)
        #expect(!rejections(0x34323076, transfer: hlg, source: .hlgBT2020).isEmpty)
        #expect(!rejections(0x78343230, transfer: nil, source: .hlgBT2020).isEmpty)
        #expect(!rejections(0x78343230, transfer: hlg, source: .appleLog2).isEmpty)
    }

    @Test func sourcePolicySurvivesQueueLedgerJournalAndLegacyDecode() throws {
        let policy = try #require(RenderCapturePolicy(60, sourceProfile: .hlgBT2020))
        let source = URL(fileURLWithPath: "/capture/test-hlg.mov")
        var ledger = DaylightCapturePolicyLedger()
        ledger.record(sourceURL: source, mode: .daylight60, sourceProfile: .hlgBT2020)
        #expect(ledger.policy(for: source) == policy)
        let job = RenderJob(sourceURL: source, stockId: "test", iso: 400, capturePolicy: policy)
        let restored = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(job))
        #expect(restored.capturePolicy == policy)

        // Remove only the new field from a valid encoded policy, so the test is
        // independent of the grain pairing enum's serialized spelling.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        object.removeValue(forKey: "sourceProfile")
        let old = try JSONDecoder().decode(RenderCapturePolicy.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.sourceProfile == .appleLog2)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        journal.markPending(source, capturePolicy: policy)
        #expect(journal.capturePolicy(for: source) == policy)
        journal.acknowledge(source)
        #expect(journal.capturePolicy(for: source) == nil)
    }

    @Test func originalWriterTagsDescribeHLGNotTheAdaptedLUTDomain() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let tags = CameraSampleValidationPolicy.originalColorProperties(for: .hlgBT2020)
        #expect(tags[AVVideoLogTransferFunctionKey] == nil)
        #expect(tags[AVVideoTransferFunctionKey] == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(tags[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_2020)
        #expect(tags[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_2020)
        let settings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(width: 1920, height: 1440,
            profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String, averageBitRate: 60_000_000, colorProperties: tags)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect(settings[AVVideoWidthKey] as? Int == 1920)
        #expect(settings[AVVideoColorPropertiesKey] as? [String: String] == tags)
    }

    // Runs the production helper, not a Swift port of its equations. Independent
    // fixed references separate transfer, gamut and normalization failures.
    @Test func gpuTransferAndGamutReferenceVectors() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let header = try String(contentsOf: TestRepository.root.appendingPathComponent("Resources/Shaders/hlg-input.h"), encoding: .utf8)
        let source = header + """
        kernel void references(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
            if (i == 0) out[i] = float4(hlg_scene(.25f), hlg_scene(.5f), hlg_scene(.75f), hlg_scene(1.f));
            if (i == 1) out[i] = float4(hlg_scene_to_apple_wide_gamut(float3(1,0,0)), 1);
            if (i == 2) out[i] = float4(hlg_scene_to_apple_wide_gamut(float3(0,1,0)), 1);
            if (i == 3) out[i] = float4(hlg_scene_to_apple_wide_gamut(float3(0,0,1)), 1);
            if (i == 4) out[i] = float4(hlg_to_lut_input(float3(.75f)), 1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "references"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let buffer = try #require(device.makeBuffer(length: 5 * 16, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 5, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let vectors = buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let transfer = SIMD4<Float>(0.0208333333, 0.0833333333, 0.2649625598, 1)
        for i in 0..<4 { #expect(abs(vectors[0][i] - transfer[i]) < 0.00001) }
        let primaries: [SIMD3<Float>] = [SIMD3(0.9750428995, 0.0008445448, 0.0198781607),
            SIMD3(-0.0768564900, 0.8615375131, 0.0492425795), SIMD3(0.1018135904, 0.1376179421, 0.9308792597)]
        for p in 0..<3 {
            for c in 0..<3 { #expect(abs(vectors[p + 1][c] - primaries[p][c]) < 0.00001) }
        }
        // Apple Log encode of scene-linear 1.0, not inverse display OOTF.
        for c in 0..<3 { #expect(abs(vectors[4][c] - 0.6945529831) < 0.00001) }
    }
}
