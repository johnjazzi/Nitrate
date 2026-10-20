import SwiftUI

/// Hardware bindings stay here; shared presentation never owns capture state.
struct ManualControlsPanel: View {
    let cameraViewModel: CameraViewModel

    @Binding var manualFocusPosition: Double
    @Binding var isManualFocus: Bool
    @Binding var expanded: Bool
    let landscape: Bool
    let daylight60Armed: Bool
    let daylight60Available: Bool
    let daylight60UnavailableReason: String?
    let canChangeFrameRate: Bool
    let setDaylight60: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ManualControlsSurface(
            zoom: Binding(get: { cameraViewModel.zoomSnapshot?.displayFactor ?? 1 },
                          set: { cameraViewModel.setDisplayZoom($0) }),
            focus: $manualFocusPosition, manualFocus: $isManualFocus,
            expanded: $expanded, landscape: landscape,
            zoomRange: zoomRange,
            zoomIsPerLens: cameraViewModel.zoomSnapshot?.isPerLens ?? true,
            zoomAvailable: cameraViewModel.zoomSnapshot != nil,
            zoomRevision: cameraViewModel.zoomSnapshot?.cameraRevision ?? 0,
            exposure: "ISO \(Int(cameraViewModel.liveISO)) · \(shutterText)",
            apertureReadout: cameraViewModel.liveAperture.map { String(format: "f/%.1f", $0) } ?? "N/A",
            stabilization: cameraViewModel.recordingStabilization,
            canChangeStabilization: cameraViewModel.canSetRecordingStabilization,
            selectStabilization: cameraViewModel.setRecordingStabilization,
            daylight60Armed: daylight60Armed,
            daylight60Available: daylight60Available,
            daylight60UnavailableReason: daylight60UnavailableReason,
            canChangeFrameRate: canChangeFrameRate,
            setDaylight60: setDaylight60,
            dismiss: onDismiss,
            beginZoom: cameraViewModel.beginSlowZoom,
            endZoom: cameraViewModel.endSlowZoom(revision:),
            stepZoom: { direction in
                guard let snapshot = cameraViewModel.zoomSnapshot else { return }
                let delta = direction == .in ? 0.1 : -0.1
                cameraViewModel.setDisplayZoom(min(max(snapshot.displayFactor + delta,
                                                        snapshot.minimumDisplayFactor), snapshot.maximumDisplayFactor))
            }
        ) {
            apertureControl
        }
        .onDisappear { cameraViewModel.endSlowZoom() }
        .onChange(of: manualFocusPosition) { _, value in
            guard isManualFocus else { return }
            cameraViewModel.session.setManualFocusPosition(Float(value))
        }
        .onChange(of: isManualFocus) { _, manual in
            if manual {
                cameraViewModel.session.setManualFocusPosition(Float(manualFocusPosition))
            } else {
                cameraViewModel.session.resetAutoFocus()
            }
        }
    }

    private var zoomRange: ClosedRange<Double> {
        let minimum = cameraViewModel.zoomSnapshot?.minimumDisplayFactor ?? 1
        let maximum = cameraViewModel.zoomSnapshot?.maximumDisplayFactor ?? 1
        return minimum...maximum
    }

    private var shutterText: String {
        let seconds = cameraViewModel.liveShutterSeconds
        return seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : "1/48"
    }

    @ViewBuilder private var apertureControl: some View {
        if cameraViewModel.canSelectAperture {
            Menu {
                Button("Hold") { cameraViewModel.setLensAperture(nil) }
                ForEach(cameraViewModel.apertureStops, id: \.self) { stop in
                    Button(String(format: "f/%.1f", stop)) { cameraViewModel.setLensAperture(stop) }
                }
            } label: {
                Text(cameraViewModel.selectedLensAperture.map { String(format: "f/%.1f", $0) } ?? "Hold")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Aperture")
        } else {
            VStack(spacing: 4) {
                Image(systemName: cameraViewModel.liveAperture == nil ? "minus.circle" : "lock.fill")
                Text(cameraViewModel.liveAperture == nil ? "—" :
                        (cameraViewModel.apertureIsVariable ? "Read only" : "Fixed"))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Aperture unavailable for adjustment")
        }
    }
}
