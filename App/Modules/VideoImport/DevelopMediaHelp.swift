#if os(iOS)
import SwiftUI

/// Short facts only. Original decoder errors remain available on explicit request.
struct DevelopMediaHelp: View {
    var refusal: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let refusal {
                    Section("Details") {
                        Text(refusal)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("develop.help.refusal")
                    }
                }
                Section("Formats") {
                    LabeledContent("Video", value: "Log 2")
                    LabeledContent("Photo", value: "RAW")
                }
                Section("Exposure") {
                    LabeledContent("Estimate", value: "Center-weighted")
                    LabeledContent("Reference", value: "18% gray")
                    LabeledContent("Calibration", value: "Uncalibrated")
                    LabeledContent("Auto", value: "Neutral")
                }
                Section("Output") {
                    LabeledContent("Preview", value: "Still")
                    LabeledContent("Photos", value: "Library")
                    LabeledContent("Originals", value: "Unchanged")
                }
            }
            .font(NitrateTypography.font(.body))
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("develop.help.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
