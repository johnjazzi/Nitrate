#if DEBUG
import Foundation
import Metal
import MetalPerformanceShaders

/// Development-only measurement of the spatial halation stage.
///
/// The Mac numbers were produced by a standalone harness that replicated
/// `spatial.metal` and `SpatialEffectsStage`'s blur work. This runs the
/// SAME terms on the actual device GPU so the two can be compared directly,
/// and additionally times the real `SpatialEffectsStage.apply` path as ground
/// truth against the replica.
///
/// The comparison it exists for is how the halation mask gets its reach. The
/// shipping stage builds ONE mip chain of the mask — a single
/// `MTLBlitCommandEncoder.generateMipmaps` — and the apply pass reads it at a
/// level chosen per colour (red coarsest). The retired shape ran three
/// independent Gaussian blurs of the same mask at three sigmas and sampled one
/// channel from each. Both arms here dispatch the same mask kernel and the same
/// single full-resolution composite, so the delta is the cost of the reach and
/// nothing else. It is a cost comparison, not a look comparison: a mip level is
/// a box downsample, not a Gaussian.
///
/// Runs only when the app is launched with `-halation-benchmark`, prints to
/// stdout, and is compiled out of Release builds entirely.
enum HalationDeviceBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-halation-benchmark")
    }

    /// Mirrors spatial.metal closely enough to measure the same GPU work: the
    /// 2x2 box-average mask kernel, the mip-chain composite that replaced the
    /// per-colour blurs, and the retired three-blur composite it is compared
    /// against.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler spatial_linear_sampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler spatial_mip_sampler(coord::normalized, filter::linear,
                                          mip_filter::linear, address::clamp_to_edge);

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

    // SHIPPING SHAPE: one rgb read of how hard the mask responds, one level
    // chosen per colour, then one sample per channel at that channel's level.
    kernel void spatial_composite_chain(
        texture2d<float, access::read>   source [[texture(0)]],
        texture2d<float, access::sample> mask   [[texture(1)]],
        texture2d<float, access::write>  output [[texture(2)]],
        constant float&  strength             [[buffer(0)]],
        constant float3& tint                 [[buffer(1)]],
        constant float3& baseLOD              [[buffer(2)]],
        constant float&  lodGain              [[buffer(3)]],
        constant float3& widenLow             [[buffer(4)]],
        constant float3& widenHigh            [[buffer(5)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float4 base = source.read(gid);
        float2 size = float2(source.get_width(), source.get_height());
        float2 uv = (float2(gid) + 0.5f) / size;
        float3 response = mask.sample(spatial_mip_sampler, uv, level(0.0f)).rgb;
        float3 climb = clamp((response - widenLow) / max(widenHigh - widenLow, 0.01f), 0.0f, 1.0f);
        climb = climb * climb * (3.0f - 2.0f * climb);
        float3 lod = max(baseLOD + lodGain * climb, 0.0f);
        float3 diffusion = float3(mask.sample(spatial_mip_sampler, uv, level(lod.r)).r,
                                  mask.sample(spatial_mip_sampler, uv, level(lod.g)).g,
                                  mask.sample(spatial_mip_sampler, uv, level(lod.b)).b);
        float3 result = base.rgb + tint * diffusion * strength;
        output.write(float4(result, base.a), gid);
    }

    // RETIRED SHAPE: three blurred copies of the mask, one channel from each.
    kernel void spatial_composite_layers(
        texture2d<float, access::read>   source [[texture(0)]],
        texture2d<float, access::sample> red    [[texture(1)]],
        texture2d<float, access::sample> green  [[texture(2)]],
        texture2d<float, access::sample> blue   [[texture(3)]],
        texture2d<float, access::write>  output [[texture(4)]],
        constant float&  strength [[buffer(0)]],
        constant float3& tint     [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float4 base = source.read(gid);
        float2 size = float2(source.get_width(), source.get_height());
        float2 uv = (float2(gid) + 0.5f) / size;
        float3 diffusion = float3(red.sample(spatial_linear_sampler, uv).r,
                                  green.sample(spatial_linear_sampler, uv).g,
                                  blue.sample(spatial_linear_sampler, uv).b);
        float3 result = base.rgb + tint * diffusion * strength;
        output.write(float4(result, base.a), gid);
    }
    """

    private static let sigmaPerRadius: Float = 2.7615277481
    private static let halationRadiusFraction: Float = 0.011
    private static let groupSize = MTLSize(width: 16, height: 16, depth: 1)

    /// The stage's own numbers, so the replica measures the shipping look.
    private static let redRadiusMultiplier: Float = 1.8
    private static let greenRadiusMultiplier: Float = 1.0
    private static let blueRadiusMultiplier: Float = 0.5
    private static let lodGain: Float = 1.0
    private static let widenLow = SIMD3<Float>(0.08, 0.35, 0.60)
    private static let widenHigh = SIMD3<Float>(0.55, 0.85, 1.00)

    /// `SpatialEffectsStage.halationBaseLOD`, replicated: the mip level whose
    /// texel is the blur sigma that colour wants, at the mask's resolution.
    /// `maskWidth` matters twice over — the radius is a fraction of it, and one
    /// octave of the chain halves it — so it is passed in rather than guessed.
    private static func halationBaseLOD(maskWidth: Int) -> SIMD3<Float> {
        let baseRadius = Float(maskWidth) * halationRadiusFraction
        func level(_ multiplier: Float) -> Float {
            max(0, log2(baseRadius * multiplier * sigmaPerRadius / 0.5))
        }
        return SIMD3(level(redRadiusMultiplier), level(greenRadiusMultiplier),
                     level(blueRadiusMultiplier))
    }

    /// Levels in the mask's chain: full size down to a single texel.
    private static func mipLevelCount(_ width: Int, _ height: Int) -> Int {
        var levels = 1
        var size = max(width, height)
        while size > 1 {
            size /= 2
            levels += 1
        }
        return levels
    }

    static func run() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("[halation-bench] no Metal device or queue")
            return
        }
        print("[halation-bench] device: \(device.name)  unifiedMemory=\(device.hasUnifiedMemory)")

        guard let replica = try? device.makeLibrary(source: shaderSource, options: nil),
              let maskFunction = replica.makeFunction(name: "spatial_mask"),
              let chainFunction = replica.makeFunction(name: "spatial_composite_chain"),
              let layersFunction = replica.makeFunction(name: "spatial_composite_layers"),
              let maskPipeline = try? device.makeComputePipelineState(function: maskFunction),
              let chainPipeline = try? device.makeComputePipelineState(function: chainFunction),
              let layersPipeline = try? device.makeComputePipelineState(function: layersFunction) else {
            print("[halation-bench] replica pipeline creation failed")
            return
        }

        func makeTexture(_ width: Int, _ height: Int, mipmapped: Bool = false) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: mipmapped)
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
            let baseRadius = Float(halfW) * halationRadiusFraction
            var baseLOD = halationBaseLOD(maskWidth: halfW)
            let levels = mipLevelCount(halfW, halfH)

            guard let graded = makeTexture(fullW, fullH),
                  let mask = makeTexture(halfW, halfH, mipmapped: true),
                  let redLayer = makeTexture(halfW, halfH),
                  let greenLayer = makeTexture(halfW, halfH),
                  let blueLayer = makeTexture(halfW, halfH),
                  let composited = makeTexture(fullW, fullH) else {
                print("[halation-bench] texture allocation failed at \(label)")
                continue
            }

            // The retired shape's three sigmas: the same base radius, three
            // multipliers. No `max(2, ...)` floor — the stage dropped it, and a
            // floor here would measure a blur nobody ships.
            let redSigma = baseRadius * redRadiusMultiplier * sigmaPerRadius
            let greenSigma = baseRadius * greenRadiusMultiplier * sigmaPerRadius
            let blueSigma = baseRadius * blueRadiusMultiplier * sigmaPerRadius
            let redBlur = MPSImageGaussianBlur(device: device, sigma: redSigma)
            redBlur.edgeMode = .clamp
            let greenBlur = MPSImageGaussianBlur(device: device, sigma: greenSigma)
            greenBlur.edgeMode = .clamp
            let blueBlur = MPSImageGaussianBlur(device: device, sigma: blueSigma)
            blueBlur.edgeMode = .clamp

            func encodeMask(_ buffer: MTLCommandBuffer) {
                guard let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(maskPipeline)
                encoder.setTexture(graded, index: 0)
                encoder.setTexture(mask, index: 1)
                encoder.dispatchThreadgroups(groups(halfW, halfH), threadsPerThreadgroup: groupSize)
                encoder.endEncoding()
            }
            /// The ONE pass that replaced the three blurs: level N is a box
            /// downsample of level N-1, so the whole reach costs a blit.
            func encodeMipChain(_ buffer: MTLCommandBuffer) {
                guard let blit = buffer.makeBlitCommandEncoder() else { return }
                blit.generateMipmaps(for: mask)
                blit.endEncoding()
            }
            func encodeChainComposite(_ buffer: MTLCommandBuffer) {
                guard let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(chainPipeline)
                encoder.setTexture(graded, index: 0)
                encoder.setTexture(mask, index: 1)
                encoder.setTexture(composited, index: 2)
                encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                encoder.setBytes(&baseLOD, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
                var gain = lodGain
                var low = widenLow
                var high = widenHigh
                encoder.setBytes(&gain, length: MemoryLayout<Float>.size, index: 3)
                encoder.setBytes(&low, length: MemoryLayout<SIMD3<Float>>.size, index: 4)
                encoder.setBytes(&high, length: MemoryLayout<SIMD3<Float>>.size, index: 5)
                encoder.dispatchThreadgroups(groups(fullW, fullH), threadsPerThreadgroup: groupSize)
                encoder.endEncoding()
            }
            func encodeLayersComposite(_ buffer: MTLCommandBuffer) {
                guard let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(layersPipeline)
                encoder.setTexture(graded, index: 0)
                encoder.setTexture(redLayer, index: 1)
                encoder.setTexture(greenLayer, index: 2)
                encoder.setTexture(blueLayer, index: 3)
                encoder.setTexture(composited, index: 4)
                encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                encoder.dispatchThreadgroups(groups(fullW, fullH), threadsPerThreadgroup: groupSize)
                encoder.endEncoding()
            }

            let tMask = median { encodeMask($0) }
            let tChain = median { encodeMipChain($0) }
            let tChainComposite = median { encodeChainComposite($0) }
            let tRed = median { redBlur.encode(commandBuffer: $0, sourceTexture: mask, destinationTexture: redLayer) }
            let tGreen = median { greenBlur.encode(commandBuffer: $0, sourceTexture: mask, destinationTexture: greenLayer) }
            let tBlue = median { blueBlur.encode(commandBuffer: $0, sourceTexture: mask, destinationTexture: blueLayer) }
            let tLayersComposite = median { encodeLayersComposite($0) }

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

            func chainPasses(_ buffer: MTLCommandBuffer) {
                encodeMask(buffer)
                encodeMipChain(buffer)
                encodeChainComposite(buffer)
            }

            func layerPasses(_ buffer: MTLCommandBuffer) {
                encodeMask(buffer)
                redBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: redLayer)
                greenBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: greenLayer)
                blueBlur.encode(commandBuffer: buffer, sourceTexture: mask, destinationTexture: blueLayer)
                encodeLayersComposite(buffer)
            }

            // INTERLEAVED on purpose. The app's camera session is live while
            // this runs and steals GPU time in bursts, so measuring one arm as a
            // block and then the other hands all of that drift to whichever went
            // second. That is exactly how an earlier run reported the 3-blur
            // version as 30% *faster* than the 2-blur version, which is
            // impossible. Alternating makes any drift land on both arms.
            for _ in 0..<8 {
                _ = timed(chainPasses)
                _ = timed(layerPasses)
            }
            var chainSamples: [Double] = []
            var layerSamples: [Double] = []
            for _ in 0..<40 {
                chainSamples.append(timed(chainPasses))
                layerSamples.append(timed(layerPasses))
            }
            chainSamples.sort()
            layerSamples.sort()
            let tChainTotal = chainSamples[chainSamples.count / 2]
            let tLayerTotal = layerSamples[layerSamples.count / 2]
            print(String(format: "[halation-bench]   interleaved spread mip chain   p10/p90: %6.3f / %6.3f ms",
                         chainSamples[4], chainSamples[35]))
            print(String(format: "[halation-bench]   interleaved spread three blur p10/p90: %6.3f / %6.3f ms",
                         layerSamples[4], layerSamples[35]))

            print("")
            print("[halation-bench] === \(label)   half-res \(halfW)x\(halfH)")
            print(String(format: "[halation-bench]   base LOD r/g/b                      : %5.2f / %5.2f / %5.2f",
                         baseLOD.x, baseLOD.y, baseLOD.z))
            print(String(format: "[halation-bench]   mask kernel (full->half)            : %7.3f ms", tMask))
            print(String(format: "[halation-bench]   mip chain (generateMipmaps, \(levels) levels): %7.3f ms",
                         tChain))
            print(String(format: "[halation-bench]   one full-res composite (mip chain)  : %7.3f ms", tChainComposite))
            print(String(format: "[halation-bench]   ---- MIP CHAIN TOTAL                : %7.3f ms", tChainTotal))
            print(String(format: "[halation-bench]   red blur    sigma %7.2f            : %7.3f ms", redSigma, tRed))
            print(String(format: "[halation-bench]   green blur  sigma %7.2f            : %7.3f ms", greenSigma, tGreen))
            print(String(format: "[halation-bench]   blue blur   sigma %7.2f            : %7.3f ms", blueSigma, tBlue))
            print(String(format: "[halation-bench]   one full-res composite (3 layers)   : %7.3f ms", tLayersComposite))
            print(String(format: "[halation-bench]   ---- THREE-BLUR TOTAL               : %7.3f ms", tLayerTotal))
            print(String(format: "[halation-bench]   DELTA                               : %7.3f ms  (three-blur is +%.0f%% of the chain)",
                         tLayerTotal - tChainTotal, (tLayerTotal / tChainTotal - 1) * 100))
            print(String(format: "[halation-bench]   frame budget at 24 fps              :  41.667 ms"))
            print(String(format: "[halation-bench]   stage as share of budget            : %7.2f %%", tChainTotal / 41.667 * 100))
            print(String(format: "[halation-bench]   delta as share of budget            : %7.2f %%", (tLayerTotal - tChainTotal) / 41.667 * 100))
        }

        // Ground truth: the real production stage, not the replica.
        measureRealStage(device: device, queue: queue)
        measureOverheads(device: device, queue: queue)
        measureStorageMode(device: device, queue: queue,
                           maskPipeline: maskPipeline, chainPipeline: chainPipeline)
    }

    /// The replica used `.private` scratch textures; `SpatialEffectsStage`
    /// leaves `storageMode` unset, which defaults to `.shared` on iOS. This runs
    /// the identical pass sequence both ways to see whether that alone explains
    /// the gap between the replica's summed passes and the real `apply` cost.
    /// The mip chain is the pass most likely to care: `generateMipmaps` writes
    /// every level, which is exactly where a shared allocation can stall.
    private static func measureStorageMode(
        device: MTLDevice,
        queue: MTLCommandQueue,
        maskPipeline: MTLComputePipelineState,
        chainPipeline: MTLComputePipelineState
    ) {
        var tint = SIMD3<Float>(1.0, 0.32, 0.10)
        var strength: Float = 0.43

        for (label, width, height) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let halfW = width / 2, halfH = height / 2
            var baseLOD = halationBaseLOD(maskWidth: halfW)

            func texture(_ w: Int, _ h: Int, _ mode: MTLStorageMode,
                         mipmapped: Bool = false) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float, width: w, height: h, mipmapped: mipmapped)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = mode
                return device.makeTexture(descriptor: descriptor)
            }

            for mode in [MTLStorageMode.shared, MTLStorageMode.private] {
                guard let graded = texture(width, height, mode),
                      let mask = texture(halfW, halfH, mode, mipmapped: true),
                      let composited = texture(width, height, mode) else { continue }

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
                    if let blit = buffer.makeBlitCommandEncoder() {
                        blit.generateMipmaps(for: mask)
                        blit.endEncoding()
                    }
                    if let encoder = buffer.makeComputeCommandEncoder() {
                        encoder.setComputePipelineState(chainPipeline)
                        encoder.setTexture(graded, index: 0)
                        encoder.setTexture(mask, index: 1)
                        encoder.setTexture(composited, index: 2)
                        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                        encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                        encoder.setBytes(&baseLOD, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
                        var gain = lodGain
                        var low = widenLow
                        var high = widenHigh
                        encoder.setBytes(&gain, length: MemoryLayout<Float>.size, index: 3)
                        encoder.setBytes(&low, length: MemoryLayout<SIMD3<Float>>.size, index: 4)
                        encoder.setBytes(&high, length: MemoryLayout<SIMD3<Float>>.size, index: 5)
                        encoder.dispatchThreadgroups(
                            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                            threadsPerThreadgroup: groupSize)
                        encoder.endEncoding()
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
                print(String(format: "[halation-bench] mip chain passes, %@ scratch \(label): %7.3f ms",
                             name, samples[samples.count / 2]))
            }
        }
    }

    /// Decomposes the gap between the replica's summed GPU passes and the real
    /// `apply` cost. The production path allocates two scratch textures on every
    /// call — the mipmapped half-resolution mask and a full-resolution RGBA16F
    /// output, which is ~66 MB at 4K — and commits its own command buffer, so it
    /// also pays the CPU/GPU sync latency.
    private static func measureOverheads(device: MTLDevice, queue: MTLCommandQueue) {
        for (label, width, height) in [("4K 3840x2160", 3840, 2160), ("1080p 1920x1080", 1920, 1080)] {
            let halfW = width / 2, halfH = height / 2

            let fullDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            fullDescriptor.usage = [.shaderRead, .shaderWrite]
            fullDescriptor.storageMode = .private
            let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: halfW, height: halfH, mipmapped: true)
            maskDescriptor.usage = [.shaderRead, .shaderWrite]
            maskDescriptor.storageMode = .private

            func allocateScratch() {
                _ = device.makeTexture(descriptor: maskDescriptor)   // mipmapped halation mask
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

            // A mip chain is 4/3 of level 0's bytes.
            let bytes = Double(halfW * halfH * 8) * 4.0 / 3.0 + Double(width * height * 8)
            print(String(format: "[halation-bench] 2 scratch textures alloc \\(label): %7.3f ms  (%.0f MB)",
                         allocation[allocation.count / 2], bytes / 1_048_576))
            print(String(format: "[halation-bench] empty commit+wait  \\(label): %7.3f ms", sync[sync.count / 2]))
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
                // Production order: halation on the scene-linear source, then
                // the LUT (not timed here), then the post-LUT glow bloom.
                let halated = stage.applyHalation(
                    source: input,
                    commandQueue: queue,
                    strength: 0.43,
                    radiusFraction: 0.011,
                    layerScale: SIMD3<Float>(1.0, 0.32, 0.10),
                    width: width,
                    height: height)
                let glowed = stage.applyGlow(
                    graded: graded,
                    commandQueue: queue,
                    strength: 0.35,
                    width: width,
                    height: height)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                return (halated == nil || glowed == nil) ? .nan : elapsed
            }

            for _ in 0..<5 { _ = once() }
            var samples: [Double] = []
            for _ in 0..<25 { samples.append(once()) }
            samples.sort()
            print(String(format: "[halation-bench] REAL SpatialEffectsStage.apply \\(label): %7.3f ms (median of 25)",
                         samples[samples.count / 2]))
        }
        print("[halation-bench] done")
    }
}
#endif
