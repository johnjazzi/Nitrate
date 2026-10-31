import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CameraPhotoCaptureResult: Sendable {
    let dngURL: URL?
    let evidence: [String: String]
    let failure: String?
    let timedOut: Bool
}

/// Retained by the session owner until the framework's terminal callback.
final class CameraPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let output: AVCapturePhotoOutput
    private let pixelFormat: OSType
    private let requestedDimensions: CMVideoDimensions
    private let directory: URL
    private let queue: DispatchQueue
    /// Quarter-turn frozen at the shutter tap. Applied to the photo connection
    /// immediately before the request, because that is what the DNG's EXIF
    /// orientation — and therefore the decoded still — follows.
    private let rotationAngle: CGFloat?
    private let onTerminal: @Sendable (CameraPhotoCaptureResult) -> Void
    private let timeoutInterval: TimeInterval
    private var settings: AVCapturePhotoSettings?
    private var transaction: PhotoCaptureTransactionState?
    private var evidence: [String: String] = [:]
    private var failure: String?
    private var dngURL: URL?
    private var terminalDelivered = false
    private var started = false
    private var frameworkTerminated = false
    private var completionBarrier = PhotoCompletionBarrier(waitingFor: [.rawProcessed, .captureTerminated])
    private let deliveryLock = NSLock()
    private var pendingProcessing = 0

    init(output: AVCapturePhotoOutput, pixelFormat: OSType,
         dimensions: CMVideoDimensions, directory: URL, queue: DispatchQueue,
         rotationAngle: CGFloat? = nil,
         timeoutInterval: TimeInterval = PhotoExposureCadence.captureTransactionTimeout,
         onTerminal: @escaping @Sendable (CameraPhotoCaptureResult) -> Void) throws {
        guard timeoutInterval.isFinite, timeoutInterval > 0 else { throw CaptureError.invalidSettings }
        self.timeoutInterval = timeoutInterval
        self.output = output
        self.pixelFormat = pixelFormat
        self.requestedDimensions = dimensions
        self.directory = directory
        self.queue = queue
        self.rotationAngle = rotationAngle
        self.onTerminal = onTerminal
        super.init()

        let formats = output.availableRawPhotoPixelFormatTypes
        guard formats.contains(pixelFormat),
              AVCapturePhotoOutput.isBayerRAWPixelFormat(pixelFormat),
              output.availableRawPhotoFileTypes.contains(AVFileType.dng) else {
            throw CaptureError.unsupportedRawFormat
        }
        let requested = PhotoCapturePolicy.Dimensions(width: Int(dimensions.width), height: Int(dimensions.height))
        guard PhotoCapturePolicy.permitsActualDimensions(requested) else { throw CaptureError.invalidDimensions }
        guard output.maxPhotoDimensions.width >= dimensions.width,
              output.maxPhotoDimensions.height >= dimensions.height else { throw CaptureError.unsupportedDimensions }
        let raw = AVCapturePhotoSettings(rawPixelFormatType: pixelFormat, rawFileType: .dng,
                                        processedFormat: nil, processedFileType: nil)
        raw.photoQualityPrioritization = .speed
        raw.maxPhotoDimensions = dimensions
        guard raw.maxPhotoDimensions.width == dimensions.width,
              raw.maxPhotoDimensions.height == dimensions.height,
              raw.photoQualityPrioritization == .speed,
              raw.rawPhotoPixelFormatType == pixelFormat, raw.rawFileType == .dng else { throw CaptureError.invalidSettings }
        settings = raw
        transaction = PhotoCaptureTransactionState(uniqueID: raw.uniqueID)
        evidence = ["status": "prepared", "rawPixelFormat": String(pixelFormat),
                    "requestedWidth": String(dimensions.width), "requestedHeight": String(dimensions.height),
                    "qualityPrioritization": "speed", "transactionID": String(raw.uniqueID),
                    "exposure": "unrecorded", "iso": "unrecorded", "whiteBalance": "unrecorded",
                    "orientation": "unrecorded", "rawType": "Bayer", "fileType": "DNG"]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeManifest()
    }

    func start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !started, let settings, let transaction, transaction.isInFlight else {
            throw CaptureError.alreadyStarted
        }
        evidence["status"] = "capturing"
        try writeManifest()
        started = true
        let requestID = settings.uniqueID
        queue.asyncAfter(deadline: .now() + timeoutInterval) { [weak self] in
            guard let self, var state = self.transaction else { return }
            guard state.uniqueID == requestID else { return }
            switch state.timeout() {
            case .markedFailed:
                self.failure = self.failure ?? "capture timed out awaiting framework terminal callback"
                self.evidence["status"] = "timedOutAwaitingTerminal"
                self.evidence["timedOut"] = "true"
                self.transaction = state
                self.recordManifest()
                // The framework's terminal callback is normally last. When it never
                // arrives the transaction is closed here instead: `finishIfReady`
                // waits for `frameworkTerminated`, so a dropped terminal would hold
                // `capturing` for the rest of the session and leave the shutter dead
                // with nothing said.
                self.finishAfterTimeout()
            case .alreadyFailed, .terminal: break
            }
        }
        applyCaptureRotation()
        recordManifest()
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Install the frozen quarter-turn on the photo connection, then record what
    /// was asked for, what is actually installed, and whether it is supported.
    ///
    /// This must run immediately before the request: `AVCapturePhotoOutput` bakes
    /// the connection angle into the DNG's EXIF orientation, so a value applied
    /// at any other moment describes a different hold.
    private func applyCaptureRotation() {
        let requested = PhotoCaptureRotationPolicy.connectionAngle(rotationAngle)
        guard let requested, let connection = output.connection(with: .video) else {
            evidence.merge(PhotoCaptureRotationPolicy.evidence(
                requested: requested, applied: nil, supported: nil)) { _, new in new }
            return
        }
        guard #available(iOS 17.0, *) else {
            evidence.merge(PhotoCaptureRotationPolicy.evidence(
                requested: requested, applied: nil, supported: nil)) { _, new in new }
            return
        }
        let supported = connection.isVideoRotationAngleSupported(requested)
        if supported { connection.videoRotationAngle = requested }
        evidence.merge(PhotoCaptureRotationPolicy.evidence(
            requested: requested, applied: connection.videoRotationAngle,
            supported: supported)) { _, new in new }
#if DEBUG
        print("Camera photo orientation: requested=\(requested)°, " +
              "supported=\(supported), applied=\(connection.videoRotationAngle)°")
#endif
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        deliveryLock.withLock { pendingProcessing += 1 }
        let id = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        let isRaw = photo.isRawPhoto
        let dimensions = photo.pixelBuffer.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
        let resolved = photo.resolvedSettings.rawPhotoDimensions
        let rawDimensions = PhotoCapturePolicy.Dimensions(width: Int(resolved.width), height: Int(resolved.height))
        let actualPixelFormat = photo.pixelBuffer.map { CVPixelBufferGetPixelFormatType($0) }
        let metadata = Self.captureMetadata(photo.metadata)
        let errorText = error.map { String(describing: $0) }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.processingSettled() }
            guard self.accept(id) else { return }
            self.evidence.merge(metadata) { _, measured in measured }
            self.evidence["resolvedRawWidth"] = String(rawDimensions.width)
            self.evidence["resolvedRawHeight"] = String(rawDimensions.height)
            if let errorText { self.failure = self.failure ?? "photo processing failed: \(errorText)" }
            guard isRaw else { self.failure = self.failure ?? "callback was not RAW"; self.recordManifest(); return }
            guard let data, !data.isEmpty else {
                self.failure = self.failure ?? "missing DNG representation"
                self.evidence["dng"] = "missing"
                self.recordManifest(); return
            }
            do {
                let url = self.directory.appendingPathComponent("capture.dng")
                try data.write(to: url, options: .atomic)
                self.evidence["dng"] = "capture.dng"
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) > 0,
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int else { throw CaptureError.invalidDNG }
                let actual = PhotoCapturePolicy.Dimensions(width: w, height: h)
                guard PhotoCapturePolicy.permitsActualDimensions(actual),
                      PhotoCapturePolicy.permitsActualDimensions(rawDimensions) else { throw CaptureError.oversizedDNG }
                guard actual == rawDimensions else { throw CaptureError.invalidDNG }
                guard let fileType = CGImageSourceGetType(source),
                      let type = UTType(fileType as String), type.conforms(to: .rawImage) else {
                    throw CaptureError.invalidDNG
                }
                self.evidence["actualFileType"] = fileType as String
                if let actualPixelFormat {
                    self.evidence["actualRawPixelFormat"] = String(actualPixelFormat)
                    guard AVCapturePhotoOutput.isBayerRAWPixelFormat(actualPixelFormat) else {
                        throw CaptureError.unsupportedRawFormat
                    }
                }
                if let neutral = (props[kCGImagePropertyDNGDictionary] as? [CFString: Any])?[kCGImagePropertyDNGAsShotNeutral]
                    as? [NSNumber], neutral.count == 3, neutral.allSatisfy({ $0.doubleValue.isFinite }) {
                    self.evidence["asShotNeutral"] = neutral.map { String($0.doubleValue) }.joined(separator: ",")
                }
                if let dimensions {
                    self.evidence["pixelBufferWidth"] = String(dimensions.0)
                    self.evidence["pixelBufferHeight"] = String(dimensions.1)
                    let storage = PhotoCapturePolicy.Dimensions(width: dimensions.0, height: dimensions.1)
                    guard PhotoCapturePolicy.permitsBayerStorage(storage, usable: actual) else {
                        throw CaptureError.invalidDNG
                    }
                    if let area = (props[kCGImagePropertyDNGDictionary] as? [CFString: Any])?[kCGImagePropertyDNGActiveArea]
                        as? [NSNumber] {
                        guard area.count == 4 else { throw CaptureError.invalidDNG }
                        self.evidence["activeArea"] = area.map { $0.stringValue }.joined(separator: ",")
                        let bounds = area.map(\.intValue)
                        guard bounds[0] >= 0, bounds[1] >= 0,
                              bounds[2] <= storage.height, bounds[3] <= storage.width,
                              bounds[2] - bounds[0] == actual.height,
                              bounds[3] - bounds[1] == actual.width else { throw CaptureError.invalidDNG }
                    } else {
                        // Unpadded front-camera Bayer DNGs omit the optional ActiveArea tag.
                        // Padded storage still requires explicit, validated usable bounds.
                        guard storage == actual else { throw CaptureError.invalidDNG }
                        self.evidence["activeArea"] = "fullBuffer"
                    }
                }
                self.evidence["rawWidth"] = String(w); self.evidence["rawHeight"] = String(h)
                self.evidence["dngBytes"] = String((attrs[.size] as? NSNumber)?.intValue ?? 0)
                self.evidence["dngReadable"] = "true"
                self.dngURL = url
            } catch {
                self.failure = self.failure ?? "DNG validation failed: \(error)"
                self.evidence["dngReadable"] = "false"
            }
            self.evidence["status"] = "photoProcessed"
            self.recordManifest()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let id = resolvedSettings.uniqueID
        let errorText = error.map { String(describing: $0) }
        queue.async { [weak self] in
            guard let self, let state = self.transaction, state.uniqueID == id,
                  state.isInFlight, !self.frameworkTerminated else { return }
            self.frameworkTerminated = true
            if let errorText { self.failure = self.failure ?? "capture failed: \(errorText)" }
            self.evidence["terminalReceived"] = "true"
            self.completionBarrier.complete(.captureTerminated)
            // The framework terminal callback is last. Account for processing
            // callbacks that already entered but are still extracting/persisting data.
            if !self.hasPendingProcessing { self.completionBarrier.complete(.rawProcessed) }
            self.finishIfReady()
        }
    }

    private var hasPendingProcessing: Bool { deliveryLock.withLock { pendingProcessing > 0 } }

    private func processingSettled() {
        let settled = deliveryLock.withLock { pendingProcessing -= 1; return pendingProcessing == 0 }
        if settled { completionBarrier.complete(.rawProcessed) }
        finishIfReady()
    }

    private func finishIfReady() {
        guard frameworkTerminated, !hasPendingProcessing, completionBarrier.isReady,
              !terminalDelivered, var state = transaction else { return }
        guard state.finish(uniqueID: state.uniqueID) else { return }
        transaction = state
        if dngURL == nil { failure = failure ?? "terminal callback without validated DNG" }
        evidence["status"] = failure == nil ? "complete" : "failed"
        recordManifest()
        terminalDelivered = true
        onTerminal(CameraPhotoCaptureResult(dngURL: failure == nil ? dngURL : nil,
            evidence: evidence, failure: failure, timedOut: state.timedOut))
    }

    /// Close a timed-out transaction without the framework's terminal callback.
    private func finishAfterTimeout() {
        guard !terminalDelivered, var state = transaction, state.timedOut else { return }
        guard state.finish(uniqueID: state.uniqueID) else { return }
        transaction = state
        frameworkTerminated = true
        completionBarrier.complete(.rawProcessed)
        completionBarrier.complete(.captureTerminated)
        failure = failure ?? "capture timed out awaiting framework terminal callback"
        evidence["status"] = "timedOutAwaitingTerminal"
        recordManifest()
        terminalDelivered = true
        onTerminal(CameraPhotoCaptureResult(dngURL: nil, evidence: evidence,
                                            failure: failure, timedOut: true))
    }

    private static func captureMetadata(_ metadata: [String: Any]) -> [String: String] {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var result: [String: String] = [:]
        for (name, value) in [("exposure", exif[kCGImagePropertyExifExposureTime as String]),
                              ("whiteBalance", exif[kCGImagePropertyExifWhiteBalance as String]),
                              ("orientation", metadata[kCGImagePropertyOrientation as String])] {
            if let number = value as? NSNumber, number.doubleValue.isFinite {
                result[name] = String(number.doubleValue)
            }
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first,
           iso.doubleValue.isFinite { result["iso"] = String(iso.doubleValue) }
        return result
    }

    private func accept(_ id: Int64) -> Bool {
        guard var state = transaction else { return false }
        let disposition = state.acceptCallback(uniqueID: id)
        guard disposition == .accepted else { return false }
        transaction = state
        return true
    }

    private func recordManifest() {
        do { try writeManifest() }
        catch { failure = failure ?? "capture manifest persistence failed: \(error)" }
    }

    private func writeManifest() throws {
        let allowed = Set(["status", "rawPixelFormat", "requestedWidth", "requestedHeight", "qualityPrioritization",
                           "transactionID", "timedOut", "terminalReceived", "dng", "exposure", "iso",
                           "whiteBalance", "orientation", "rawType", "fileType", "rawWidth", "rawHeight",
                           "pixelBufferWidth", "pixelBufferHeight", "dngBytes", "dngReadable",
                           "resolvedRawWidth", "resolvedRawHeight", "actualFileType", "actualRawPixelFormat",
                           "asShotNeutral", "activeArea", "rotationAngleRequested", "rotationAngleApplied",
                           "rotationAngleSupported"])
        var manifest = evidence.filter { allowed.contains($0.key) }
        if let failure { manifest["failure"] = String(failure.prefix(240)) }
        if manifest["dng"] == nil { manifest["dng"] = dngURL == nil ? "missing" : "capture.dng" }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        guard data.count <= 4096 else { throw CaptureError.manifestTooLarge }
        try data.write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
    }

    private enum CaptureError: Error {
        case unsupportedRawFormat, invalidDimensions, unsupportedDimensions, invalidSettings, invalidDNG, oversizedDNG
        case alreadyStarted, manifestTooLarge
    }
}
