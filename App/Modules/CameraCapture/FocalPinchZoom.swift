import SwiftUI

/// The baseline is an absolute equivalent focal length, not a lens-local zoom
/// factor. Switching physical cameras must never restart a live pinch.
struct FocalPinchZoom: ViewModifier {
    let camera: CameraViewModel
    @Binding var isActive: Bool
    @Binding var millimeters: Double
    @State private var baseline = 24.0
    @State private var feedbackTrigger = 0
    @State private var interrupted = false
    @GestureState private var gestureInFlight = false
    @Environment(\.scenePhase) private var scenePhase

    private var captureBusy: Bool {
        camera.isStartingRecording || camera.isRecording || camera.isStoppingRecording
    }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($gestureInFlight) { _, active, _ in active = true }
                    .onChanged { value in
                        guard scenePhase == .active, !captureBusy, !interrupted,
                              value.isFinite, value > 0, camera.zoomSnapshot != nil else {
                            isActive = false
                            interrupted = true
                            return
                        }
                        if !isActive {
                            baseline = camera.currentFocalLengthMM
                            millimeters = baseline
                            isActive = true
                            camera.endSlowZoom()
                        }
                        guard let target = camera.normalizedFocalLengthZoom(baseline * pow(value, 0.65)) else { return }
                        if FocalLengthRulerScale.crossesMajorTick(from: millimeters, to: target) {
                            CameraHaptics.prepareForCaptureFeedback()
                            feedbackTrigger &+= 1
                        }
                        millimeters = target
                        camera.setFocalLengthZoom(target)
                    }
                    .onEnded { _ in
                        isActive = false
                        interrupted = false
                    }
            )
            .sensoryFeedback(.selection, trigger: feedbackTrigger)
            .onChange(of: captureBusy) { _, busy in
                if busy, isActive { isActive = false; interrupted = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active, isActive { isActive = false; interrupted = true }
            }
            .onChange(of: gestureInFlight) { _, active in
                if !active { isActive = false; interrupted = false }
            }
    }
}
