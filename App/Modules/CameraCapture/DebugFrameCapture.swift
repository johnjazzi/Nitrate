#if DEBUG
import AVFoundation
import CoreImage
import CoreVideo

/// Debug-only single-frame capture support.
///
/// The live camera path is deliberately kept out of the render pipeline: the
/// recorder owns `AVCaptureVideoDataOutput` and its delegate, so the debug tap
/// uses its *own* video output and delegate instead of adding a second delegate
/// to the recorder's. Everything here is compiled only in DEBUG builds, so the
/// shipping capture path carries none of it.

/// Keeps the most recent frame from the debug tap until a capture asks for one.
/// The handler is consumed on the first frame, so a request never keeps a stale
/// buffer alive.
final class CameraDebugFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CVPixelBuffer) -> Void)?

    /// Register a one-shot handler for the next delivered frame.
    func request(_ handler: @escaping (CVPixelBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        guard let handler, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(buffer)
    }
}

/// `@unchecked Sendable` box for handing a captured frame across an actor hop.
/// The frame is only read after the producing queue has finished with it.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer?
}

/// `@unchecked Sendable` box for a plain completion, so a nonisolated capture
/// callback can hand it back to the main thread without Sendable friction.
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One-shot guard so the frame callback and the timeout cannot both complete a
/// single debug capture.
final class CameraDebugFrameRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    /// Returns true exactly once, for whichever caller finishes first.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

/// Convert a processed camera snapshot to the video renderer's Apple Wide
/// Gamut / Apple Log 2 input, using the capture owner's active color-space
/// snapshot. SDR idle is intentional; it must be decoded, not relabeled Log.
/// This adapter does not turn processed camera pixels into a captured RAW Photo.
enum DebugFrameConverter {
    @available(iOS 26.0, *)
    static func rgbaHalfBuffer(from pixelBuffer: CVPixelBuffer,
                               sourceColorSpace: AVCaptureColorSpace = .appleLog2) -> CVPixelBuffer? {
        let source: DebugFrameSourceAdapter.SourceColorSpace
        switch sourceColorSpace {
        case .appleLog2: source = .appleLog2
        case .sRGB: source = .sRGB
        case .P3_D65: source = .displayP3
        // Apple Log 1, HLG, and future spaces need their own explicit adapter.
        // Never infer transfer/primaries from 8-bit, 10-bit, or half storage.
        default: return nil
        }
        return DebugFrameSourceAdapter.rgbaHalfBuffer(from: pixelBuffer, sourceColorSpace: source)
    }
}
#endif
