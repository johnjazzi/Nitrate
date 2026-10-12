import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation

/// Small normalized code-value samples from a fixed 3×3 grid. This intentionally
/// does not retain the source CVPixelBuffer or perform a transfer/gamut decode.
struct CameraYUVProbe: Sendable, Equatable {
    let lumaMeans: [Float]
    let cbMeans: [Float]
    let crMeans: [Float]

    struct Difference: Sendable, Equatable {
        let maximumLumaMeanError: Float
        let maximumChromaMeanError: Float
    }

    enum ProbeError: LocalizedError {
        case unsupportedPixelFormat(UInt32)
        case invalidGeometry
        case lockFailed(CVReturn)
        case missingPlane

        var errorDescription: String? {
            switch self {
            case .unsupportedPixelFormat(let format):
                return "Unsupported ten-bit bi-planar YUV pixel format \(format)."
            case .invalidGeometry:
                return "The YUV pixel buffer has invalid plane geometry or row strides."
            case .lockFailed(let status):
                return "The YUV pixel buffer could not be locked (Core Video status \(status))."
            case .missingPlane:
                return "The YUV pixel buffer is missing a required plane address."
            }
        }
    }

    /// Averages nine fixed 8×8 luma regions and their corresponding chroma.
    /// Video range maps Y using (code−64)/876 and Cb/Cr using (code−512)/896;
    /// full range maps Y using code/1023 and Cb/Cr using (code−512)/1023.
    /// These legal-range normalizations put x420 and x422 code values in a
    /// common scale without applying a transfer function or gamut matrix.
    static func sample(_ buffer: CVPixelBuffer) throws -> CameraYUVProbe {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isVideoRange: Bool
        let verticalChromaSubsampling: Int
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            isVideoRange = true
            verticalChromaSubsampling = 2
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            isVideoRange = false
            verticalChromaSubsampling = 2
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            isVideoRange = true
            verticalChromaSubsampling = 1
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            isVideoRange = false
            verticalChromaSubsampling = 1
        default:
            throw ProbeError.unsupportedPixelFormat(format)
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { throw ProbeError.invalidGeometry }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard width >= 32, height >= 32,
              CVPixelBufferGetWidthOfPlane(buffer, 0) >= width,
              CVPixelBufferGetHeightOfPlane(buffer, 0) >= height,
              chromaWidth >= (width + 1) / 2,
              chromaHeight >= (height + verticalChromaSubsampling - 1) / verticalChromaSubsampling,
              yStride >= width * MemoryLayout<UInt16>.size,
              chromaStride >= chromaWidth * 2 * MemoryLayout<UInt16>.size else {
            throw ProbeError.invalidGeometry
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else { throw ProbeError.lockFailed(lockStatus) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw ProbeError.missingPlane
        }

        var lumaMeans: [Float] = []
        var cbMeans: [Float] = []
        var crMeans: [Float] = []
        lumaMeans.reserveCapacity(9)
        cbMeans.reserveCapacity(9)
        crMeans.reserveCapacity(9)

        for gridY in 1...3 {
            for gridX in 1...3 {
                let centerX = width * gridX / 4
                let centerY = height * gridY / 4
                let minX = centerX - 4
                let minY = centerY - 4
                var lumaTotal: Float = 0
                var cbTotal: Float = 0
                var crTotal: Float = 0
                var count = 0

                for y in minY..<(minY + 8) {
                    let yRow = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt16.self)
                    let chromaY = y / verticalChromaSubsampling
                    let chromaRow = chromaBase.advanced(by: chromaY * chromaStride).assumingMemoryBound(to: UInt16.self)
                    for x in minX..<(minX + 8) {
                        let yCode = Int(UInt16(littleEndian: yRow[x]) >> 6)
                        let chromaX = x / 2
                        let cbCode = Int(UInt16(littleEndian: chromaRow[chromaX * 2]) >> 6)
                        let crCode = Int(UInt16(littleEndian: chromaRow[chromaX * 2 + 1]) >> 6)
                        lumaTotal += isVideoRange ? Float(yCode - 64) / 876 : Float(yCode) / 1023
                        cbTotal += isVideoRange ? Float(cbCode - 512) / 896 : Float(cbCode - 512) / 1023
                        crTotal += isVideoRange ? Float(crCode - 512) / 896 : Float(crCode - 512) / 1023
                        count += 1
                    }
                }
                let divisor = Float(count)
                lumaMeans.append(lumaTotal / divisor)
                cbMeans.append(cbTotal / divisor)
                crMeans.append(crTotal / divisor)
            }
        }
        return CameraYUVProbe(lumaMeans: lumaMeans, cbMeans: cbMeans, crMeans: crMeans)
    }

    func maximumMeanError(comparedTo other: CameraYUVProbe) -> Difference {
        guard lumaMeans.count == 9, cbMeans.count == 9, crMeans.count == 9,
              other.lumaMeans.count == 9, other.cbMeans.count == 9, other.crMeans.count == 9 else {
            return Difference(maximumLumaMeanError: .infinity, maximumChromaMeanError: .infinity)
        }
        let lumaError = zip(lumaMeans, other.lumaMeans).map { abs($0 - $1) }.max() ?? .infinity
        let cbError = zip(cbMeans, other.cbMeans).map { abs($0 - $1) }.max() ?? .infinity
        let crError = zip(crMeans, other.crMeans).map { abs($0 - $1) }.max() ?? .infinity
        return Difference(maximumLumaMeanError: lumaError, maximumChromaMeanError: max(cbError, crError))
    }
}

enum CameraHEVCProfilePolicy {
    /// Parses the fixed HEVCDecoderConfigurationRecord header. Main10 is
    /// profile_idc 2; this policy specifically accepts 4:2:0 and ten-bit Y/C.
    static func isMain10_420(_ data: Data) -> Bool {
        guard data.count >= 23 else { return false }
        let bytes = [UInt8](data.prefix(23))
        let profileIDC = bytes[1] & 0x1f
        let chromaFormatIDC = bytes[16] & 0x03
        let lumaDepthMinus8 = bytes[17] & 0x07
        let chromaDepthMinus8 = bytes[18] & 0x07
        return profileIDC == 2 && chromaFormatIDC == 1
            && lumaDepthMinus8 == 2 && chromaDepthMinus8 == 2
    }
}

enum CameraCapturePreservationProbe {
    private static let lumaTolerance: Float = 0.03
    private static let chromaTolerance: Float = 0.03
    private static let synchronizationTolerance: Double = 0.12

    static func inspect(url: URL, source: CameraYUVProbe, requiresAudio: Bool) async throws -> String {
        try await Task.detached(priority: .utility) {
            try await inspectOffQueue(url: url, source: source, requiresAudio: requiresAudio)
        }.value
    }

    private static func inspectOffQueue(url: URL, source: CameraYUVProbe, requiresAudio: Bool) async throws -> String {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw PreservationError.missingVideo
        }
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        guard let videoFormat = videoFormats.first,
              CMFormatDescriptionGetMediaSubType(videoFormat) == 0x68766331,
              CMVideoFormatDescriptionGetDimensions(videoFormat).width == 3840,
              CMVideoFormatDescriptionGetDimensions(videoFormat).height == 2160,
              let hvcC = hevcConfiguration(from: videoFormat),
              CameraHEVCProfilePolicy.isMain10_420(hvcC) else {
            throw PreservationError.invalidVideoFormat
        }

        let videoRange = try await videoTrack.load(.timeRange)
        try validateTimeRange(videoRange)
        let reader = try AVAssetReader(asset: asset)
        let decodedOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        )
        guard reader.canAdd(decodedOutput) else { throw PreservationError.cannotDecodeVideo }
        reader.add(decodedOutput)
        guard reader.startReading() else { throw reader.error ?? PreservationError.cannotDecodeVideo }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let firstVideoSample = decodedOutput.copyNextSampleBuffer(),
              let decodedBuffer = CMSampleBufferGetImageBuffer(firstVideoSample) else {
            throw reader.error ?? PreservationError.cannotDecodeVideo
        }
        let decoded = try CameraYUVProbe.sample(decodedBuffer)
        let difference = source.maximumMeanError(comparedTo: decoded)
        guard difference.maximumLumaMeanError <= lumaTolerance,
              difference.maximumChromaMeanError <= chromaTolerance else {
            throw PreservationError.pixelValuesExceededTolerance(
                luma: difference.maximumLumaMeanError,
                chroma: difference.maximumChromaMeanError
            )
        }
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(firstVideoSample)
        guard videoPTS.isValid, videoPTS.isNumeric else { throw PreservationError.invalidTimestamps }

        let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        if requiresAudio, audioTrack == nil { throw PreservationError.missingAACAudio }
        var audioSkew = 0.0
        var endDifference = 0.0
        if let audioTrack {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            guard let audioFormat = audioFormats.first,
                  CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC else {
                throw PreservationError.missingAACAudio
            }
            let audioRange = try await audioTrack.load(.timeRange)
            try validateTimeRange(audioRange)
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard audioReader.canAdd(audioOutput) else { throw PreservationError.invalidAudioTiming }
            audioReader.add(audioOutput)
            guard audioReader.startReading() else { throw audioReader.error ?? PreservationError.invalidAudioTiming }
            defer { if audioReader.status == .reading { audioReader.cancelReading() } }
            guard let firstAudioSample = audioOutput.copyNextSampleBuffer() else {
                throw audioReader.error ?? PreservationError.invalidAudioTiming
            }
            let audioPTS = CMSampleBufferGetPresentationTimeStamp(firstAudioSample)
            guard audioPTS.isValid, audioPTS.isNumeric else { throw PreservationError.invalidTimestamps }
            audioSkew = CMTimeGetSeconds(CMTimeSubtract(audioPTS, videoPTS))
            let videoEnd = CMTimeGetSeconds(CMTimeAdd(videoRange.start, videoRange.duration))
            let audioEnd = CMTimeGetSeconds(CMTimeAdd(audioRange.start, audioRange.duration))
            endDifference = abs(videoEnd - audioEnd)
            guard audioSkew.isFinite, endDifference.isFinite,
                  abs(audioSkew) <= synchronizationTolerance,
                  endDifference <= synchronizationTolerance else {
                throw PreservationError.audioOutOfSync(skew: audioSkew, endDifference: endDifference)
            }
        }

        let audioEvidence = audioTrack == nil
            ? "audio=absent"
            : String(format: "audio=present, skew=%.3fs, end-delta=%.3fs", audioSkew, endDifference)
        return String(
            format: "HEVC Main10 4:2:0 3840x2160 decoded YUV passed (max luma error %.4f, chroma %.4f; limits %.2f/%.2f); %@",
            difference.maximumLumaMeanError,
            difference.maximumChromaMeanError,
            lumaTolerance,
            chromaTolerance,
            audioEvidence
        )
    }

    private static func hevcConfiguration(from format: CMFormatDescription) -> Data? {
        guard let extensions = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return nil }
        return extensions["hvcC"] as? Data
    }

    private static func validateTimeRange(_ range: CMTimeRange) throws {
        let start = CMTimeGetSeconds(range.start)
        let duration = CMTimeGetSeconds(range.duration)
        guard range.start.isValid, range.start.isNumeric,
              range.duration.isValid, range.duration.isNumeric,
              start.isFinite, duration.isFinite, duration > 0 else {
            throw PreservationError.invalidTimestamps
        }
    }

    private enum PreservationError: LocalizedError {
        case missingVideo
        case invalidVideoFormat
        case cannotDecodeVideo
        case pixelValuesExceededTolerance(luma: Float, chroma: Float)
        case invalidTimestamps
        case missingAACAudio
        case invalidAudioTiming
        case audioOutOfSync(skew: Double, endDifference: Double)

        var errorDescription: String? {
            switch self {
            case .missingVideo: return "Preservation check failed: movie has no video track."
            case .invalidVideoFormat: return "Preservation check failed: video is not hvc1 HEVC Main10 4:2:0 at 3840×2160."
            case .cannotDecodeVideo: return "Preservation check failed: the first ten-bit 4:2:0 video frame could not be decoded."
            case .pixelValuesExceededTolerance(let luma, let chroma):
                return String(format: "Preservation check failed: YUV mean errors %.4f/%.4f exceed limits %.2f/%.2f.", luma, chroma, lumaTolerance, chromaTolerance)
            case .invalidTimestamps: return "Preservation check failed: the movie contains invalid capture-clock timestamps or durations."
            case .missingAACAudio: return "Preservation check failed: required AAC audio is missing or uses another codec."
            case .invalidAudioTiming: return "Preservation check failed: the audio track could not be inspected."
            case .audioOutOfSync(let skew, let endDifference):
                return String(format: "Preservation check failed: A/V first-sample skew %.3fs or end-duration difference %.3fs exceeds %.2fs.", skew, endDifference, synchronizationTolerance)
            }
        }
    }
}
