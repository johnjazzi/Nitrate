import SwiftUI

/// The shutter dial leads with its denominations rather than its detents:
/// larger numbers over shorter ticks than the shared ruler draws by default.
/// Everything else — the 44pt rail, its length, the reversed dial gesture —
/// stays as the shared ruler lays it out.
enum PhotoShutterRailStyle {
    static let labelFontSize: CGFloat = 14
    static let majorTickLength: CGFloat = 9
    static let minorTickLength: CGFloat = 4.5
}

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
                // The face prints only the denominator; the ruler below speaks
                // the full photographic value, so this copy would repeat it.
                .accessibilityHidden(true)
            if durations.count > 1 {
                RulerSlider(value: Binding(get: { displayDuration }, set: { value in
                    intent.select(duration: value)
                    setDuration(value)
                }), range: snapshot.shutterRange, step: 1,
                    pointsPerStep: CGFloat(RulerScale.detentTravel),
                    majorValues: Set(durations),
                    tickLabel: { PhotoShutterPresentation.label(for: $0) },
                    scale: .logarithmic(pointsPerStop: RulerScale.detentTravel * 3),
                    ladder: durations, tint: .orange,
                    labelFontSize: PhotoShutterRailStyle.labelFontSize,
                    majorTickLength: PhotoShutterRailStyle.majorTickLength,
                    minorTickLength: PhotoShutterRailStyle.minorTickLength,
                    length: max(44, width - 120), width: 44,
                    orientation: .horizontal, reversesDrag: true)
                    .accessibilityIdentifier("photo.shutterDuration")
                    .accessibilityLabel("Photo shutter duration")
                    .accessibilityValue(PhotoShutterPresentation.spokenLabel(for: displayDuration))
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
        // The same dark translucent rail the manual focus and zoom rulers
        // draw, so the shutter reads as one more manual ruler rather than a
        // raised control plate.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.45))
        }
        .onChange(of: snapshot) { _, value in intent.reconcile(value) }
    }
}
