import SwiftUI
import AVFoundation
import MetalKit

/// Clean camera preview only — controls live in ContentView.
struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: CameraViewModel
    @State private var previewLayer: AVCaptureVideoPreviewLayer?
    @AppStorage(CameraPreviewMode.preferenceKey) private var previewMode = CameraPreviewMode.neutral.rawValue
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var selectedStockLUTName: String? = nil

    var body: some View {
        CameraPreviewRepresentable(previewLayer: $previewLayer, camera: viewModel.session,
                                   videoGravity: videoGravity, mode: .resolved(previewMode),
                                   active: scenePhase == .active,
                                   transitioning: viewModel.isSwitchingCameraLens,
                                   lens: viewModel.activeLens, selectedStockLUTName: selectedStockLUTName)
            .overlay {
                // Where exposure is metered. Hidden during a take so it never
                // draws over the recording.
                if !viewModel.isRecording {
                    MeteringBoxView(point: viewModel.meteringPoint,
                                    isManual: viewModel.isManualExposure)
                }
            }
            .onTapGesture { location in
                guard let layer = previewLayer else { return }
                viewModel.handleFocusTap(at: location, in: layer)
                let previewSize = layer.bounds.size
                if previewSize.width > 0, previewSize.height > 0 {
                    viewModel.setMeteringPoint(CGPoint(x: location.x / previewSize.width,
                                                       y: location.y / previewSize.height))
                }
            }
            .onAppear {
                if scenePhase == .active { viewModel.onAppear() }
                else { viewModel.onSceneInactive() }
            }
            .onDisappear { viewModel.onDisappear() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.onSceneActive()
                } else {
                    viewModel.onSceneInactive()
                }
            }
    }
}

// MARK: - UIViewRepresentable

private struct CameraPreviewRepresentable: UIViewRepresentable {
    @Binding var previewLayer: AVCaptureVideoPreviewLayer?
    let camera: CameraSession
    let videoGravity: AVLayerVideoGravity
    let mode: CameraPreviewMode
    let active: Bool
    let transitioning: Bool
    let lens: CameraLens
    let selectedStockLUTName: String?

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(camera: camera)
        let layer = view.previewLayer
        layer.videoGravity = videoGravity
        DispatchQueue.main.async {
            previewLayer = layer
            // The layer's connection does not exist until the session is
            // running, so the per-camera rotation is applied here.
            view.updatePreviewRotation(for: camera.activeLens)
            view.setNeedsLayout()
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = videoGravity
        uiView.update(mode: mode, active: active, transitioning: transitioning, lens: lens,
                      selectedStockLUTName: selectedStockLUTName)
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.detach()
    }
}

/// SwiftUI may update before UIKit has applied the new bounds. Resize the
/// existing preview layer during layout, never recreate it for a mode change.
private final class CameraPreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let camera: CameraSession
    private let metalView = MTKView(frame: .zero)
    private let monitorLabel = UILabel()
    private let handoffLabel = UILabel()
    private let owner = UUID()
    private var renderer: CameraPreviewRenderer?
    private var wantsLUT = false
    private var transitioning = false
    private var attached = false
    private var activeLens: CameraLens?
    private var resolvedLUTName: String?
#if DEBUG
    private var diagnosticGeometry = ""
    private var reportedPreviewRotation = ""
#endif
    private var previewRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var previewRotationLens: CameraLens?
    private var previewRotationConnection: AVCaptureConnection?

    init(camera: CameraSession) {
        self.camera = camera
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.isPaused = true
        metalView.autoResizeDrawable = false
        metalView.enableSetNeedsDisplay = false
        metalView.isUserInteractionEnabled = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isHidden = true
        addSubview(metalView)
        monitorLabel.font = NitrateTypography.uiFont(size: NitrateTypography.baseSize(for: .caption2),
                                                     relativeTo: .caption2)
        monitorLabel.adjustsFontForContentSizeCategory = true
        monitorLabel.textColor = .white
        monitorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        monitorLabel.numberOfLines = 2
        monitorLabel.isUserInteractionEnabled = false
        addSubview(monitorLabel)
        handoffLabel.font = NitrateTypography.uiFont(size: 46)
        handoffLabel.adjustsFontForContentSizeCategory = true
        handoffLabel.textColor = .white
        handoffLabel.textAlignment = .center
        handoffLabel.backgroundColor = .clear
        handoffLabel.numberOfLines = 1
        handoffLabel.adjustsFontSizeToFitWidth = true
        handoffLabel.minimumScaleFactor = 0.4
        handoffLabel.isUserInteractionEnabled = false
        handoffLabel.isHidden = true
        handoffLabel.shadowColor = UIColor.black.withAlphaComponent(0.65)
        handoffLabel.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(handoffLabel)
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            metalLayer.framebufferOnly = true
            renderer = CameraPreviewRenderer(layer: metalLayer) { [weak self] lutActive, warning in
                guard let self, self.wantsLUT else { return }
                self.metalView.isHidden = !lutActive
                self.handoffLabel.text = lutActive ? warning : nil
                self.handoffLabel.isHidden = !lutActive || warning == nil
                self.monitorLabel.text = lutActive ? nil : warning
                self.monitorLabel.isHidden = lutActive || warning == nil
                self.setNeedsLayout()
            }
        }
    }

    func update(mode: CameraPreviewMode, active: Bool, transitioning: Bool, lens: CameraLens,
                selectedStockLUTName: String?) {
        let requested = mode != .log && active
        let lutName = mode.lutName(for: selectedStockLUTName)
        let selectionChanged = resolvedLUTName != lutName
        let requestedChanged = wantsLUT != requested
        self.transitioning = transitioning
        if requestedChanged || selectionChanged {
            handoffLabel.isHidden = true
            // An explicit display change — Log mode, the scene leaving, or a new
            // LUT choice — must never keep a stale graded frame.
            metalView.isHidden = true
            monitorLabel.text = requested ? "Preview LUT pending — showing Log" : nil
            monitorLabel.isHidden = !requested
            renderer?.reset()
        }
        // A lens handoff is *expected*: the renderer holds its last graded
        // drawable within a bounded grace rather than flashing the Log layer.
        wantsLUT = requested
        activeLens = lens
        resolvedLUTName = lutName
        updatePreviewRotation(for: lens)
        updateRendererGeometry()
        refreshSink()
    }

    private func refreshSink() {
        let shouldAttach = wantsLUT && window != nil && renderer != nil
        guard shouldAttach != attached else { return }
        attached = shouldAttach
        if shouldAttach, let renderer {
            camera.setPreviewTap(owner: owner) { [weak renderer] in renderer?.receive($0) }
        } else {
            camera.removePreviewTap(owner: owner)
            metalView.isHidden = true
        }
    }

    func detach() {
        wantsLUT = false
        handoffLabel.isHidden = true
        // The coordinator holds a weak layer reference; drop the observation and
        // the remembered lens so a re-attach rebuilds both.
        previewRotationObservation = nil
        previewRotationCoordinator = nil
        previewRotationLens = nil
        previewRotationConnection = nil
        renderer?.configure(active: wantsLUT && window != nil, transitioning: transitioning, geometry: .init(),
                            selectedLUTName: resolvedLUTName)
        camera.removePreviewTap(owner: owner)
        attached = false
        metalView.isHidden = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        if let activeLens { updatePreviewRotation(for: activeLens) }
        updateRendererGeometry()
        refreshSink()
    }

    private func updateRendererGeometry() {
        let connection = previewLayer.connection
        let geometry = CameraPreviewRenderer.Geometry(size: bounds.size,
            rotationAngle: connection?.videoRotationAngle ?? CameraPreviewRotationPolicy.fallbackAngle,
            mirrored: connection?.isVideoMirrored ?? false,
            fill: previewLayer.videoGravity == .resizeAspectFill)
        // The renderer decides whether to keep its last graded drawable (a
        // bounded, expected handoff) or surface a real condition; the view never
        // synchronously hides it here.
        renderer?.configure(active: wantsLUT && window != nil, transitioning: transitioning,
                            geometry: geometry, selectedLUTName: resolvedLUTName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The preview layer's rotation follows the platform's per-camera
    /// horizon-level angle. A fixed 90° is right for the rear camera and a
    /// quarter turn out for the front: the front camera's native data-output
    /// buffer is already portrait-sized, and its coordinator angle is 0° in a
    /// portrait hold (measured on device: applied 90° against platform 0°).
    fileprivate func updatePreviewRotation(for lens: CameraLens) {
        if previewRotationLens != lens {
            observePreviewRotation(for: lens)
        }
        // A lens switch re-creates the layer's connection, so re-apply.
        guard previewLayer.connection !== previewRotationConnection else { return }
        applyPreviewRotation()
    }

    private func observePreviewRotation(for lens: CameraLens) {
        previewRotationObservation = nil
        previewRotationCoordinator = nil
        previewRotationLens = lens
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position) else {
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        // Updates arrive on the main queue. Dropping the previous observation
        // keeps a lens switch from resurrecting the old camera's angle.
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                         options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.applyPreviewRotation(change.newValue) }
        }
        previewRotationCoordinator = coordinator
    }

    /// Nil asks the coordinator itself; the fallback is the previous fixed 90°.
    private func applyPreviewRotation(_ platformAngle: CGFloat? = nil) {
        guard let connection = previewLayer.connection else { return }
        let coordinator = previewRotationCoordinator
        let requested = CameraPreviewRotationPolicy.angle(
            platformAngle: platformAngle ?? coordinator?.videoRotationAngleForHorizonLevelPreview)
        guard connection.isVideoRotationAngleSupported(requested) else { return }
        previewRotationConnection = connection
        if connection.videoRotationAngle != requested {
            connection.videoRotationAngle = requested
            // The stock-LUT preview derives its geometry from this angle.
            updateRendererGeometry()
        }
        logPreviewRotation(connection, requested: requested)
    }

#if DEBUG
    /// Reports the applied angle per camera; the platform value is the reference
    /// that a fixed 90° failed for the front camera.
    private func logPreviewRotation(_ connection: AVCaptureConnection, requested: CGFloat) {
        let report = "lens=\(previewRotationLens?.rawValue ?? "none"), applied=\(connection.videoRotationAngle), " +
            "requested=\(requested), mirrored=\(connection.isVideoMirrored), " +
            "platform=\(previewRotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? -1)"
        guard report != reportedPreviewRotation else { return }
        reportedPreviewRotation = report
        print("Camera preview rotation: \(report)")
    }
#else
    private func logPreviewRotation(_ connection: AVCaptureConnection, requested: CGFloat) {}
#endif

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        metalView.frame = bounds
        metalView.drawableSize = CameraPreviewPolicy.drawablePixelSize(viewSize: bounds.size,
            fallbackScale: contentScaleFactor, displayScale: traitCollection.displayScale)
        monitorLabel.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 34)
        handoffLabel.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 48),
                                    height: min(64, max(0, bounds.height)))
        handoffLabel.center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
#if DEBUG
        let diagnostic = "bounds=\(bounds.size) parentScale=\(contentScaleFactor) displayScale=\(traitCollection.displayScale) drawable=\(metalView.drawableSize)"
        if diagnosticGeometry != diagnostic {
            diagnosticGeometry = diagnostic
            print("Camera preview surface: \(diagnostic)")
        }
#endif
        // A session reconfiguration can replace the layer's connection, which
        // resets its rotation; re-apply before the geometry is read from it.
        if let activeLens { updatePreviewRotation(for: activeLens) }
        updateRendererGeometry()
    }
}
