import SwiftUI

/// Photo shutter ruler using the shared relative-drag interaction.
struct PhotoShutterControl: View {
    let snapshot: PhotoExposureSnapshot
    let setDuration: (Double) -> Void
    let setLocked: (Bool) -> Void
    let width: CGFloat

    @State private var intent: PhotoExposureIntentPresentation

    init(snapshot: PhotoExposureSnapshot, setDuration: @escaping (Double) -> Void,
         setLocked: @escaping (Bool) -> Void, width: CGFloat = 280) {
        self.snapshot = snapshot
        self.setDuration = setDuration
        self.setLocked = setLocked
        self.width = width
        _intent = State(initialValue: PhotoExposureIntentPresentation(snapshot: snapshot))
    }

    private var durations: [Double] { PhotoShutterPresentation.detents(in: snapshot.shutterRange) }
    private var displayDuration: Double { intent.duration }

    var body: some View {
        HStack(spacing: 4) {
            Text(PhotoShutterPresentation.label(for: displayDuration))
                .font(NitrateTypography.font(size: 11).monospacedDigit())
#if os(iOS)
                .cameraUpright()
#endif
                .frame(width: 52, height: 44)
            if durations.count > 1 {
                RulerSlider(value: Binding(get: { displayDuration }, set: { value in
                    intent.select(duration: value)
                    setDuration(value)
                }), range: snapshot.shutterRange, step: 1,
                    pointsPerStep: CGFloat(RulerScale.detentTravel),
                    majorValues: Set(durations),
                    tickLabel: { PhotoShutterPresentation.label(for: $0) },
                    scale: .logarithmic(pointsPerStop: RulerScale.detentTravel * 3),
                    ladder: durations, tint: .orange, length: max(44, width - 120), width: 44,
                    orientation: .horizontal)
                    .accessibilityIdentifier("photo.shutterDuration")
                    .accessibilityLabel("Photo shutter duration")
                    .accessibilityValue(PhotoShutterPresentation.label(for: displayDuration))
            }
            Button {
                let next = !intent.shutterLocked
                intent.setLocked(next)
                setLocked(next)
            } label: {
                Text(intent.shutterLocked ? "Lock" : "Float")
                    .font(NitrateTypography.font(size: 10))
    #if os(iOS)
                .cameraUpright()
#endif
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(intent.shutterLocked ? Color.yellow : Color.orange)
            .accessibilityLabel("Shutter duration mode")
            .accessibilityValue(intent.shutterLocked ? "Lock" : "Float")
            .accessibilityIdentifier("photo.shutterLock")
        }
        .font(NitrateTypography.font(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: width, height: 56)
        .contentShape(Rectangle())
        .onTapGesture { } // Consume gaps so preview focus cannot receive rail taps.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo.shutterRail")
        .modifier(CameraInsetSurface())
        .onChange(of: snapshot) { _, value in intent.reconcile(value) }
    }
}
