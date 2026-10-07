import SwiftUI
import AVFoundation

/// Clean camera preview only — controls live in ContentView.
struct CameraView: View {
    @State var viewModel: CameraViewModel
    @State private var previewLayer: AVCaptureVideoPreviewLayer?

    var body: some View {
        CameraPreviewRepresentable(previewLayer: $previewLayer, session: viewModel.session.session)
            .onTapGesture { location in
                guard let layer = previewLayer else { return }
                viewModel.handleFocusTap(at: location, in: layer)
            }
            .onAppear { viewModel.onAppear() }
            .onDisappear { viewModel.onDisappear() }
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
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        previewLayer?.frame = uiView.bounds
    }
}