import SwiftUI
import AVFoundation

/// Clean camera preview only — controls live in ContentView.
struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: CameraViewModel
    @State private var previewLayer: AVCaptureVideoPreviewLayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    var body: some View {
        CameraPreviewRepresentable(previewLayer: $previewLayer, session: viewModel.session.session,
                                   videoGravity: videoGravity)
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
    let session: AVCaptureSession
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(session: session)
        let layer = view.previewLayer
        layer.videoGravity = videoGravity
        DispatchQueue.main.async {
            previewLayer = layer
            if #available(iOS 17.0, *),
               let connection = layer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = videoGravity
        uiView.setNeedsLayout()
    }
}

/// SwiftUI may update before UIKit has applied the new bounds. Resize the
/// existing preview layer during layout, never recreate it for a mode change.
private final class CameraPreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
