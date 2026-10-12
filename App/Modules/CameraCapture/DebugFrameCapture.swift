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

/// Converts a live Apple Log 2 camera frame into the RGBA-half layout the
/// offline renderer decodes from a recorded clip, so the debug single-frame
/// render feeds pass1 the format it already expects.
///
/// This is a debug convenience, not a calibrated color transform: color
/// management is disabled so the matrix conversion keeps the Apple Log code
/// values (no tone mapping), matching the decoder's behaviour. It is not
/// exercised on the simulator, where no camera exists.
enum DebugFrameConverter {
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull()
    ])

    static func rgbaHalfBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf {
            return pixelBuffer
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary,
                                  &output) == kCVReturnSuccess, let output else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        context.render(image, to: output, bounds: image.extent, colorSpace: nil)
        return output
    }
}
#endif
