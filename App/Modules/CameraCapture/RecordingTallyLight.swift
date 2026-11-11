import SwiftUI

/// A steady tally acknowledges an accepted take, including cancellable startup.
struct RecordingTallyLight: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            Circle()
                .fill(Color.red)
                .overlay { Circle().strokeBorder(.black.opacity(0.65), lineWidth: 2) }
                .shadow(color: .red.opacity(0.7), radius: 5)
                .frame(width: 18, height: 18)
                .padding(3)
                .background(Circle().fill(.black.opacity(0.4)))
                .allowsHitTesting(false)
                .accessibilityLabel("Recording light on")
        }
    }
}
