import Foundation

/// A display preference only; it does not change the camera's capture format.
enum CameraPreviewMode: String, CaseIterable, Sendable {
    case neutral, stock, log

    static let preferenceKey = "camera.previewMode"

    static func resolved(_ raw: String?) -> Self {
        // Missing/invalid values and the retired "normal" value use Neutral.
        raw.flatMap(Self.init(rawValue:)) ?? .neutral
    }

    /// Each monitor mode consumes Log 2 directly; never stack Neutral and stock LUTs.
    func lutName(for selectedStockName: String?) -> String? {
        switch self {
        case .neutral: return "AppleLog2ToRec709.cube"
        case .stock: return selectedStockName
        case .log: return nil
        }
    }
}


/// Preview-layer display rotation for the active camera.
///
/// The preview layer's own rotation is a display transform, and the angle a
/// camera needs is per-camera: measured on device in a portrait hold, the rear
/// camera's horizon-level preview angle is 90° while the front camera's is 0°,
/// because the front camera's native data-output buffer is already
/// portrait-sized. A fixed 90° therefore renders the front preview a quarter
/// turn out. `AVCaptureVideoPreviewLayer` rotation angles are only 0/90/180/270.
enum CameraPreviewRotationPolicy {
    /// The angle used before the platform angle is known, and the fallback when
    /// no coordinator can describe the camera. Correct only for the rear camera.
    static let fallbackAngle: CGFloat = 90

    /// Only quarter turns are settable on a preview connection; anything else
    /// (including an unavailable coordinator) keeps the previous fixed angle.
    static func angle(platformAngle: CGFloat?) -> CGFloat {
        guard let platformAngle, platformAngle.isFinite else { return fallbackAngle }
        return platformAngle
    }
}

/// A filename-only load token: geometry, ISO, and gauge updates do not reload LUTs.
struct CameraPreviewLUTSelection: Equatable, Sendable {
    private(set) var name: String?
    private(set) var generation: UInt64 = 0

    @discardableResult
    mutating func select(_ name: String?) -> Bool {
        guard self.name != name else { return false }
        self.name = name
        generation &+= 1
        return true
    }
}

/// Pure strict cube parser used by the renderer. Keep file RGB order unchanged:
/// red is the fastest axis, matching Metal's x/y/z texture upload.
struct CameraPreviewCube: Sendable {
    let size: Int
    let rgba: [Float]

    enum ParseError: Error { case invalid }

    static func parse(_ content: String) throws -> Self {
        var size: Int?
        var minimumSeen = false
        var maximumSeen = false
        var values: [Float] = []
        for line in content.components(separatedBy: .newlines) {
            let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = parts.first else { continue }
            if first == "TITLE", values.isEmpty { continue }
            if first == "LUT_3D_SIZE" {
                guard size == nil, values.isEmpty, parts.count == 2,
                      let value = Int(parts[1]), (2...65).contains(value) else { throw ParseError.invalid }
                size = value
                continue
            }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                let minimum = first == "DOMAIN_MIN"
                guard values.isEmpty, parts.count == 4,
                      !(minimum ? minimumSeen : maximumSeen),
                      parts.dropFirst().compactMap(Float.init) == (minimum ? [0, 0, 0] : [1, 1, 1]) else {
                    throw ParseError.invalid
                }
                if minimum { minimumSeen = true } else { maximumSeen = true }
                continue
            }
            let rgb = parts.compactMap(Float.init)
            guard let size, parts.count == 3, rgb.count == 3,
                  rgb.allSatisfy({ $0.isFinite }), values.count < size * size * size * 4 else {
                throw ParseError.invalid
            }
            values.append(contentsOf: rgb)
            values.append(1)
        }
        guard let size, values.count == size * size * size * 4 else { throw ParseError.invalid }
        return Self(size: size, rgba: values)
    }
}

/// Pure display geometry and code-value conversion, independent of camera APIs.
enum CameraPreviewPolicy {
    static func drawablePixelSize(viewSize: CGSize, fallbackScale: CGFloat, displayScale: CGFloat) -> CGSize {
        guard viewSize.width.isFinite, viewSize.height.isFinite,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale
            : (fallbackScale.isFinite && fallbackScale > 0 ? fallbackScale : 1)
        return CGSize(width: (viewSize.width * scale).rounded(), height: (viewSize.height * scale).rounded())
    }

    struct PixelFormat: Equatable, Sendable {
        let tenBit: Bool
        let fullRange: Bool
    }

    /// Accept only the supported 10-bit bi-planar 4:2:0 / 4:2:2 formats.
    static func format(_ fourCC: UInt32) -> PixelFormat? {
        switch fourCC {
        case 0x78343230, 0x78343232: // x420, x422
            return PixelFormat(tenBit: true, fullRange: false)
        case 0x78663230, 0x78663232: // xf20, xf22
            return PixelFormat(tenBit: true, fullRange: true)
        default:
            return nil
        }
    }

    /// Undo display-space mirroring first, then clockwise display rotation.
    static func sourceUV(_ point: SIMD2<Float>, quarterTurns: Int, mirrored: Bool) -> SIMD2<Float> {
        let display = SIMD2<Float>(mirrored ? 1 - point.x : point.x, point.y)
        switch normalizedTurns(quarterTurns) {
        case 1: return SIMD2<Float>(display.y, 1 - display.x)
        case 2: return SIMD2<Float>(1 - display.x, 1 - display.y)
        case 3: return SIMD2<Float>(1 - display.y, display.x)
        default: return display
        }
    }

    /// Content dimensions relative to the view; fill may extend beyond one axis.
    /// Invalid or empty dimensions have no displayable content.
    static func imageScale(sourceWidth: Float, sourceHeight: Float,
                           viewWidth: Float, viewHeight: Float,
                           quarterTurns: Int, fill: Bool) -> SIMD2<Float> {
        guard sourceWidth.isFinite, sourceHeight.isFinite, viewWidth.isFinite, viewHeight.isFinite,
              sourceWidth > 0, sourceHeight > 0, viewWidth > 0, viewHeight > 0 else {
            return .zero
        }
        let swapped = normalizedTurns(quarterTurns) % 2 != 0
        let width = swapped ? sourceHeight : sourceWidth
        let height = swapped ? sourceWidth : sourceHeight
        let widthScale = viewWidth / width
        let heightScale = viewHeight / height
        let scale = fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        return SIMD2<Float>(width * scale / viewWidth, height * scale / viewHeight)
    }

    /// Decode integer-valued YCbCr samples, not normalized texture values.
    /// BT.2020 conversion preserves Log encoding and out-of-range RGB values;
    /// it applies neither a transfer function nor a clamp.
    static func logRGB(y: Float, cb: Float, cr: Float,
                       tenBit: Bool, fullRange: Bool) -> SIMD3<Float> {
        let luma: Float
        let blueChroma: Float
        let redChroma: Float
        if tenBit {
            luma = fullRange ? y / 1023 : (y - 64) / 876
            blueChroma = (cb - 512) / (fullRange ? 1023 : 896)
            redChroma = (cr - 512) / (fullRange ? 1023 : 896)
        } else {
            luma = fullRange ? y / 255 : (y - 16) / 219
            blueChroma = (cb - 128) / (fullRange ? 255 : 224)
            redChroma = (cr - 128) / (fullRange ? 255 : 224)
        }
        return SIMD3<Float>(luma + 1.4746 * redChroma,
                            luma - 0.164553 * blueChroma - 0.571353 * redChroma,
                            luma + 1.8814 * blueChroma)
    }

    private static func normalizedTurns(_ turns: Int) -> Int {
        let remainder = turns % 4
        return remainder < 0 ? remainder + 4 : remainder
    }
}

/// Pure, time-injected arbiter for the live LUT preview's last-good-frame
/// handoff.
///
/// A lens handoff, a source reconfiguration, or a brief nil frame is an
/// *expected* interruption, not a failure: the preview must keep presenting its
/// last graded drawable for a bounded grace instead of flashing the raw Log
/// layer and an error-styled label. A genuine failure — a frame the current
/// source cannot grade, a missing/invalid LUT, a GPU error — is never hidden.
///
/// The policy holds no clock, no lock, and no camera state; callers feed the
/// event and the current time so the whole transition sequence can be exercised
/// without a camera, a GPU, or a sleep.
struct CameraPreviewHandoffPolicy {
    /// How long an expected handoff may hold the last graded drawable before the
    /// preview surfaces the underlying source/unsupported condition. Bounded so
    /// a stopped source cannot freeze the preview indefinitely.
    static let grace: TimeInterval = 1.5

    static let pendingText = "Preview LUT pending — showing Log"
    static let sourceUnavailableText = "Preview LUT source unavailable — showing Log"

    /// A frame that could not be graded. `.transitional` reasons may be held
    /// silently through an expected handoff; `.fatal` reasons never are.
    enum Rejection: Equatable {
        case transitional(String)
        case fatal(String)

        var text: String {
            switch self {
            case .transitional(let text), .fatal(let text): return text
            }
        }
    }

    enum Decision: Equatable {
        /// Keep the current drawable; publish nothing.
        case hold
        /// Publish: `nil` means the LUT is active and the graded drawable shows.
        case show(String?)
    }

    private var hasGradedFrame = false
    private var deadline: TimeInterval?
    private var transitionalText: String?

    /// The bounded hold deadline, or nil when nothing is being held.
    var holdDeadline: TimeInterval? { deadline }
    var isHolding: Bool { deadline != nil }
    var hasGradableFrame: Bool { hasGradedFrame }

    /// Leaving the gradeable state (inactive scene, Log mode, or an explicit LUT
    /// change): the previous drawable must not persist and must not be held.
    mutating func invalidate() {
        hasGradedFrame = false
        deadline = nil
        transitionalText = nil
    }

    /// An expected handoff begins (lens switch, source-signature change, or a
    /// suspension). Begins the bounded grace only when nothing good exists to
    /// hold yet; a repeated begin never extends an existing hold.
    mutating func beginHold(at now: TimeInterval) -> Decision {
        guard hasGradedFrame else { return .show(Self.pendingText) }
        if deadline == nil { deadline = now + Self.grace }
        return .hold
    }

    /// The expected handoff completed: restart the bounded grace from here, so
    /// the visible Log-off is bounded from the handoff finishing, not starting.
    mutating func handoffCompleted(at now: TimeInterval) -> Decision {
        guard hasGradedFrame else { return .show(Self.pendingText) }
        if deadline != nil { deadline = now + Self.grace }
        return .hold
    }

    /// A conforming frame was graded and presented.
    mutating func graded(at _: TimeInterval) -> Decision {
        hasGradedFrame = true
        deadline = nil
        transitionalText = nil
        return .show(nil)
    }

    /// The independent source went away (nil frame). Held only while a graded
    /// drawable exists to show; otherwise it is a real, immediate condition.
    mutating func suspended(at now: TimeInterval) -> Decision {
        guard hasGradedFrame else { return .show(Self.sourceUnavailableText) }
        if deadline == nil { deadline = now + Self.grace }
        return .hold
    }

    /// A frame was rejected. A fatal reason is always surfaced; a transitional
    /// reason is held (and remembered for the deadline) only during a live hold.
    mutating func rejected(_ rejection: Rejection, at now: TimeInterval) -> Decision {
        switch rejection {
        case .fatal(let text):
            hasGradedFrame = false
            deadline = nil
            transitionalText = nil
            return .show(text)
        case .transitional(let text):
            if let deadline, now < deadline {
                transitionalText = text
                return .hold
            }
            hasGradedFrame = false
            self.deadline = nil
            transitionalText = nil
            return .show(text)
        }
    }

    /// The bounded deadline was reached (frames stopped, or a rejection arrived
    /// late). Surfaces the last transitional reason, or the source being gone,
    /// as a persistent condition.
    mutating func deadlineReached(at now: TimeInterval) -> Decision {
        guard let deadline, now >= deadline else { return .hold }
        let text = transitionalText ?? Self.sourceUnavailableText
        hasGradedFrame = false
        self.deadline = nil
        transitionalText = nil
        return .show(text)
    }
}
