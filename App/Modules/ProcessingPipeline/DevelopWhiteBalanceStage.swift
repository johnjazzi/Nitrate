import Foundation
import Metal
import simd

enum DevelopWhiteBalanceStageError: Error, Equatable {
    /// The board's `plate_prepare` kernel was not in the bundle's library.
    case missingKernel
    /// The GPU could not complete the correction.
    case dispatchFailed
}

/// The one implementation of the video development white balance.
///
/// It runs the board's existing `plate_prepare` kernel
/// (`Resources/Shaders/camera-preview.metal`), which is already this app's
/// decode → white balance → re-encode step: it decodes Apple Log 2 codes to
/// linear light, multiplies by a Bradford chromatic adaptation in **linear
/// Apple Wide Gamut**, and re-encodes. That is exactly the domain the stock
/// LUT and the halation stage are authored for (the same reason the camera
/// locks white balance in hardware before the renderer sees a frame), so the
/// correction is applied in front of halation, exposure and the LUT — not as a
/// display tint and not to sRGB-encoded Log values.
///
/// The frame preview (`DevelopColorPreviewResources`) and the delivered render
/// (`PipelineRenderer`) both dispatch through this type, so the two cannot
/// drift into different colour maths.
final class DevelopWhiteBalanceStage: @unchecked Sendable {
    /// Full-scale reciprocal-temperature shift. This is a relative correction
    /// scale, not a calibrated measurement of the source illuminant.
    static let fullScaleMiredShift: Float = 34

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary) throws {
        guard let function = library.makeFunction(name: "plate_prepare") else {
            throw DevelopWhiteBalanceStageError.missingKernel
        }
        self.device = device
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// The chromatic adaptation a warmth asks for, in linear Apple Wide Gamut.
    ///
    /// A relative control is a mired shift around `referenceKelvin`: a warmer
    /// picture is the same light balanced as if the scene were cooler, which is
    /// `adaptation(sceneKelvin: lower, lockedKelvin: reference)`. Zero is
    /// exactly identity, so a neutral job cannot move a single code.
    static func adaptation(referenceKelvin: Float, warmth: Float) -> simd_float3x3 {
        let resolved = min(max(warmth.isFinite ? warmth : 0,
                               DevelopWhiteBalance.videoWarmthRange.lowerBound),
                           DevelopWhiteBalance.videoWarmthRange.upperBound)
        guard resolved != 0 else { return matrix_identity_float3x3 }
        let reference = referenceKelvin.isFinite && referenceKelvin > 0
            ? referenceKelvin : DevelopWhiteBalance.referenceKelvin
        let referenceMired = 1_000_000 / reference
        let shiftedMired = max(1, referenceMired + resolved * fullScaleMiredShift)
        return PlateWhiteBalance.adaptation(sceneKelvin: 1_000_000 / shiftedMired,
                                            lockedKelvin: reference)
    }

    /// Apply the relative warmth to a texture of Apple Wide Gamut / Apple Log 2
    /// code values.
    ///
    /// Returns `input` ITSELF when the warmth resolves to zero: the neutral path
    /// allocates nothing, dispatches nothing and hands the original texture on,
    /// so a default job's bytes are untouched. The returned texture is complete
    /// when this returns (the command buffer is waited on), so a later pass can
    /// read it; `input` must stay alive until then, as it must for every other
    /// stage on the same command queue.
    func corrected(_ input: MTLTexture, referenceKelvin: Float, warmth: Float,
                   commandQueue: MTLCommandQueue) throws -> MTLTexture {
        let resolved = min(max(warmth.isFinite ? warmth : 0,
                               DevelopWhiteBalance.videoWarmthRange.lowerBound),
                           DevelopWhiteBalance.videoWarmthRange.upperBound)
        guard resolved != 0, input.width > 0, input.height > 0 else { return input }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: input.width, height: input.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        // The caller reads this corrected texture back on the CPU (the
        // preview's exposure readback), so it must be shared, matching the
        // preview resources it stands in for.
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw DevelopWhiteBalanceStageError.dispatchFailed
        }
        // `PlatePrepareUniformsCPU` mirrors the shader struct; its stride and
        // the field's offset are pinned by PlatePreviewEffectsTests, so this
        // upload cannot silently disagree with the kernel.
        var uniforms = PlatePrepareUniformsCPU(
            whiteBalance: Self.adaptation(referenceKelvin: referenceKelvin, warmth: resolved))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PlatePrepareUniformsCPU>.stride, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (input.width + 15) / 16, height: (input.height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw DevelopWhiteBalanceStageError.dispatchFailed
        }
        return output
    }
}
