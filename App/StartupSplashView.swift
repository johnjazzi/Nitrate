import CoreGraphics
import SwiftUI

/// Native launch overlay; the real camera view remains mounted underneath it.
struct StartupSplashView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timing: StartupSplashTiming
    let onFinished: () -> Void

    init(isPreview: Bool, onFinished: @escaping () -> Void) {
        _timing = State(initialValue: StartupSplashTiming(isPreview: isPreview))
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image("HalationLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .overlay {
                    Image(
                        decorative: SplashGrain.frames[reduceMotion ? 0 : timing.frameIndex],
                        scale: 1,
                        orientation: .up
                    )
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)
                    .blendMode(.softLight)
                    .opacity(0.22)
                    .mask {
                        Image("HalationLogo")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .rotationEffect(.degrees(reduceMotion ? 0 : timing.rotationDegrees))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .opacity(timing.opacity)
        .accessibilityHidden(true)
        .onChange(of: scenePhase) { _, phase in
            timing.setActive(phase == .active, at: ProcessInfo.processInfo.systemUptime)
        }
        .task(id: scenePhase) {
            timing.setActive(scenePhase == .active, at: ProcessInfo.processInfo.systemUptime)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1 / StartupSplashTiming.framesPerSecond))
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                timing.advance(to: ProcessInfo.processInfo.systemUptime)
                if timing.isFinished {
                    onFinished()
                    return
                }
            }
        }
    }
}

/// 48 deterministic 64×64 one-byte grayscale tiles, generated once, not per tick.
/// The cache is bounded to 192 KiB of pixel data and reused by every splash view.
@MainActor
private enum SplashGrain {
    static let frames: [CGImage] = (0..<StartupSplashTiming.frameCount).map { frame in
        let side = 64
        var random = UInt64(frame + 1) &* 0x9E3779B97F4A7C15
        let pixels = (0..<(side * side)).map { _ -> UInt8 in
            random ^= random >> 12
            random ^= random << 25
            random ^= random >> 27
            return UInt8(truncatingIfNeeded: (random &* 0x2545F4914F6CDD1D) >> 32)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
