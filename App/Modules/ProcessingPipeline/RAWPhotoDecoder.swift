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
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let usablePixelLimit = PhotoCapturePolicy.maximumPixelCount

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

    func decode(url: URL, temperature: Float, tint: Float = 0) throws -> Decoded {
        guard temperature.isFinite, (2000...50000).contains(temperature), tint.isFinite, (-150...150).contains(tint) else {
            throw DecodeError.invalidWhiteBalance
        }
        guard let raw = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupported("CIRAWFilter could not open URL") }
        let version = CIRAWDecoderVersion(rawValue: "8.dng")
        guard raw.supportedDecoderVersions.contains(version) else { throw DecodeError.unsupported("decoder 8.dng not supported") }
        raw.decoderVersion = version
        raw.scaleFactor = 1
        raw.exposure = 0
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
            "decoderVersion": "8.dng", "scaleFactor": "1", "exposure": "0",
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
        disable("colorNoiseReduction", supported: raw.isColorNoiseReductionSupported) { raw.colorNoiseReductionAmount = 0 }
        disable("moireReduction", supported: raw.isMoireReductionSupported) { raw.moireReductionAmount = 0 }
        disable("despeckle", supported: raw.isDespeckleSupported) { raw.despeckleAmount = 0 }
        disable("localToneMap", supported: raw.isLocalToneMapSupported) { raw.localToneMapAmount = 0 }
        if raw.isHighlightRecoverySupported {
            raw.isHighlightRecoveryEnabled = false
            settings["highlightRecovery"] = "supported=true,enabled=false"
        } else { settings["highlightRecovery"] = "supported=false,unchanged" }

        guard let image = raw.outputImage else { throw DecodeError.emptyOutput }
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
        return Decoded(texture: texture, linearImage: normalized, nativeSize: raw.nativeSize, orientedExtent: CGRect(origin: .zero, size: CGSize(width: extent.width, height: extent.height)), settings: settings)
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
