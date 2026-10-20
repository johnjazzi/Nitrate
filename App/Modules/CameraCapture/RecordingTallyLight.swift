import SwiftUI

/// A steady tally avoids suggesting a take is live before capture confirms it.
struct RecordingTallyLight: View {
    let isRecording: Bool

    var body: some View {
        Circle()
            .fill(isRecording ? Color.red : Color(red: 0.22, green: 0.045, blue: 0.035))
            .overlay { Circle().strokeBorder(.black.opacity(0.65), lineWidth: 2) }
            .shadow(color: isRecording ? .red.opacity(0.7) : .clear, radius: 5)
            .frame(width: 18, height: 18)
            .padding(3)
            .background(Circle().fill(.black.opacity(0.4)))
            .allowsHitTesting(false)
            .accessibilityLabel(isRecording ? "Recording light on" : "Recording light off")
    }
}
