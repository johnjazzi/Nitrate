import SwiftUI

/// Pop-over panel of manual camera controls, presented over the preview from
/// the top toolbar's "Manual" button.
///
/// Three compact columns: ZOOM, FOCUS, and APERTURE. ISO deliberately lives in the control
/// bar's exposure control instead, so the two cannot fight over the same
/// device setting.
struct ManualControlsPanel: View {
    let cameraViewModel: CameraViewModel
    @Binding var zoomFactor: Double
    @Binding var manualFocusPosition: Double
    @Binding var isManualFocus: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header

            HStack(alignment: .top, spacing: 6) {
                zoomColumn
                focusColumn
                apertureColumn
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
                    .padding(6)
            }
            .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 7))
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
                length: 80
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
                length: 80
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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
            }
            .buttonStyle(CameraRaisedButtonStyle(
                faceColor: isManualFocus ? .yellow : Color(red: 0.16, green: 0.17, blue: 0.19),
                cornerRadius: 6
            ))
        }
    }

    private var apertureColumn: some View {
        let measured = cameraViewModel.liveAperture
        let readout = measured.map { String(format: "f/%.1f", $0) } ?? "N/A"
        return controlColumn(title: "APERTURE", readout: readout) {
            if cameraViewModel.canSelectAperture {
                Menu {
                    Button("Hold") { cameraViewModel.setLensAperture(nil) }
                    ForEach(cameraViewModel.apertureStops, id: \.self) { stop in
                        Button(String(format: "f/%.1f", stop)) {
                            cameraViewModel.setLensAperture(stop)
                        }
                    }
                } label: {
                    Label(cameraViewModel.selectedLensAperture.map { String(format: "f/%.1f", $0) } ?? "Hold",
                          systemImage: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .frame(height: 80)
                .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 6))
            } else {
                let stateLabel: String = {
                    guard measured != nil else { return "—" }
                    return cameraViewModel.apertureIsVariable ? "READ ONLY" : "FIXED"
                }()
                VStack(spacing: 6) {
                    Image(systemName: measured == nil ? "minus.circle" : "lock.fill")
                    Text(stateLabel)
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 80)
            }
        }
    }

    /// One labelled column: title, vertical control, readout.
    private func controlColumn<Content: View>(
        title: String,
        readout: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            content()
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}
