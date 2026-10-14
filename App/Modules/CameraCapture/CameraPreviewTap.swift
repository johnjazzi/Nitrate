import AVFoundation

/// Retained read-only buffer and connection geometry; no capture attachment writes.
struct CameraPreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let rotationAngle: CGFloat
    let mirrored: Bool
    let stabilized: Bool
}

/// Independent capture delegate. Session controls synchronize on its own serial
/// queue so invalidation follows all old deliveries, without involving the writer.
/// The sink must never synchronously call back into the session queue.
final class CameraPreviewTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "camera.preview.sample-buffer")
    private var owner: UUID?
    private var tap: (@Sendable (CameraPreviewFrame?) -> Void)?
    private var enabled = false
    private var generation: UInt64 = 0
    private var receivedFrame = false
    private var startAfter: CMTime = .invalid

    func set(owner: UUID, tap: @escaping @Sendable (CameraPreviewFrame?) -> Void) {
        queue.sync {
            self.tap?(nil)
            self.owner = owner
            self.tap = tap
        }
    }

    func remove(owner: UUID) {
        queue.sync {
            guard self.owner == owner else { return }
            self.tap?(nil)
            self.owner = nil
            self.tap = nil
            enabled = false
            generation &+= 1
        }
    }

    /// Nil explicitly means the independent source is unavailable; the renderer
    /// invalidates pending GPU presentation and shows the native Log fallback.
    func setEnabled(_ enabled: Bool, startAfter: CMTime = .invalid) {
        queue.sync {
            self.enabled = enabled
            self.startAfter = startAfter
            generation &+= 1
            receivedFrame = false
            tap?(nil)
            guard enabled else { return }
            let current = generation
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.enabled, self.generation == current, !self.receivedFrame else { return }
                self.tap?(nil)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard enabled, let tap, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Capture timestamps use the session clock; reject samples produced
        // before this lens/start/owner generation, including late old callbacks.
        guard timestamp.isValid, timestamp.isNumeric,
              !startAfter.isValid || timestamp >= startAfter else { return }
#if DEBUG
        if !receivedFrame {
            print("Camera preview independent source: " +
                  "buffer=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)), " +
                  "pixel=\(CameraSampleValidationPolicy.fourCCDescription(CVPixelBufferGetPixelFormatType(buffer))), " +
                  "rotation=\(connection.videoRotationAngle), mirrored=\(connection.isVideoMirrored)")
        }
#endif
        receivedFrame = true
#if os(iOS)
        let stabilized = connection.activeVideoStabilizationMode != .off
#else
        let stabilized = false
#endif
        tap(CameraPreviewFrame(buffer: buffer, rotationAngle: connection.videoRotationAngle,
                               mirrored: connection.isVideoMirrored, stabilized: stabilized))
    }
}
