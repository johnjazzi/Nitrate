import SwiftUI

/// Hardware bindings stay here; shared presentation never owns capture state.
struct ManualControlsPanel: View {
    let cameraViewModel: CameraViewModel
    @Binding var zoomFactor: Double
    @Binding var manualFocusPosition: Double
    @Binding var isManualFocus: Bool
    @Binding var expanded: Bool
    let landscape: Bool
    let onDismiss: () -> Void

    var body: some View {
        ManualControlsSurface(
            zoom: $zoomFactor, focus: $manualFocusPosition, manualFocus: $isManualFocus,
            expanded: $expanded, landscape: landscape,
            zoomRange: 1...Double(max(cameraViewModel.session.maxZoomFactor, 1)),
            exposure: "ISO \(Int(cameraViewModel.liveISO)) · \(shutterText)",
            apertureReadout: cameraViewModel.liveAperture.map { String(format: "f/%.1f", $0) } ?? "N/A",
            stabilization: cameraViewModel.recordingStabilization,
            canChangeStabilization: cameraViewModel.canSetRecordingStabilization,
            selectStabilization: cameraViewModel.setRecordingStabilization,
            dismiss: onDismiss
        ) {
            apertureControl
        }
        .onChange(of: zoomFactor) { _, value in cameraViewModel.session.setZoom(CGFloat(value)) }
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
