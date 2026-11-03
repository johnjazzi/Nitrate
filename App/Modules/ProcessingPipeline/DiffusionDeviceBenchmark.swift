#if DEBUG
import Foundation
import Metal

/// Development-only measurement of the lens diffusion node's cost.
///
/// Runs only when the app is launched with `-diffusion-benchmark`, prints to
/// stdout, and is compiled out of Release builds. It times the REAL stage —
/// `SpatialEffectsStage.applyHalation`, the same call the video, photo and debug
/// paths make — so the numbers include the shared decode/encode pass, the
/// halation layer blurs and the diffusion ladder together, exactly as a frame
/// pays for them.
///
/// The measurement is a median of wall time around a commit-and-wait, which is
/// what a frame loop actually experiences. The first runs of each configuration
/// are discarded so texture allocation and pipeline warm-up do not land in the
/// sample.
enum DiffusionDeviceBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-diffusion-benchmark")
    }

    static func run(width: Int = 3840, height: Int = 2160, iterations: Int = 15) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("[diffusion-bench] no Metal device or queue")
            return
        }
        print("[diffusion-bench] device: \(device.name)  unifiedMemory=\(device.hasUnifiedMemory)")

        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            print("[diffusion-bench] default.metallib not found in the app bundle")
            return
        }
        guard let stage = try? SpatialEffectsStage(device: device, library: library) else {
            print("[diffusion-bench] stage creation failed")
            return
        }
        guard let source = makeSource(device: device, width: width, height: height) else {
            print("[diffusion-bench] source texture allocation failed")
            return
        }

        // The shipped 35mm stock geometry: a real render, not a synthetic worst
        // case, so the halation work in the baseline is the work a frame does.
        let strength: Float = 2.5
        let radiusFraction: Float = 0.001
        let layerScale = SIMD3<Float>(1, 0.32, 0.10)

        // INTERLEAVED on purpose. Absolute temperatures and the simulator's
        // shared GPU drift over a run, and measuring one arm as a block and the
        // other afterwards hands all of that drift to whichever ran second. Each
        // sample here is a baseline/config PAIR captured back to back, and the
        // reported figure is the median of the per-pair DIFFERENCES — the cost
        // of the node, not of the GPU of the moment.
        func measure(_ settings: DiffusionSettings) -> Double {
            measureOnce(settings, stage: stage, queue: queue, source: source,
                        strength: strength, radiusFraction: radiusFraction, layerScale: layerScale,
                        width: width, height: height)
        }

        func pairedDelta(_ settings: DiffusionSettings, samples: Int) -> (median: Double, baseline: Double) {
            var deltas: [Double] = []
            var baselines: [Double] = []
            for index in 0..<samples {
                let before = measure(.disabled)
                let with = measure(settings)
                guard index >= 2 else { continue }
                deltas.append(with - before)
                baselines.append(before)
            }
            deltas.sort()
            baselines.sort()
            let half = deltas.count / 2
            return (deltas.isEmpty ? .nan : deltas[half],
                    baselines.isEmpty ? .nan : baselines[half])
        }

        print(String(format: "[diffusion-bench] %dx%d · halation on (strength %.1f, radius %.4f)",
                     width, height, strength, radiusFraction))
        print("[diffusion-bench] deltas are paired medians against the halation-only pass")

        for preset in DiffusionPreset.allCases where preset != .off {
            let settings = DiffusionSettings(preset: preset, amount: 0.50)
            let plan = settings.plan(sourceWidth: width)
            let result = pairedDelta(settings, samples: iterations)
            let described = plan.map {
                String(format: "%d levels, %d taps/axis, sigma %.1f px @1080p",
                       $0.levels, $0.taps, $0.sigmaPixels(atSourceWidth: width))
            } ?? "bypassed — nothing allocated"
            print(String(format: "[diffusion-bench]   %@ px / 0.50   %+7.2f ms  (baseline %.2f ms)  %@",
                         preset.title as NSString, result.median, result.baseline,
                         described as NSString))
        }
    }

    /// One commit-and-wait, in milliseconds.
    private static func measureOnce(
        _ settings: DiffusionSettings, stage: SpatialEffectsStage, queue: MTLCommandQueue,
        source: MTLTexture, strength: Float, radiusFraction: Float, layerScale: SIMD3<Float>,
        width: Int, height: Int
    ) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = stage.applyHalation(
            source: source, commandQueue: queue,
            strength: strength, radiusFraction: radiusFraction, layerScale: layerScale,
            diffusion: settings, width: width, height: height
        )
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// A 4K Apple Log 2-ish frame: mid grey everywhere, so the halation mask has
    /// real work to do without a synthetic worst case.
    private static func makeSource(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        // `.shared` so the CPU can fill it; this is a debug harness, not a
        // shipping allocation.
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let code: Float16 = 0.55
        var row = [Float16](repeating: code, count: width * 4)
        for index in 0..<width {
            row[index * 4 + 3] = 1
        }
        for y in 0..<height {
            row.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0,
                    withBytes: raw.baseAddress!, bytesPerRow: width * 8
                )
            }
        }
        return texture
    }
}
#endif
