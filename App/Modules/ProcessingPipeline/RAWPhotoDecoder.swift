import CoreImage
import CoreGraphics
import Metal
import Foundation

/// Synchronous RAW development. Confine instances and calls to one serial executor.
final class RAWPhotoDecoder {
    struct Decoded {
        let texture: MTLTexture
        let linearImage: CIImage
        let nativeSize: CGSize
        let orientedExtent: CGRect
        let settings: [String: String]
        /// Stops of lift this decode kept from the capture (`BaselineExposure`).
        /// The film stages need it: halation measures excess above diffuse
        /// white, and a lifted frame's diffuse white no longer sits at 1.0.
        let baselineExposure: Float
        /// The file's own sensor numbers, when it is a DNG.
        let metadata: DNGMetadata?
        /// Highlight ceiling the file actually carries: the 99.99th percentile
        /// of its configured decode, in the same lifted units the film stages
        /// see. Halation is anchored to this instead of a constant, because a
        /// single-exposure raw clips at its own white (see
        /// `SpatialEffectsStage.halationReferenceSuperwhite`).
        let halationHeadroom: Float

        /// Additional lift actually applied by CIRAWFilter, separate from its baseline.
        let exposureEV: Float

        init(texture: MTLTexture, linearImage: CIImage, nativeSize: CGSize,
             orientedExtent: CGRect, settings: [String: String], baselineExposure: Float,
             metadata: DNGMetadata?, halationHeadroom: Float,
             exposureEV: Float = RAWPhotoDecoder.baseExposureEV) {
            self.texture = texture
            self.linearImage = linearImage
            self.nativeSize = nativeSize
            self.orientedExtent = orientedExtent
            self.settings = settings
            self.baselineExposure = baselineExposure
            self.metadata = metadata
            self.halationHeadroom = halationHeadroom
            self.exposureEV = exposureEV
        }

        /// Total stops this frame was lifted by before the film stages: the
        /// capture's baseline plus the still base exposure.
        var sceneLiftStops: Float {
            RAWPhotoDecoder.sceneLiftStops(baselineExposure: baselineExposure, exposureEV: exposureEV)
        }
    }

    /// Legacy ambient still exposure before the film stages.
    ///
    /// The RAW pipeline's neutral rendering sits low: a develop came out about a
    /// stop under what the same capture looks like in Photos, consistently, on
    /// both ProRAW and maker raws. This is the single number that fixes the base
    /// rather than leaving every photo to be corrected by hand with push/pull.
    ///
    /// It is a LIFT, so it also counts toward the halation scene lift (see
    /// `sceneLiftStops`) — a frame lifted here must not be measured against
    /// un-lifted knees, which is the bug that made raw blooms orange.
    static let baseExposureEV: Float = 1

    static func exposureEV(for flash: FlashRecord?) -> Float {
        guard let flash, flash.mode == .native, flash.resolved == true, !flash.wasRefused else {
            return baseExposureEV
        }
        // Native flash already meters the shot; do not add the ambient still lift.
        return 0
    }

    /// Total stops the film stages see this frame lifted by: the capture's own
    /// `BaselineExposure` plus the still base exposure above.
    static func sceneLiftStops(baselineExposure: Float, exposureEV: Float = baseExposureEV) -> Float {
        baselineExposure + exposureEV
    }

    /// The decoder version to pin for a file: the DNG-tagged one when the file
    /// offers it, otherwise the newest version it does support.
    ///
    /// Pure and separate from `CIRAWFilter` so the rule is testable without a
    /// camera's file: `["8.dng", "9.0"]` pins 8.dng, `["6.0", "8.0", "9.0"]`
    /// pins 9.0 (a non-DNG raw), and an empty list is refused rather than
    /// silently left on a default the rest of the pipeline did not measure.
    static func preferredDecoderVersion(from supported: [CIRAWDecoderVersion]) -> CIRAWDecoderVersion? {
        let dng = CIRAWDecoderVersion(rawValue: "8.dng")
        if supported.contains(dng) { return dng }
        // Newest wins: versions read as "6.0", "8.0", "9.0", so a natural-order
        // comparison keeps 9.0 above 10.0 and above 8.0.
        return supported.max {
            $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace: CGColorSpace
    /// Largest imported raw this decoder will open.
    ///
    /// `PhotoCapturePolicy.maximumPixelCount` (12.19 MP) sizes the DNGs THIS app
    /// writes; it is not an import limit, and applying it refused every DSLR raw
    /// above 12 MP (a 16 MP Sony NEX-6 ARW, a 33 MP A7 IV, a 45 MP NEF). A raw
    /// the operator picked is theirs to develop, at the resolution it was shot.
    ///
    /// This ceiling exists only to refuse a file large enough to exhaust memory
    /// before anything can fail gracefully. Raise it if it gets in the way; it is
    /// one number on purpose.
    static let maximumImportPixels = 80_000_000

    private var usablePixelLimit: Int { Self.maximumImportPixels }

    init(device: MTLDevice, queue: MTLCommandQueue) throws {
        self.device = device
        self.queue = queue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw DecodeError.resources("extendedLinearSRGB unavailable")
        }
        self.colorSpace = colorSpace
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
    }

    /// Preview-only size seam. Nil retains the shipping full-resolution decode.
    func decode(url: URL, temperature: Float, tint: Float = 0,
                maximumDimension: Int? = nil) throws -> Decoded {
        guard temperature.isFinite, (2000...50000).contains(temperature), tint.isFinite, (-150...150).contains(tint) else {
            throw DecodeError.invalidWhiteBalance
        }
        guard let raw = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupported("CIRAWFilter could not open URL") }
        // Pick the newest version THIS file supports instead of demanding
        // "8.dng". That string is a DNG-tagged decoder version, and a Nikon NEF,
        // a Sony ARW or a Canon CR2 does not offer it at all: pinning it refused
        // every non-DNG raw at the first line of the decode.
        let version = Self.preferredDecoderVersion(from: raw.supportedDecoderVersions)
        guard let version else { throw DecodeError.unsupported("no supported decoder version") }
        raw.decoderVersion = version
        raw.scaleFactor = 1
        if let maximumDimension {
            guard maximumDimension > 0 else { throw DecodeError.emptyOutput }
            let longest = max(raw.nativeSize.width, raw.nativeSize.height)
            guard longest.isFinite, longest > 0 else { throw DecodeError.emptyOutput }
            raw.scaleFactor = Float(min(1, CGFloat(maximumDimension) / longest))
        }
        let capture = PhotoDeliveryMetadata.capture(fromDNG: url)
        let exposureEV = Self.exposureEV(for: capture.flash)
        raw.exposure = exposureEV
        // `baselineExposure` is deliberately NOT zeroed: the DNG's BaselineExposure
        // is the capture's exposure compensation (measured +0.98 EV and +2.49 EV on
        // real captures). Forcing it to 0 developed every photo ~2–5x darker than
        // Apple's own RAW pipeline and than the matching Log 2 video take.
        let dngBaselineExposure = raw.baselineExposure
        raw.shadowBias = 0
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.isGamutMappingEnabled = false
        raw.extendedDynamicRangeAmount = 1
        raw.neutralTemperature = temperature
        raw.neutralTint = tint

        var settings: [String: String] = [
            "decoderVersion": raw.decoderVersion.rawValue, "scaleFactor": maximumDimension == nil ? "1" : String(raw.scaleFactor),
            "exposure": String(format: "%.2f (still base)", exposureEV),
            "baselineExposure": String(format: "%.3f (DNG-provided)", dngBaselineExposure), "shadowBias": "0",
            "boostAmount": "0", "boostShadowAmount": "0", "gamutMappingEnabled": "false",
            "extendedDynamicRangeAmount": "1", "neutralTemperature": String(raw.neutralTemperature),
            "neutralTint": String(raw.neutralTint), "whiteBalance": "applied once by CIRAWFilter",
            "opticalCorrections": "SDK defaults retained; support/enabled recorded"
        ]
        settings["lensCorrection"] = "supported=\(raw.isLensCorrectionSupported),enabled=\(raw.isLensCorrectionEnabled)"
        func disable(_ name: String, supported: Bool, set: () -> Void) {
            settings[name] = supported ? "supported=true,amount=0" : "supported=false,unchanged"
            if supported { set() }
        }
        disable("sharpness", supported: raw.isSharpnessSupported) { raw.sharpnessAmount = 0 }
        disable("detail", supported: raw.isDetailSupported) { raw.detailAmount = 0 }
        disable("contrast", supported: raw.isContrastSupported) { raw.contrastAmount = 0 }
        disable("luminanceNoiseReduction", supported: raw.isLuminanceNoiseReductionSupported) { raw.luminanceNoiseReductionAmount = 0 }
        // Colour noise reduction is the one RAW control the still path does ask for,
        // and only as far as the capture's own ISO justifies: an untouched Bayer
        // frame carries the sensor's multicoloured chroma speckle, which is exactly
        // what an operator reads as "wrong grain". See PhotoNoiseReductionPolicy.
        let captureISO = capture.iso
        let colorNoiseReduction = PhotoNoiseReductionPolicy.colorAmount(iso: captureISO)
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = colorNoiseReduction }
        settings["colorNoiseReduction"] = raw.isColorNoiseReductionSupported
            ? "supported=true," + PhotoNoiseReductionPolicy.report(iso: captureISO)
            : "supported=false,unchanged"
        disable("moireReduction", supported: raw.isMoireReductionSupported) { raw.moireReductionAmount = 0 }
        disable("despeckle", supported: raw.isDespeckleSupported) { raw.despeckleAmount = 0 }
        disable("localToneMap", supported: raw.isLocalToneMapSupported) { raw.localToneMapAmount = 0 }
        if raw.isHighlightRecoverySupported {
            raw.isHighlightRecoveryEnabled = false
            settings["highlightRecovery"] = "supported=true,enabled=false"
        } else { settings["highlightRecovery"] = "supported=false,unchanged" }

        guard let outputImage = raw.outputImage else { throw DecodeError.emptyOutput }
        // Some RAW decoders round their scale-factor raster. Enforce the preview
        // bound before materializing a texture; nil leaves delivery unchanged.
        let image: CIImage
        if let maximumDimension, max(outputImage.extent.width, outputImage.extent.height) > CGFloat(maximumDimension) {
            let scale = CGFloat(maximumDimension) / max(outputImage.extent.width, outputImage.extent.height)
            image = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            image = outputImage
        }
        let extent = image.extent
        guard extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { throw DecodeError.emptyOutput }
        let pixels = extent.width * extent.height
        guard pixels.isFinite, pixels <= CGFloat(usablePixelLimit) else { throw DecodeError.pixelBudget(pixels) }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let texture = try renderLinearImage(normalized)
        settings["renderColorSpace"] = "extendedLinearSRGB"
        settings["pixelFormat"] = "rgba16Float"
        settings["alpha"] = "opaque RAW"
        settings["nativeWidth"] = String(Double(raw.nativeSize.width))
        settings["nativeHeight"] = String(Double(raw.nativeSize.height))
        return Decoded(texture: texture, linearImage: normalized, nativeSize: raw.nativeSize,
                       orientedExtent: CGRect(origin: .zero, size: CGSize(width: extent.width, height: extent.height)),
                       settings: settings, baselineExposure: dngBaselineExposure,
                       metadata: DNGMetadata.read(url),
                       halationHeadroom: measureHeadroom(of: normalized), exposureEV: exposureEV)
    }

    /// The file's highlight ceiling, in the lifted units the film stages see.
    ///
    /// The 99.99th percentile of the PEAK channel over a 256 px sample: the
    /// channel a specular saturates first, and a percentile so one hot pixel
    /// cannot set a whole frame's halation. Sampled small on purpose - this runs
    /// once per photo, and 65 536 values are plenty to place a 0.01% point.
    private func measureHeadroom(of image: CIImage) -> Float {
        let sample = 256
        let scale = CGFloat(sample) / max(1, image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [Float](repeating: 0, count: sample * sample * 4)
        context.render(small, toBitmap: &pixels, rowBytes: sample * 16,
                       bounds: CGRect(x: 0, y: 0, width: sample, height: sample),
                       format: .RGBAf, colorSpace: colorSpace)
        var values: [Float] = []
        values.reserveCapacity(sample * sample)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let peak = max(pixels[index], max(pixels[index + 1], pixels[index + 2]))
            if peak.isFinite { values.append(peak) }
        }
        guard !values.isEmpty else { return 1 }
        values.sort()
        return values[min(values.count - 1, Int(Double(values.count - 1) * 0.9999))]
    }

    /// Shared render destination for RAW and numerical handoff regressions.
    func renderLinearImage(_ normalized: CIImage) throws -> MTLTexture {
        let width = Int(ceil(normalized.extent.width)), height = Int(ceil(normalized.extent.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw DecodeError.resources("Metal texture or command buffer unavailable")
        }
        context.render(normalized, to: texture, commandBuffer: commandBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw DecodeError.metal(error.localizedDescription) }
        return texture
    }

    enum DecodeError: Error, LocalizedError {
        case unsupported(String), resources(String), invalidWhiteBalance, emptyOutput, pixelBudget(CGFloat), metal(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let s), .resources(let s), .metal(let s): return s
            case .invalidWhiteBalance: return "Temperature/tint outside supported finite ranges"
            case .emptyOutput: return "RAW decoder returned an empty or non-finite extent"
            case .pixelBudget(let p): return "RAW output exceeds 12 MP-class usable-pixel limit (\(p))"
            }
        }
    }
}
