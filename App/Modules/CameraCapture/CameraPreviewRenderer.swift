import AVFoundation
import MetalKit

/// Preview-only renderer. Lock protects configuration/admission; GPU resources
/// belong to renderQueue. One retained source frame total, no queued backlog.
final class CameraPreviewRenderer: @unchecked Sendable {
    struct Geometry: Equatable, Sendable {
        var size: CGSize = .zero
        var rotationAngle: CGFloat = 90
        var mirrored = false
        var fill = true
    }

    private struct SourceSignature: Equatable {
        let width: Int
        let height: Int
        let format: UInt32
        let rotation: CGFloat
        let mirrored: Bool
    }

    private struct GPUFrameLease: @unchecked Sendable {
        let frame: CameraPreviewFrame
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
    }

    private struct Uniforms {
        var imageScale: SIMD2<Float>
        var quarterTurns: UInt32
        var mirrored: UInt32
        var fullRange: UInt32
    }

    private let layer: CAMetalLayer
    private let renderQueue = DispatchQueue(label: "camera.preview.metal", qos: .userInitiated)
    private let lock = NSLock()
    private let admission = DispatchSemaphore(value: 1)
    private var active = false
    private var transitioning = false
    private var revision: UInt64 = 0
    private var geometry = Geometry()
    private var selection = CameraPreviewLUTSelection()
    private var lastAdmission: TimeInterval = 0
    private var publishedStatus: String?
    private var sourceSignature: SourceSignature?
    /// Decides whether an expected handoff keeps the last graded drawable or a
    /// real condition is published. Guarded by `lock`; time is injected.
    private var handoff = CameraPreviewHandoffPolicy()
    private var armedDeadline: TimeInterval?
    private var deadlineToken: UInt64 = 0
    private var device: (any MTLDevice)?
    private var commands: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var cache: CVMetalTextureCache?
    private var lut: (any MTLTexture)?
    private var loadedSelection: CameraPreviewLUTSelection?
    private var lutFailure: String?
    private var bundleFiles: [String: URL]?
    private var initializationFailure: String?
    private let status: @MainActor @Sendable (Bool, String?) -> Void

    init(layer: CAMetalLayer, status: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
        self.layer = layer
        self.status = status
        renderQueue.async { [weak self] in self?.initialize() }
    }

    /// Invalidates in-flight presentation before changing modes/geometry/lens.
    /// `transitioning` marks an *expected* lens handoff: the last graded drawable
    /// is held within a bounded grace instead of being replaced by the Log layer.
    @discardableResult
    func configure(active: Bool, transitioning: Bool, geometry: Geometry, selectedLUTName: String? = nil) -> Bool {
        lock.lock()
        let nameChanged = selection.select(selectedLUTName)
        let activeChanged = self.active != active
        let transitionChanged = self.transitioning != transitioning
        let geometryChanged = self.geometry != geometry
        guard activeChanged || transitionChanged || geometryChanged || nameChanged else { lock.unlock(); return false }
        self.active = active
        self.transitioning = transitioning
        self.geometry = geometry
        revision &+= 1
        publishedStatus = nil
        lastAdmission = 0
        let requested = selection
        let now = ProcessInfo.processInfo.systemUptime
        var decision: CameraPreviewHandoffPolicy.Decision?
        if !active || activeChanged || nameChanged {
            // Leaving the active scene, entering Log mode, or choosing a new LUT
            // must never keep the previous drawable.
            handoff.invalidate()
            decision = CameraPreviewHandoffPolicy.Decision.show(
                active ? CameraPreviewHandoffPolicy.pendingText : nil)
        } else if transitionChanged {
            // Only the expected handoff itself is held; a layout/geometry change
            // is not, so it cannot restart or extend the bounded deadline.
            decision = transitioning ? handoff.beginHold(at: now, lensSwitch: true) : handoff.handoffCompleted(at: now)
        }
        let current = revision
        lock.unlock()
        if let decision { apply(decision, revision: current) }
        syncDeadline()
        if nameChanged { renderQueue.async { [weak self] in self?.loadLUT(requested) } }
        return true
    }

    func reset(warning: String = CameraPreviewHandoffPolicy.pendingText) {
        lock.lock()
        revision &+= 1
        publishedStatus = nil
        handoff.invalidate()
        let current = revision
        lock.unlock()
        publish(lutActive: false, warning: warning, revision: current)
        syncDeadline()
    }

    /// Capture queue does only bounded admission and a read-only retain.
    func receive(_ frame: CameraPreviewFrame?) {
        guard let frame else {
            // An expected suspension holds the last graded drawable; only a
            // source with nothing good to show publishes immediately.
            lock.lock()
            guard active else { lock.unlock(); return }
            revision &+= 1
            publishedStatus = nil
            let decision = handoff.suspended(at: ProcessInfo.processInfo.systemUptime)
            let current = revision
            lock.unlock()
            apply(decision, revision: current)
            syncDeadline()
            return
        }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard active, now - lastAdmission >= 1.0 / 30.0,
              admission.wait(timeout: .now()) == .success else { lock.unlock(); return }
        lastAdmission = now
        let signature = SourceSignature(width: CVPixelBufferGetWidth(frame.buffer),
            height: CVPixelBufferGetHeight(frame.buffer), format: CVPixelBufferGetPixelFormatType(frame.buffer),
            rotation: frame.rotationAngle, mirrored: frame.mirrored)
        let sourceChanged = sourceSignature != signature
        if sourceChanged {
            sourceSignature = signature
            revision &+= 1
            publishedStatus = nil
        }
        let current = revision
        let snapshot = geometry
        let selected = selection
        // A source-signature change during a handoff is expected: invalidate the
        // in-flight presentation but hold the good drawable and publish nothing.
        let decision = sourceChanged ? handoff.beginHold(at: now) : nil
        lock.unlock()
        if let decision { apply(decision, revision: current) }
        syncDeadline()
        renderQueue.async { [self] in render(frame, geometry: snapshot, selected: selected, revision: current) }
    }

    /// Publishes a frame-level failure, holding only while a bounded handoff is
    /// live; a fatal reason is surfaced immediately.
    private func reject(_ rejection: CameraPreviewHandoffPolicy.Rejection, revision current: UInt64) {
        lock.lock()
        guard active, revision == current else { lock.unlock(); return }
        let decision = handoff.rejected(rejection, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        apply(decision, revision: current)
        syncDeadline()
    }

    /// Publishes a successfully graded frame and clears any held handoff.
    private func graded(revision current: UInt64) {
        lock.lock()
        guard active, revision == current else { lock.unlock(); return }
        let decision = handoff.graded(at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        apply(decision, revision: current)
        syncDeadline()
    }

    private func apply(_ decision: CameraPreviewHandoffPolicy.Decision, revision current: UInt64) {
        switch decision {
        case .hold:
            // Keep the graded layer active (never `lutActive: false`) and publish
            // an informational notice so a retained frame is explained rather
            // than silently frozen. The notice is never error-styled here.
            publish(lutActive: true, warning: handoffNotice(), revision: current)
        case .show(let warning):
            publish(lutActive: warning == nil, warning: warning, revision: current)
        }
    }

    /// The live hold's informational notice, read under the lock that guards the
    /// policy. Nil when nothing is held.
    private func handoffNotice() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return handoff.notice
    }

    /// Arms the single bounded deadline for the current hold. Only the newest arm
    /// fires, so a rapid transition cannot leave a stale callback behind.
    private func syncDeadline() {
        lock.lock()
        // Read the live policy under the same lock. Passing a snapshot from a
        // previous event could cancel a newer hold when capture and GPU race.
        let deadline = handoff.holdDeadline
        guard armedDeadline != deadline else { lock.unlock(); return }
        armedDeadline = deadline
        deadlineToken &+= 1
        guard let deadline else { lock.unlock(); return }
        let token = deadlineToken
        lock.unlock()
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deadlineFired(token)
        }
    }

    private func deadlineFired(_ token: UInt64) {
        lock.lock()
        guard token == deadlineToken else { lock.unlock(); return }
        // Consume this arm before checking the injected-clock policy. If clock
        // rounding makes it early, syncDeadline schedules the remaining delay.
        armedDeadline = nil
        let decision = handoff.deadlineReached(at: ProcessInfo.processInfo.systemUptime)
        let current = revision
        let stillActive = active
        lock.unlock()
        guard stillActive else { return }
        apply(decision, revision: current)
        syncDeadline()
    }

    private func isCurrent(_ current: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && revision == current
    }

    private func isCurrentStatus(_ key: String, revision current: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && revision == current && publishedStatus == key
    }

    private func publish(lutActive: Bool, warning: String?, revision current: UInt64) {
        // The key includes the notice so active -> holding -> active each
        // delivers: the informational hold notice is distinct from both the
        // graded state and the error/log states.
        let key = (lutActive ? "active:" : "log:") + (warning ?? "")
        lock.lock()
        guard active, revision == current, publishedStatus != key else { lock.unlock(); return }
        // A queued notice must not restore the graded layer after a newer
        // failure, nor replace recovery with an already-cleared hold message.
        guard !lutActive || (handoff.hasGradableFrame && handoff.notice == warning) else {
            lock.unlock()
            return
        }
        publishedStatus = key
        let selectedName = selection.name ?? "none"
        lock.unlock()
#if DEBUG
        print("Camera preview: \(lutActive ? "Preview LUT active [\(selectedName)]" : warning ?? "Log")")
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentStatus(key, revision: current) else { return }
            MainActor.assumeIsolated { self.status(lutActive, warning) }
        }
    }

    private func initialize() {
        do {
            guard let device = layer.device, let commands = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "cameraPreviewVertex"),
                  let fragment = library.makeFunction(name: "cameraPreviewFragment") else {
                throw PreviewError.unavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
                throw PreviewError.unavailable
            }
            self.device = device
            self.commands = commands
            self.cache = cache
            // Preview LUT resources load separately, only when the selected filename changes.
        } catch {
            initializationFailure = "Preview LUT unavailable — showing Log"
        }
    }

    private func render(_ frame: CameraPreviewFrame, geometry: Geometry, selected: CameraPreviewLUTSelection, revision current: UInt64) {
        var committed = false
        defer { if !committed { admission.signal() } }
        guard isCurrent(current) else { return }
        guard initializationFailure == nil, let commands, let pipeline, let cache, let lut,
              selected.name != nil, loadedSelection == selected else {
            reject(.fatal(initializationFailure ?? lutFailure ?? "Preview LUT missing selection — showing Log"),
                   revision: current)
            return
        }
        let buffer = frame.buffer
        // Recording stabilization can crop/warp the data-output image independently
        // of the native preview. Do not misregister focus/metering over that source.
        guard !frame.stabilized else {
            reject(.fatal("Preview LUT unavailable with recording stabilization — showing Log"), revision: current)
            return
        }
        guard #available(iOS 26.0, *),
              CameraSampleValidationPolicy.isAppleLog2(
                CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) as? String),
              CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String == "ITU_R_2020",
              Self.unspecifiedAttachment(buffer, key: kCVImageBufferColorPrimariesKey),
              Self.unspecifiedAttachment(buffer, key: kCVImageBufferTransferFunctionKey),
              let format = CameraPreviewPolicy.format(CVPixelBufferGetPixelFormatType(buffer)),
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            // A non-conforming frame is never graded. During an expected handoff
            // it may be a superseded transitional frame, so it is held silently;
            // otherwise it is a real, persistent condition.
            reject(.transitional("Preview LUT unsupported for this source — showing Log"), revision: current)
            return
        }
        let turns = (Int(((geometry.rotationAngle - frame.rotationAngle) / 90).rounded()) % 4 + 4) % 4
        let scale = CameraPreviewPolicy.imageScale(
            sourceWidth: Float(CVPixelBufferGetWidth(buffer)), sourceHeight: Float(CVPixelBufferGetHeight(buffer)),
            viewWidth: Float(geometry.size.width), viewHeight: Float(geometry.size.height), quarterTurns: turns, fill: geometry.fill)
        guard scale.x > 0, scale.y > 0 else { return }
        var yRef: CVMetalTexture?
        var cRef: CVMetalTexture?
        let yResult = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .r16Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &yRef)
        let cResult = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .rg16Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &cRef)
        guard yResult == kCVReturnSuccess, cResult == kCVReturnSuccess,
              let yRef, let cRef, let y = CVMetalTextureGetTexture(yRef), let c = CVMetalTextureGetTexture(cRef),
              let drawable = layer.nextDrawable(), let command = commands.makeCommandBuffer() else {
            reject(.fatal("Preview LUT rendering unavailable — showing Log"), revision: current)
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            reject(.fatal("Preview LUT rendering unavailable — showing Log"), revision: current)
            return
        }
        var uniforms = Uniforms(imageScale: scale, quarterTurns: UInt32(turns),
                                mirrored: geometry.mirrored != frame.mirrored ? 1 : 0, fullRange: format.fullRange ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(y, index: 0)
        encoder.setFragmentTexture(c, index: 1)
        encoder.setFragmentTexture(lut, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        guard isCurrent(current) else { return }
        command.present(drawable)
        let lease = GPUFrameLease(frame: frame, luma: yRef, chroma: cRef)
        command.addCompletedHandler { [self, lease] completed in
            // Explicit ownership through GPU completion, including CV texture wrappers.
            withExtendedLifetime(lease) {}
            if completed.status == .completed {
                graded(revision: current)
            } else {
                reject(.fatal("Preview LUT GPU error — showing Log"), revision: current)
            }
            admission.signal()
        }
        committed = true
        command.commit()
    }

    private static func unspecifiedAttachment(_ buffer: CVPixelBuffer, key: CFString) -> Bool {
        let value = CVBufferCopyAttachment(buffer, key, nil) as? String
        return value == nil || value == "Unspecified"
    }

    private func isSelected(_ requested: CameraPreviewLUTSelection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return selection == requested
    }

    /// Queue-owned lookup/load; obsolete selections cannot publish a late result.
    private func loadLUT(_ requested: CameraPreviewLUTSelection) {
        guard isSelected(requested) else { return }
        lut = nil
        loadedSelection = nil
        lutFailure = "Preview LUT missing selection — showing Log"
        guard let name = requested.name, !name.isEmpty, let device else { return }
        do {
            guard let url = findBundleFile(named: name) else { throw PreviewError.unavailable }
            let cube = try CameraPreviewCube.parse(String(contentsOf: url, encoding: .utf8))
            let texture = try Self.makeLUT(cube, device: device)
            lock.lock()
            defer { lock.unlock() }
            guard selection == requested else { return }
            lut = texture
            loadedSelection = requested
            lutFailure = nil
        } catch {
            lock.lock()
            defer { lock.unlock() }
            guard selection == requested else { return }
            lutFailure = "Preview LUT unavailable or invalid — showing Log"
        }
    }

    /// Root and LUT folder references first; build the recursive fallback index once.
    /// No bundle lookup, disk read, or LUT allocation runs in the per-frame path.
    private func findBundleFile(named filename: String) -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: filename, withExtension: nil) { return url }
        if let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "LUTs") { return url }
        if let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "Preview") { return url }
        if bundleFiles == nil {
            var files: [String: URL] = [:]
            if let root = bundle.resourceURL,
               let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                while let url = enumerator.nextObject() as? URL {
                    if files[url.lastPathComponent] == nil { files[url.lastPathComponent] = url }
                }
            }
            bundleFiles = files
        }
        return bundleFiles?[filename]
    }

    /// Same direct RGB/red-fastest RGBA32Float upload as PipelineRenderer.
    private static func makeLUT(_ cube: CameraPreviewCube, device: any MTLDevice) throws -> any MTLTexture {
        let size = cube.size
        let values = cube.rgba
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw PreviewError.unavailable }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                bytesPerImage: size * size * 4 * MemoryLayout<Float>.size)
        }
        return texture
    }

    private enum PreviewError: Error { case unavailable }
}
