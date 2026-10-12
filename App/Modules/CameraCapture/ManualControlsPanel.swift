import SwiftUI

/// Pop-over panel of manual camera controls, presented over the preview from
/// the top toolbar's "Manual" button.
///
/// Exactly two columns: ZOOM and FOCUS. ISO deliberately lives in the control
/// bar's exposure control instead, so the two cannot fight over the same
/// device setting.
struct ManualControlsPanel: View {
    let cameraViewModel: CameraViewModel
    @Binding var zoomFactor: Double
    @Binding var manualFocusPosition: Double
    @Binding var isManualFocus: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            header

            HStack(alignment: .top, spacing: 24) {
                zoomColumn
                focusColumn
                apertureColumn
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack {
            Text("MANUAL")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: - Columns

    private var zoomColumn: some View {
        controlColumn(title: "ZOOM", readout: String(format: "%.1fx", zoomFactor)) {
            VerticalSlider(
                value: $zoomFactor,
                range: 1.0...Double(max(cameraViewModel.session.maxZoomFactor, 1.0)),
                step: 0.1,
                tint: .white,
                length: 110
            )
            .onChange(of: zoomFactor) { _, newValue in
                cameraViewModel.session.setZoom(CGFloat(newValue))
            }
        }
    }

    private var focusColumn: some View {
        controlColumn(title: "FOCUS", readout: isManualFocus ? "MF" : "AF") {
            VerticalSlider(
                value: $manualFocusPosition,
                range: 0...1,
                step: 0.01,
                tint: isManualFocus ? .yellow : .white.opacity(0.45),
                length: 110
            )
            .disabled(!isManualFocus)
            .opacity(isManualFocus ? 1 : 0.4)
            .onChange(of: manualFocusPosition) { _, newValue in
                guard isManualFocus else { return }
                cameraViewModel.session.setManualFocusPosition(Float(newValue))
            }

            Button {
                isManualFocus.toggle()
                if isManualFocus {
                    cameraViewModel.session.setManualFocusPosition(Float(manualFocusPosition))
                } else {
                    cameraViewModel.session.resetAutoFocus()
                }
            } label: {
                Text(isManualFocus ? "AF" : "MF")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isManualFocus ? .black : .white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isManualFocus ? Color.yellow : Color.white.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    private var apertureColumn: some View {
        let measured = cameraViewModel.liveAperture
        let readout = measured.map { String(format: "f/%.1f", $0) } ?? "N/A"
        return controlColumn(title: "APERTURE", readout: readout) {
            if cameraViewModel.apertureIsVariable {
                Menu {
                    Button("Auto") { cameraViewModel.setLensAperture(nil) }
                    ForEach(cameraViewModel.apertureStops, id: \.self) { stop in
                        Button(String(format: "f/%.1f", stop)) {
                            cameraViewModel.setLensAperture(stop)
                        }
                    }
                } label: {
                    Label(cameraViewModel.selectedLensAperture.map { String(format: "f/%.1f", $0) } ?? "Auto",
                          systemImage: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .frame(height: 110)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: measured == nil ? "minus.circle" : "lock.fill")
                    Text(measured == nil ? "—" : "FIXED")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 110)
            }
        }
    }

    /// One labelled column: title, vertical control, readout.
    private func controlColumn<Content: View>(
        title: String,
        readout: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
            content()
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }
}
