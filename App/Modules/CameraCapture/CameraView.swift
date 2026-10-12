import SwiftUI
import AVFoundation

/// Clean camera preview only — controls live in ContentView.
struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: CameraViewModel
    @State private var previewLayer: AVCaptureVideoPreviewLayer?
    @State private var previewSize: CGSize = .zero

    var body: some View {
        CameraPreviewRepresentable(previewLayer: $previewLayer, session: viewModel.session.session)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { previewSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in previewSize = size }
                }
            )
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

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        DispatchQueue.main.async { [weak view] in
            previewLayer = layer
            layer.frame = view?.bounds ?? .zero
            if #available(iOS 17.0, *),
               let connection = layer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        previewLayer?.frame = uiView.bounds
    }
}
