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
            ZStack {
                // Each exposure spins about its own centre; only the view offset
                // separates them, so neither orbits the other.
                Image("HalationRear")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(reduceMotion ? 0 : timing.rotationDegrees))
                    .offset(x: 4.9, y: -4.0)
                Image("HalationFront")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(reduceMotion ? 0 : timing.rotationDegrees))
                    .offset(x: -1.9, y: 1.6)
            }
            // Grain is applied after the baked smear and the live rotation.
            // Soft light leaves the black surround untouched, so no mask is needed.
            // The group ignores the safe area so the reel stays centred on the
            // display while the edge markings stay inside it.
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
            }
            .ignoresSafeArea()
            SplashEdgeOverlay(
                details: .placeholder,
                version: AppVersion.current()
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(timing.opacity)
        .accessibilityHidden(true)
        .onChange(of: scenePhase) { _, phase in
            timing.setActive(phase == .active, at: ProcessInfo.processInfo.systemUptime)
        }
        .task(id: scenePhase) {
            timing.setActive(scenePhase == .active, at: ProcessInfo.processInfo.systemUptime)
            guard scenePhase == .active else { return }
            let clock = ContinuousClock()
            let anchor = clock.now
            let start = ProcessInfo.processInfo.systemUptime
            var schedule = StartupSplashFrameSchedule(start: start)
            while !Task.isCancelled {
                do {
                    try await clock.sleep(
                        until: anchor.advanced(by: .seconds(schedule.nextDeadline - start)),
                        tolerance: .zero
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                let timestamp = ProcessInfo.processInfo.systemUptime
                timing.advance(to: timestamp)
                schedule.didDeliver(at: timestamp)
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
