import CoreVideo
import Foundation
import Testing

@Suite(.serialized)
struct CameraCapturePreservationProbeTests {
    @Test func samplesDistinctPatchesFromTenBit420WithStableSelfComparison() throws {
        let buffer = try makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        fill(buffer, luma: { x, y in 360 + ((x / 16 + y / 16) % 3) * 70 },
             cb: { x, y in 460 + ((x / 8 + y / 8) % 3) * 20 },
             cr: { x, y in 560 - ((x / 8 + y / 8) % 3) * 20 })

        let sampled = try CameraYUVProbe.sample(buffer)
        #expect(sampled.lumaMeans.count == 9)
        #expect(Set(sampled.lumaMeans).count > 1)
        #expect(Set(sampled.cbMeans).count > 1)
        let error = sampled.maximumMeanError(comparedTo: sampled)
        #expect(error.maximumLumaMeanError == 0)
        #expect(error.maximumChromaMeanError == 0)
    }

    @Test func orientationMetadataLeavesTenBitSensorPlanesAndLogColorAttachmentsUntouched() throws {
        guard #available(macOS 14.2, iOS 17.2, *) else { return }
        let buffer = try makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        fill(buffer, luma: { x, y in 200 + (x * 3 + y * 5) % 600 },
             cb: { x, y in 300 + (x + y) % 200 }, cr: { x, y in 600 - (x + y) % 200 })
        CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey,
            CameraSampleValidationPolicy.appleLog2Identifier as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        let original = try CameraYUVProbe.sample(buffer)
        let before = try planeBytes(buffer)
        let holds: [CameraSampleValidationPolicy.DeliveryOrientation] =
            [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
        for coded in [CameraSampleValidationPolicy.CodedDimensions.landscape4K, .portrait4K] {
            for hold in holds {
                let turns = CameraSampleValidationPolicy.deliveryQuarterTurns(for: hold, coded: coded)
                CameraFrozenFrameOrientationPolicy.setQuarterTurns(turns, on: buffer)
                #expect(try planeBytes(buffer) == before)
                let error = original.maximumMeanError(comparedTo: try CameraYUVProbe.sample(buffer))
                #expect(error.maximumLumaMeanError == 0 && error.maximumChromaMeanError == 0)
                #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                #expect(CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) as? String ==
                    CameraSampleValidationPolicy.appleLog2Identifier)
                #expect(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == "ITU_R_2020")
            }
        }
    }

    private func planeBytes(_ buffer: CVPixelBuffer) throws -> [Data] {
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return try (0..<CVPixelBufferGetPlaneCount(buffer)).map { plane in
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            return Data(bytes: base, count: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) *
                CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }

    @Test func normalizes420And422VideoAndFullRangeWithoutRgbConversion() throws {
        let formats: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ]
        var probes: [CameraYUVProbe] = []
        for format in formats {
            let buffer = try makeBuffer(format: format)
            let fullRange = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            let y = fullRange ? 512 : 502
            let cb = fullRange ? 512 : 512
            let cr = fullRange ? 512 : 512
            fill(buffer, luma: { _, _ in y }, cb: { _, _ in cb }, cr: { _, _ in cr })
            probes.append(try CameraYUVProbe.sample(buffer))
        }
        for probe in probes.dropFirst() {
            let error = probes[0].maximumMeanError(comparedTo: probe)
            #expect(error.maximumLumaMeanError < 0.002)
            #expect(error.maximumChromaMeanError < 0.002)
        }
    }

    @Test func reportsControlledCodeValueDifferences() throws {
        let original = try makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        let changed = try makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        fill(original, luma: { _, _ in 500 }, cb: { _, _ in 512 }, cr: { _, _ in 512 })
        fill(changed, luma: { _, _ in 518 }, cb: { _, _ in 532 }, cr: { _, _ in 492 })

        let error = try CameraYUVProbe.sample(original).maximumMeanError(comparedTo: CameraYUVProbe.sample(changed))
        #expect(error.maximumLumaMeanError > 0.019 && error.maximumLumaMeanError < 0.022)
        #expect(error.maximumChromaMeanError > 0.021 && error.maximumChromaMeanError < 0.024)
    }

    @Test func rejectsNonTenBitYUVBuffers() throws {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &optionalBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        #expect(throws: CameraYUVProbe.ProbeError.self) { try CameraYUVProbe.sample(buffer) }
    }

    @Test func acceptsOnlyCompleteMain10TenBit420ConfigurationRecords() {
        var valid = makeHVCC()
        #expect(CameraHEVCProfilePolicy.isMain10_420(valid))
        valid[16] = (valid[16] & 0xfc) | 2
        #expect(!CameraHEVCProfilePolicy.isMain10_420(valid))

        valid = makeHVCC()
        valid[1] = (valid[1] & 0xe0) | 1
        #expect(!CameraHEVCProfilePolicy.isMain10_420(valid))

        valid = makeHVCC()
        valid[17] = (valid[17] & 0xf8) | 1
        #expect(!CameraHEVCProfilePolicy.isMain10_420(valid))

        valid = makeHVCC()
        valid[18] = (valid[18] & 0xf8) | 1
        #expect(!CameraHEVCProfilePolicy.isMain10_420(valid))
        #expect(!CameraHEVCProfilePolicy.isMain10_420(Data(valid.prefix(22))))
    }

    private func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, format, attributes, &optionalBuffer)
        #expect(status == kCVReturnSuccess)
        return try #require(optionalBuffer)
    }

    private func fill(
        _ buffer: CVPixelBuffer,
        luma: (Int, Int) -> Int,
        cb: (Int, Int) -> Int,
        cr: (Int, Int) -> Int
    ) {
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            Issue.record("The Core Video fixture did not provide two planes")
            return
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let verticalSubsampling = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 2 : 1
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width { row[x] = UInt16(luma(x, y) << 6) }
        }
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        for y in 0..<chromaHeight {
            let row = chromaBase.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<chromaWidth {
                let sourceY = y * verticalSubsampling
                row[x * 2] = UInt16(cb(x * 2, sourceY) << 6)
                row[x * 2 + 1] = UInt16(cr(x * 2, sourceY) << 6)
            }
        }
    }

    private func makeHVCC() -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = 2
        bytes[16] = 1
        bytes[17] = 2
        bytes[18] = 2
        return Data(bytes)
    }
}
