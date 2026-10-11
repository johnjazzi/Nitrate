import SwiftUI

/// Pop-over panel of manual camera controls, presented over the preview from
/// the top toolbar's "Manual" button.
///
/// Exactly two columns: ZOOM and FOCUS. ISO deliberately lives in the control
/// bar's exposure control instead, so the two cannot fight over the same
/// device setting.
struct ManualControlsPanel: View {
    let session: CameraSession
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
                range: 1.0...Double(max(session.maxZoomFactor, 1.0)),
                step: 0.1,
                tint: .white,
                length: 110
            )
            .onChange(of: zoomFactor) { _, newValue in
                session.setZoom(CGFloat(newValue))
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
                session.setManualFocusPosition(Float(newValue))
            }

            Button {
                isManualFocus.toggle()
                if isManualFocus {
                    session.setManualFocusPosition(Float(manualFocusPosition))
                } else {
                    session.resetAutoFocus()
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
