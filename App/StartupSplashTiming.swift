import Foundation

/// Monotonic active time drives a quantized 48-frame loop and a separate exit fade.
struct StartupSplashTiming {
    static let framesPerSecond = 24.0
    static let frameCount = 48
    static let duration = 2.0
    static let fadeDuration = 0.25

    let isPreview: Bool
    private(set) var elapsed = 0.0
    private var lastActiveTimestamp: TimeInterval?

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
    }

    var isFinished: Bool {
        !isPreview && elapsed >= Self.duration + Self.fadeDuration
    }

    var frameIndex: Int {
        let cycleTime = elapsed.truncatingRemainder(dividingBy: Self.duration)
        return min(Int(cycleTime * Self.framesPerSecond), Self.frameCount - 1)
    }

    /// The launch holds the completed turn during its fade; preview wraps forever.
    var rotationDegrees: Double {
        if !isPreview && elapsed >= Self.duration { return 360 }
        return Double(frameIndex) * 360 / Double(Self.frameCount)
    }

    var opacity: Double {
        if isPreview { return 1 }
        return max(0, min(1, 1 - (elapsed - Self.duration) / Self.fadeDuration))
    }

    mutating func setActive(_ active: Bool, at timestamp: TimeInterval) {
        advance(to: timestamp)
        lastActiveTimestamp = active ? timestamp : nil
    }

    mutating func advance(to timestamp: TimeInterval) {
        guard let previous = lastActiveTimestamp, timestamp >= previous else { return }
        elapsed += timestamp - previous
        lastActiveTimestamp = timestamp
    }
}
