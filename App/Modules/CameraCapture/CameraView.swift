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
                                   active: scenePhase == .active && !viewModel.isSwitchingCameraLens,
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
    let lens: CameraLens
    let selectedStockLUTName: String?

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(camera: camera)
        let layer = view.previewLayer
        layer.videoGravity = videoGravity
        DispatchQueue.main.async {
            previewLayer = layer
            if #available(iOS 17.0, *),
               let connection = layer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                view.setNeedsLayout()
            }
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = videoGravity
        uiView.update(mode: mode, active: active, lens: lens, selectedStockLUTName: selectedStockLUTName)
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
    private let owner = UUID()
    private var renderer: CameraPreviewRenderer?
    private var wantsLUT = false
    private var attached = false
    private var activeLens: CameraLens?
    private var resolvedLUTName: String?
#if DEBUG
    private var diagnosticGeometry = ""
#endif

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
        monitorLabel.font = .preferredFont(forTextStyle: .caption2)
        monitorLabel.textColor = .white
        monitorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        monitorLabel.numberOfLines = 2
        monitorLabel.isUserInteractionEnabled = false
        addSubview(monitorLabel)
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            metalLayer.framebufferOnly = true
            renderer = CameraPreviewRenderer(layer: metalLayer) { [weak self] lutActive, warning in
                guard let self, self.wantsLUT else { return }
                self.metalView.isHidden = !lutActive
                self.monitorLabel.text = warning
                self.monitorLabel.isHidden = warning == nil
                self.setNeedsLayout()
            }
        }
    }

    func update(mode: CameraPreviewMode, active: Bool, lens: CameraLens, selectedStockLUTName: String?) {
        let requested = mode != .log && active
        let lutName = mode.lutName(for: selectedStockLUTName)
        if wantsLUT != requested || activeLens != lens || resolvedLUTName != lutName {
            metalView.isHidden = true
            monitorLabel.text = requested ? "Preview LUT pending — showing Log" : nil
            monitorLabel.isHidden = !requested
            renderer?.reset()
        }
        wantsLUT = requested
        activeLens = lens
        resolvedLUTName = lutName
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
        renderer?.configure(active: false, geometry: .init(), selectedLUTName: resolvedLUTName)
        camera.removePreviewTap(owner: owner)
        attached = false
        metalView.isHidden = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        updateRendererGeometry()
        refreshSink()
    }

    private func updateRendererGeometry() {
        let connection = previewLayer.connection
        if let connection, connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
        let geometry = CameraPreviewRenderer.Geometry(size: bounds.size,
            rotationAngle: connection?.videoRotationAngle ?? 90,
            mirrored: connection?.isVideoMirrored ?? false,
            fill: previewLayer.videoGravity == .resizeAspectFill)
        if renderer?.configure(active: wantsLUT && window != nil, geometry: geometry,
                               selectedLUTName: resolvedLUTName) == true {
            metalView.isHidden = true
            monitorLabel.text = wantsLUT ? "Preview LUT pending — showing Log" : nil
            monitorLabel.isHidden = !wantsLUT
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        metalView.frame = bounds
        metalView.drawableSize = CameraPreviewPolicy.drawablePixelSize(viewSize: bounds.size,
            fallbackScale: contentScaleFactor, displayScale: traitCollection.displayScale)
        monitorLabel.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 34)
        CATransaction.commit()
#if DEBUG
        let diagnostic = "bounds=\(bounds.size) parentScale=\(contentScaleFactor) displayScale=\(traitCollection.displayScale) drawable=\(metalView.drawableSize)"
        if diagnosticGeometry != diagnostic {
            diagnosticGeometry = diagnostic
            print("Camera preview surface: \(diagnostic)")
        }
#endif
        updateRendererGeometry()
    }
}
