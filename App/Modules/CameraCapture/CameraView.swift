import SwiftUI
import AVFoundation

/// Clean camera preview only — controls live in ContentView.
struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: CameraViewModel
    @State private var previewLayer: AVCaptureVideoPreviewLayer?
    @AppStorage(MeteringIndicatorPreferences.showsIndicatorKey) private var showsMeteringIndicator = MeteringIndicatorPreferences.defaultShowsIndicator
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var selectedStockLUTName: String? = nil
    var previewEnabled = true
    var developmentPhotoPreview = false

    private var captureStatus: String {
        let profile = viewModel.isChangingCaptureProfile ? "Changing capture profile"
            : (viewModel.isVideoCaptureProfileActive ? "Video Log" : "Idle SDR")
        let duration = viewModel.photoExposureSnapshot?.durationSeconds ?? viewModel.liveShutterSeconds
        return profile + String(format: "; exposure=%.6f", duration)
    }

    var body: some View {
        CameraPreviewRepresentable(previewLayer: $previewLayer, camera: viewModel.session,
                                   videoGravity: videoGravity,
                                   cropZoom: viewModel.isVideoCaptureProfileActive ? 1 : viewModel.photoCropZoom,
                                   active: scenePhase == .active && previewEnabled,
                                   lens: viewModel.activeLens,
                                   captureStatus: captureStatus)
            .overlay {
                MeteringBoxView(point: viewModel.meteringPoint,
                                isManual: viewModel.isManualExposure,
                                isVisible: showsMeteringIndicator && !viewModel.isRecording)
            }
            .onTapGesture { location in
                guard let layer = previewLayer, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
                let visiblePoint = CGPoint(x: layer.bounds.midX + (location.x - layer.bounds.midX) / (viewModel.isVideoCaptureProfileActive ? 1 : max(viewModel.photoCropZoom, 1)),
                                           y: layer.bounds.midY + (location.y - layer.bounds.midY) / (viewModel.isVideoCaptureProfileActive ? 1 : max(viewModel.photoCropZoom, 1)))
                viewModel.handleFocusTap(at: visiblePoint, in: layer)
                viewModel.setMeteringPoint(CGPoint(x: location.x / layer.bounds.width,
                                                   y: location.y / layer.bounds.height))
            }
            .onAppear {
                if scenePhase == .active { viewModel.onAppear() }
                else if scenePhase == .background { viewModel.onSceneInactive() }
            }
            .onDisappear { viewModel.onDisappear() }
            // Only `.background` owns the camera's teardown. `.inactive` is
            // transient — a permission alert, Control Center, an incoming call
            // banner — and tearing the session down for it left the shutter
            // waiting on a photo-exposure snapshot that the restart had not
            // republished yet, so the mode switch was refused and the camera
            // looked dead after returning.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: viewModel.onSceneActive()
                case .background: viewModel.onSceneInactive()
                default: break
                }
            }
    }
}

private struct CameraPreviewRepresentable: UIViewRepresentable {
    @Binding var previewLayer: AVCaptureVideoPreviewLayer?
    let camera: CameraSession
    let videoGravity: AVLayerVideoGravity
    let cropZoom: Double
    let active: Bool
    let lens: CameraLens
    let captureStatus: String

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(camera: camera)
        view.previewLayer.videoGravity = videoGravity
        DispatchQueue.main.async {
            previewLayer = view.previewLayer
            view.updatePreviewRotation(for: lens)
            view.setNeedsLayout()
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.accessibilityValue = captureStatus
        uiView.previewLayer.videoGravity = videoGravity
        uiView.previewLayer.setAffineTransform(CGAffineTransform(scaleX: max(cropZoom, 1), y: max(cropZoom, 1)))
        uiView.isPreviewActive = active
        uiView.updatePreviewRotation(for: lens)
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.detach()
    }
}

/// A single native AVFoundation preview surface; LUT/film rendering is deliberately absent.
private final class CameraPreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var isPreviewActive = true { didSet { if oldValue != isPreviewActive { updateVisibility() } } }
    private let camera: CameraSession
    private var activeLens: CameraLens?
    private var previewRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var previewRotationLens: CameraLens?
    private var previewRotationConnection: AVCaptureConnection?
    private var sessionObservation: NSKeyValueObservation?

    init(camera: CameraSession) {
        self.camera = camera
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "camera.preview"
        accessibilityLabel = "Camera preview"
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.isHidden = true
        layer.addSublayer(previewLayer)
        sessionObservation = camera.session.observe(\.isRunning, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.setNeedsLayout()
                self?.updateVisibility()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func updatePreviewRotation(for lens: CameraLens) {
        activeLens = lens
        if previewRotationLens != lens { observePreviewRotation(for: lens) }
        guard previewLayer.connection !== previewRotationConnection else { return }
        applyPreviewRotation()
    }

    private func observePreviewRotation(for lens: CameraLens) {
        previewRotationObservation = nil
        previewRotationCoordinator = nil
        previewRotationLens = lens
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                         options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in
                self?.applyPreviewRotation(change.newValue)
                self?.setNeedsLayout()
            }
        }
        previewRotationCoordinator = coordinator
    }

    private func applyPreviewRotation(_ platformAngle: CGFloat? = nil) {
        guard let connection = previewLayer.connection else { return }
        let angle = CameraPreviewRotationPolicy.angle(
            platformAngle: platformAngle ?? previewRotationCoordinator?.videoRotationAngleForHorizonLevelPreview)
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        previewRotationConnection = connection
        if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
        updateVisibility()
    }

    private func updateVisibility() {
        let nativeReady = isPreviewActive && bounds.width > 0 && bounds.height > 0
            && camera.session.isRunning && previewLayer.connection != nil
            && previewRotationConnection === previewLayer.connection
        previewLayer.isHidden = !nativeReady
    }

    func detach() {
        sessionObservation = nil
        previewRotationObservation = nil
        previewRotationCoordinator = nil
        previewRotationLens = nil
        previewRotationConnection = nil
        previewLayer.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        if let activeLens { updatePreviewRotation(for: activeLens) }
        updateVisibility()
    }
}
