#if os(iOS)
import SwiftUI

/// Format requirements and processing guidance for Lab. Decoder errors remain
/// available separately without changing the import or render policy.
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
                Section("Development") {
                    Text("Choose a film stock, print gauge and push/pull setting. Develop applies that recipe to your selected photo or video and saves the rendered result to Photos.")
                    Text("The stock sets the color treatment, the print gauge shapes the grain, and push/pull changes the processing exposure. Your original file stays unchanged.")
                }
                Section("Photos") {
                    Text("RAW photos, including DNG and Apple ProRAW, plus camera RAW formats such as Nikon NEF, Sony ARW and Canon CR2/CR3 when supported by this device's RAW decoder.")
                    Text("Support depends on the camera model and iOS decoder, not just the file extension. JPEG, HEIC and other already-processed images cannot be developed here.")
                }
                Section("Video") {
                    Text("Apple Log 2 clips with their original color metadata intact. Standard video, first-generation Apple Log, and clips converted to SDR or HDR are not supported by the video importer.")
                    Text("Keep the original Log file when transferring a clip. An export or conversion may remove the metadata needed to identify it.")
                }
                Section("White balance") {
                    Text("Tap WB beside Push/Pull to open the slider. RAW photos start at the stock's temperature; choose Kelvin to override it, or Use stock to reset.")
                    Text("Video starts at Original. Adjust toward Cooler or Warmer for a relative correction, or Use original to reset. This is a processing adjustment, not a measurement of the camera's recorded white balance.")
                }
                Section("Preview") {
                    Text("The preview updates as you change the recipe. Photos show a still; videos show the first available frame, not playback. Develop processes the full selected photo or clip.")
                }
                Section("Exposure") {
                    Text("The exposure estimate is a center-weighted file reading relative to 18% gray, not a calibrated camera meter. For video, it measures only the preview frame.")
                    Text("Auto is neutral for imported files because there is no live camera meter. Choose a manual push or pull to adjust processing without changing the original capture settings.")
                }
                Section("Results") {
                    Text("Finished results are saved to Photos. Imported originals are not saved back as duplicate originals. Queue shows processing, delivery and any errors.")
                    Text("Re-develop returns an available retained original to review so you can change the recipe and render again.")
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
