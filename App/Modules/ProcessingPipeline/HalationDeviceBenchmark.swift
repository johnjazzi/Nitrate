#if DEBUG
import Foundation
import Metal
import MetalPerformanceShaders

/// Development-only measurement of the spatial halation/glow stage.
///
/// The Mac numbers were produced by a standalone harness that replicated
/// `spatial.metal` and `SpatialEffectsStage`'s MPS blur work. This runs the
/// SAME terms on the actual device GPU so the two can be compared directly,
/// and additionally times the real `SpatialEffectsStage.apply` path as ground
/// truth against the replica.
///
/// Runs only when the app is launched with `-halation-benchmark`, prints to
/// stdout, and is compiled out of Release builds entirely.
enum HalationDeviceBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-halation-benchmark")
    }

    /// Mirrors spatial.metal closely enough to measure the same GPU work:
    /// the 2x2 box-average mask kernel and the additive tinted composite.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler spatial_linear_sampler(coord::normalized, filter::linear, address::clamp_to_edge);

    kernel void spatial_mask(
        texture2d<float, access::read>  source [[texture(0)]],
        texture2d<float, access::write> mask   [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) { return; }
        float3 sum = float3(0.0f);
        for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
                uint2 src = gid * 2 + uint2(dx, dy);
                if (src.x < source.get_width() && src.y < source.get_height()) { sum += source.read(src).rgb; }
            }
        }
        float3 color = sum * 0.25f;
        float highlight = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
        mask.write(float4(highlight, highlight, highlight, 1.0f), gid);
    }

    kernel void spatial_composite(
        texture2d<float, access::read>  graded   [[texture(0)]],
        texture2d<float, access::sample> mask    [[texture(1)]],
        texture2d<float, access::write> output   [[texture(2)]],
        constant float& strength                 [[buffer(0)]],
        constant float3& tint                    [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float4 base = graded.read(gid);
        float2 size = float2(graded.get_width(), graded.get_height());
        float2 uv = (float2(gid) + 0.5f) / size;
        float spread = mask.sample(spatial_linear_sampler, uv).r;
        float3 result = base.rgb + tint * spread * strength;
        output.write(float4(result, base.a), gid);
    }
    """

    private static let sigmaPerRadius: Float = 2.7615277481
    private static let halationRadiusFraction: Float = 0.011
    private static let glowRadiusFraction: Float = 0.05
    private static let groupSize = MTLSize(width: 16, height: 16, depth: 1)

    static func run() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("[halation-bench] no Metal device or queue")
            return
        }
        print("[halation-bench] device: \(device.name)  unifiedMemory=\(device.hasUnifiedMemory)")

        guard let replica = try? device.makeLibrary(source: shaderSource, options: nil),
              let maskFunction = replica.makeFunction(name: "spatial_mask"),
              let compositeFunction = replica.makeFunction(name: "spatial_composite"),
              let maskPipeline = try? device.makeComputePipelineState(function: maskFunction),
              let compositePipeline = try? device.makeComputePipelineState(function: compositeFunction) else {
            print("[halation-bench] replica pipeline creation failed")
            return
        }

        func makeTexture(_ width: Int, _ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }

        func groups(_ width: Int, _ height: Int) -> MTLSize {
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        }

        /// Median wall time in milliseconds. On-device timings are noisier than
        /// the Mac's, so this takes more samples and reports the median.
        func median(iterations: Int = 40, _ body: (MTLCommandBuffer) -> Void) -> Double {
            func once() -> Double {
                guard let buffer = queue.makeCommandBuffer() else { return .nan }
                body(buffer)
                let start = DispatchTime.now().uptimeNanoseconds
                buffer.commit()
                buffer.waitUntilCompleted()
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            for _ in 0..<8 { _ = once() }
            var samples: [Double] = []
            for _ in 0..<iterations { samples.append(once()) }
            samples.sort()
            return samples[samples.count / 2]
        }

        var tint = SIMD3<Float>(1.0, 0.32, 0.10)
        var strength: Float = 0.43

        for (label, fullW, fullH) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let halfW = fullW / 2, halfH = fullH / 2
            let halationSigma = max(2, Float(halfW) * halationRadiusFraction) * sigmaPerRadius
            let glowSigma = max(4, Float(halfW) * glowRadiusFraction) * sigmaPerRadius

            guard let graded = makeTexture(fullW, fullH),
                  let mask = makeTexture(halfW, halfH),
                  let diffusionA = makeTexture(halfW, halfH),
                  let diffusionB = makeTexture(halfW, halfH),
                  let composited = makeTexture(fullW, fullH) else {
                print("[halation-bench] texture allocation failed at \(label)")
                continue
            }

            let narrowBlur = MPSImageGaussianBlur(device: device, sigma: halationSigma)
            narrowBlur.edgeMode = .clamp
            let wideBlur = MPSImageGaussianBlur(device: device, sigma: glowSigma)
            wideBlur.edgeMode = .clamp
            let redBlur = MPSImageGaussianBlur(device: device, sigma: halationSigma * 1.6)
            redBlur.edgeMode = .clamp
            let blueBlur = MPSImageGaussianBlur(device: device, sigma: halationSigma * 0.45)
            blueBlur.edgeMode = .clamp

            func encodeMask(_ buffer: MTLCommandBuffer) {
                guard let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(maskPipeline)
                encoder.setTexture(graded, index: 0)
                encoder.setTexture(mask, index: 1)
                encoder.dispatchThreadgroups(groups(halfW, halfH), threadsPerThreadgroup: groupSize)
                encoder.endEncoding()
            }
            func encodeComposite(_ buffer: MTLCommandBuffer, from diffusion: MTLTexture) {
                guard let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(compositePipeline)
                encoder.setTexture(graded, index: 0)
                encoder.setTexture(diffusion, index: 1)
                encoder.setTexture(composited, index: 2)
                encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                encoder.dispatchThreadgroups(groups(fullW, fullH), threadsPerThreadgroup: groupSize)
                encoder.endEncoding()
            }

            let tMask = median { encodeMask($0) }
            let tNarrow = median { narrowBlur.encode(commandBuffer: $0, sourceTexture: mask, destinationTexture: diffusionA) }
            let tWide = median { wideBlur.encode(commandBuffer: $0, sourceTexture: mask, destinationTexture: diffusionB) }
            let tComposite = median { encodeComposite($0, from: diffusionA) }

            /// One commit-and-wait, in milliseconds. Used for the interleaved
            /// comparison below, where `median` would measure each arm as a
            /// block and hand all the drift to whichever ran second.
            func timed(_ body: (MTLCommandBuffer) -> Void) -> Double {
                guard let buffer = queue.makeCommandBuffer() else { return .nan }
                body(buffer)
                let start = DispatchTime.now().uptimeNanoseconds
                buffer.commit()
                buffer.waitUntilCompleted()
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }

            func currentPasses(_ buffer: MTLCommandBuffer) {
                encodeMask(buffer)
                narrowBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionA)
                wideBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionB)
                encodeComposite(buffer, from: diffusionA)
                encodeComposite(buffer, from: diffusionB)
            }

            func physicalPasses(_ buffer: MTLCommandBuffer) {
                encodeMask(buffer)
                redBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionA)
                narrowBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionB)
                blueBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: composited)
                encodeComposite(buffer, from: diffusionA)
                encodeComposite(buffer, from: diffusionB)
            }

            // INTERLEAVED on purpose. The app's camera session is live while
            // this runs and steals GPU time in bursts, so measuring one arm as a
            // block and then the other hands all of that drift to whichever went
            // second. That is exactly how an earlier run reported the 3-blur
            // version as 30% *faster* than the 2-blur version, which is
            // impossible. Alternating makes any drift land on both arms.
            for _ in 0..<8 {
                _ = timed(currentPasses)
                _ = timed(physicalPasses)
            }
            var currentSamples: [Double] = []
            var physicalSamples: [Double] = []
            for _ in 0..<40 {
                currentSamples.append(timed(currentPasses))
                physicalSamples.append(timed(physicalPasses))
            }
            currentSamples.sort()
            physicalSamples.sort()
            let tCurrent = currentSamples[currentSamples.count / 2]
            let tPhysical = physicalSamples[physicalSamples.count / 2]
            print(String(format: "[halation-bench]   interleaved spread current  p10/p90: %6.3f / %6.3f ms",
                         currentSamples[4], currentSamples[35]))
            print(String(format: "[halation-bench]   interleaved spread physical p10/p90: %6.3f / %6.3f ms",
                         physicalSamples[4], physicalSamples[35]))

            print("")
            print("[halation-bench] === \(label)   half-res \(halfW)x\(halfH)")
            print(String(format: "[halation-bench]   mask kernel (full->half)      : %7.3f ms", tMask))
            print(String(format: "[halation-bench]   halation blur  sigma %7.2f   : %7.3f ms", halationSigma, tNarrow))
            print(String(format: "[halation-bench]   glow blur      sigma %7.2f   : %7.3f ms", glowSigma, tWide))
            print(String(format: "[halation-bench]   one full-res composite        : %7.3f ms", tComposite))
            print(String(format: "[halation-bench]   ---- CURRENT STAGE TOTAL      : %7.3f ms", tCurrent))
            print(String(format: "[halation-bench]   ---- PHYSICAL (3 blurs) TOTAL : %7.3f ms", tPhysical))
            print(String(format: "[halation-bench]   DELTA                         : %7.3f ms  (+%.0f%% of the stage)",
                         tPhysical - tCurrent, (tPhysical / tCurrent - 1) * 100))
            print(String(format: "[halation-bench]   frame budget at 24 fps        :  41.667 ms"))
            print(String(format: "[halation-bench]   stage as share of budget      : %7.2f %%", tCurrent / 41.667 * 100))
            print(String(format: "[halation-bench]   delta as share of budget      : %7.2f %%", (tPhysical - tCurrent) / 41.667 * 100))
        }

        // Ground truth: the real production stage, not the replica.
        measureRealStage(device: device, queue: queue)
        measureOverheads(device: device, queue: queue)
        measureStorageMode(device: device, queue: queue,
                           maskPipeline: maskPipeline, compositePipeline: compositePipeline)
    }

    /// The replica used `.private` scratch textures; `SpatialEffectsStage`
    /// leaves `storageMode` unset, which defaults to `.shared` on iOS. This runs
    /// the identical pass sequence both ways to see whether that alone explains
    /// the gap between the replica's summed passes and the real `apply` cost.
    private static func measureStorageMode(
        device: MTLDevice,
        queue: MTLCommandQueue,
        maskPipeline: MTLComputePipelineState,
        compositePipeline: MTLComputePipelineState
    ) {
        var tint = SIMD3<Float>(1.0, 0.32, 0.10)
        var strength: Float = 0.43

        for (label, width, height) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let halfW = width / 2, halfH = height / 2
            let halationSigma = max(2, Float(halfW) * halationRadiusFraction) * sigmaPerRadius
            let glowSigma = max(4, Float(halfW) * glowRadiusFraction) * sigmaPerRadius

            func texture(_ w: Int, _ h: Int, _ mode: MTLStorageMode) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = mode
                return device.makeTexture(descriptor: descriptor)
            }

            for mode in [MTLStorageMode.shared, MTLStorageMode.private] {
                guard let graded = texture(width, height, mode),
                      let mask = texture(halfW, halfH, mode),
                      let diffusionA = texture(halfW, halfH, mode),
                      let diffusionB = texture(halfW, halfH, mode),
                      let composited = texture(width, height, mode) else { continue }

                let narrowBlur = MPSImageGaussianBlur(device: device, sigma: halationSigma)
                narrowBlur.edgeMode = .clamp
                let wideBlur = MPSImageGaussianBlur(device: device, sigma: glowSigma)
                wideBlur.edgeMode = .clamp

                func once() -> Double {
                    guard let buffer = queue.makeCommandBuffer() else { return .nan }
                    if let encoder = buffer.makeComputeCommandEncoder() {
                        encoder.setComputePipelineState(maskPipeline)
                        encoder.setTexture(graded, index: 0)
                        encoder.setTexture(mask, index: 1)
                        encoder.dispatchThreadgroups(
                            MTLSize(width: (halfW + 15) / 16, height: (halfH + 15) / 16, depth: 1),
                            threadsPerThreadgroup: groupSize)
                        encoder.endEncoding()
                    }
                    narrowBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionA)
                    wideBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: diffusionB)
                    for diffusion in [diffusionA, diffusionB] {
                        if let encoder = buffer.makeComputeCommandEncoder() {
                            encoder.setComputePipelineState(compositePipeline)
                            encoder.setTexture(graded, index: 0)
                            encoder.setTexture(diffusion, index: 1)
                            encoder.setTexture(composited, index: 2)
                            encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                            encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                            encoder.dispatchThreadgroups(
                                MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                threadsPerThreadgroup: groupSize)
                            encoder.endEncoding()
                        }
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }

                for _ in 0..<8 { _ = once() }
                var samples: [Double] = []
                for _ in 0..<40 { samples.append(once()) }
                samples.sort()
                let name = mode == .private ? "private" : "shared "
                print(String(format: "[halation-bench] same passes, %@ scratch \(label): %7.3f ms",
                             name, samples[samples.count / 2]))
            }
        }
    }

    /// Decomposes the gap between the replica's summed GPU passes and the real
    /// `apply` cost. The production path allocates four scratch textures on
    /// every call — two of them full-resolution RGBA16F, which is ~66 MB each at
    /// 4K — and commits its own command buffer, so it also pays the CPU/GPU
    /// sync latency.
    private static func measureOverheads(device: MTLDevice, queue: MTLCommandQueue) {
        for (label, width, height) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let halfW = width / 2, halfH = height / 2

            let fullDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            fullDescriptor.usage = [.shaderRead, .shaderWrite]
            fullDescriptor.storageMode = .private
            let halfDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: halfW, height: halfH, mipmapped: false)
            halfDescriptor.usage = [.shaderRead, .shaderWrite]
            halfDescriptor.storageMode = .private

            func allocateScratch() {
                _ = device.makeTexture(descriptor: halfDescriptor)   // mask
                _ = device.makeTexture(descriptor: halfDescriptor)   // halation diffusion
                _ = device.makeTexture(descriptor: halfDescriptor)   // glow diffusion
                _ = device.makeTexture(descriptor: fullDescriptor)   // composited
            }

            for _ in 0..<5 { allocateScratch() }
            var allocation: [Double] = []
            for _ in 0..<25 {
                let start = DispatchTime.now().uptimeNanoseconds
                allocateScratch()
                allocation.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            allocation.sort()

            var sync: [Double] = []
            for _ in 0..<25 {
                guard let buffer = queue.makeCommandBuffer() else { continue }
                let start = DispatchTime.now().uptimeNanoseconds
                buffer.commit()
                buffer.waitUntilCompleted()
                sync.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            sync.sort()

            let bytes = Double(halfW * halfH * 8) * 3 + Double(width * height * 8)
            print(String(format: "[halation-bench] 4 scratch textures alloc \(label): %7.3f ms  (%.0f MB)",
                         allocation[allocation.count / 2], bytes / 1_048_576))
            print(String(format: "[halation-bench] empty commit+wait  \(label): %7.3f ms", sync[sync.count / 2]))
        }
    }

    /// Times `SpatialEffectsStage.apply` itself, which allocates its own
    /// textures and command buffer per call. This is the number that actually
    /// matters — the replica exists only to make the terms comparable with the
    /// Mac harness.
    private static func measureRealStage(device: MTLDevice, queue: MTLCommandQueue) {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.main) else {
            print("[halation-bench] could not load the app's default Metal library")
            return
        }
        guard let stage = try? SpatialEffectsStage(device: device, library: library) else {
            print("[halation-bench] could not construct SpatialEffectsStage")
            return
        }

        for (label, width, height) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let graded = device.makeTexture(descriptor: descriptor),
                  let input = device.makeTexture(descriptor: descriptor) else { continue }

            func once() -> Double {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = stage.apply(
                    graded: graded,
                    input: input,
                    commandQueue: queue,
                    halationStrength: 0.43,
                    glowStrength: 0.35,
                    halationRadiusFraction: 0.011,
                    halationTint: SIMD3<Float>(1.0, 0.32, 0.10),
                    width: width,
                    height: height)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                return result == nil ? .nan : elapsed
            }

            for _ in 0..<5 { _ = once() }
            var samples: [Double] = []
            for _ in 0..<25 { samples.append(once()) }
            samples.sort()
            print(String(format: "[halation-bench] REAL SpatialEffectsStage.apply \(label): %7.3f ms (median of 25)",
                         samples[samples.count / 2]))
        }
        print("[halation-bench] done")
    }
}
#endif
