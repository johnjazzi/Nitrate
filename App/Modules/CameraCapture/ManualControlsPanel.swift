import SwiftUI

/// Pop-over panel of manual camera controls, presented over the preview from
/// the top toolbar's "Manual" button.
///
/// Three compact columns: ZOOM, FOCUS, and APERTURE. ISO remains editable only in
/// the control bar; the exposure values here are read-only. Recording
/// stabilization is a separate row and does not change preview stabilization.
struct ManualControlsPanel: View {
    let cameraViewModel: CameraViewModel
    @Binding var zoomFactor: Double
    @Binding var manualFocusPosition: Double
    @Binding var isManualFocus: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            exposureReadout

            HStack(alignment: .top, spacing: 6) {
                zoomColumn
                focusColumn
                apertureColumn
            }
            recordingStabilizationRow
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
                .cameraUpright()
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .cameraUpright()
                    .padding(6)
            }
            .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 7))
        }
    }

    private var exposureReadout: some View {
        Text("ISO \(Int(cameraViewModel.liveISO)) · \(shutterText)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .cameraUpright()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shutterText: String {
        let seconds = cameraViewModel.liveShutterSeconds
        guard seconds > 0 else { return "1/48" }
        return "1/\(Int((1.0 / seconds).rounded()))"
    }

    // MARK: - Columns

    private var recordingStabilizationRow: some View {
        let snapshot = cameraViewModel.recordingStabilization
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("Recording stabilization")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .cameraUpright()
                Spacer(minLength: 0)
                Menu {
                    ForEach(snapshot.capability.availableModes) { mode in
                        Button {
                            cameraViewModel.setRecordingStabilization(mode)
                        } label: {
                            if mode == snapshot.preferred {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Label(snapshot.capability.effectiveMode(for: snapshot.preferred).title,
                          systemImage: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .cameraUpright()
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                }
                .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 6))
                .disabled(!cameraViewModel.canSetRecordingStabilization)
            }
            Text(snapshot.statusText)
                .foregroundStyle(.white.opacity(0.8))
            Text("Recording only · may crop and delay confirmation.")
                .foregroundStyle(.white.opacity(0.6))
            DisclosureGroup("Stabilization help") {
                Text("Preview is independent. Stronger modes crop more. Confirmation takes about " +
                     "0.3 s (Off/Standard), 0.9 s (Cinematic), or 2.2 s (Extreme), measured on device. " +
                     "Recording begins about 0.2 s after the tap in every mode. Extreme uses Apple " +
                     "extended cinematic stabilization.")
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)
            }
            .tint(.white.opacity(0.8))
        }
        .font(.caption2)
        .padding(.top, 4)
    }

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
                    .cameraUpright()
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
                        .cameraUpright()
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
                        .cameraUpright()
                    Text(stateLabel)
                        .font(.caption2.weight(.bold))
                        .cameraUpright()
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
                .cameraUpright()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            content()
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .cameraUpright()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}
