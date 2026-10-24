#if os(iOS)
import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

private struct SelectedVideoFile: Transferable, Sendable {
    let lease: VideoImportFileLease
    let originalFilename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let url = try await VideoImportService.copyToOwnedStorage(from: received.file)
            return SelectedVideoFile(lease: VideoImportFileLease(url: url),
                                     originalFilename: received.file.lastPathComponent)
        }
    }
}

struct VideoImportSheet: View {
    let library: FilmStockLibrary
    let queue: RenderQueueViewModel
    @Binding var isPresented: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var presentation = VideoImportPresentation()
    @State private var imported: ImportedVideo?
    @State private var lease: VideoImportFileLease?
    @State private var transferProgress: Progress?
    @State private var inspection: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .current) {
                        Label(imported == nil ? "Choose Video" : "Change Video", systemImage: "square.and.arrow.down")
                            .frame(minHeight: 44)
                    }
                    .disabled(presentation.isLoading)
                    .accessibilityIdentifier("videoImport.choose")
                    Text("Apple Log 2 only.")
                        .font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                }
                if presentation.isLoading {
                    Section {
                        ProgressView(presentation.phase == .validating ? "Checking video…" : "Preparing video…")
                        Button("Cancel") { cancelImport() }
                            .frame(minHeight: 44)
                    }
                }
                if let imported {
                    Section("Selected video") {
                        Text(imported.originalFilename).lineLimit(2)
                        LabeledContent("Resolution", value: "\(imported.pixelWidth) × \(imported.pixelHeight)")
                        LabeledContent("Duration", value: String(format: "%.1f s", imported.durationSeconds))
                        LabeledContent("Frame rate", value: String(format: "%.2f fps", imported.nominalFrameRate))
                    }
                    Section("Film stock") {
                        ForEach(library.videoStocks(), id: \.stockId) { stock in
                            Button { presentation.selectStock(stock.stockId) } label: {
                                HStack {
                                    Text(stock.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: presentation.selectedStockID == stock.stockId
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(presentation.selectedStockID == stock.stockId
                                                         ? SettingsControlChrome.halationOrange : .secondary)
                                }
                                .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(presentation.selectedStockID == stock.stockId ? .isSelected : [])
                            .accessibilityIdentifier("videoImport.stock.\(stock.stockId)")
                        }
                    }
                    Section {
                        Button(action: render) {
                            Text("Render").font(NitrateTypography.font(.headline))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(SettingsControlChrome.halationOrange,
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!presentation.canRender)
                        .opacity(presentation.canRender ? 1 : 0.45)
                        .accessibilityIdentifier("videoImport.render")
                        Text("The finished video saves to Photos.")
                            .font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
                    }
                }
                if let message = presentation.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                            .accessibilityIdentifier("videoImport.error")
                    }
                }
            }
            .font(NitrateTypography.font(.body))
            .navigationTitle("Process Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { cancelImport(); isPresented = false }
                }
            }
            .onChange(of: pickerItem) { _, item in
                if let item { importFile(item) }
            }
            .onChange(of: isPresented) { _, shown in
                if !shown { cancelImport() }
            }
            .onDisappear {
                if !isPresented { cancelImport() }
            }
        }
    }

    private func importFile(_ item: PhotosPickerItem) {
        cancelImport(clearPicker: false)
        let token = presentation.begin()
        transferProgress = item.loadTransferable(type: SelectedVideoFile.self) { result in
            Task { @MainActor in
                guard token == presentation.generation else { return }
                switch result {
                case .success(let file?):
                    guard presentation.validating(token) else { return }
                    lease = file.lease
                    transferProgress = nil
                    inspection = Task { @MainActor in
                        do {
                            let video = try await VideoImportService.inspect(
                                url: file.lease.url, originalFilename: file.originalFilename)
                            try Task.checkCancellation()
                            guard presentation.accept(url: video.url, token: token) else { return }
                            imported = video
                            inspection = nil
                        } catch {
                            guard token == presentation.generation else { return }
                            lease = nil
                            inspection = nil
                            presentation.fail("Choose an Apple Log 2 video that can be read on this device.", token: token)
                        }
                    }
                case .success(nil):
                    transferProgress = nil
                    presentation.fail("Choose an Apple Log 2 video that can be opened on this device.", token: token)
                case .failure:
                    guard token == presentation.generation else { return }
                    transferProgress = nil
                    presentation.fail("Could not open the video. Try selecting it again.", token: token)
                }
            }
        }
    }

    private func cancelImport(clearPicker: Bool = true) {
        presentation.reset()
        transferProgress?.cancel()
        transferProgress = nil
        inspection?.cancel()
        inspection = nil
        lease = nil
        imported = nil
        if clearPicker { pickerItem = nil }
    }

    private func render() {
        guard presentation.canRender, let video = imported,
              let stock = library.videoStocks().first(where: { $0.stockId == presentation.selectedStockID }),
              lease?.url == video.url else { return }
        guard queue.enqueueImportedVideo(sourceURL: video.url, stockId: stock.stockId,
                                         iso: stock.defaultISO, gauge: stock.effectivePrintGauge) != nil else {
            presentation.enqueueFailed(queue.rendererErrorMessage ?? "Could not queue the video. Try again.")
            return
        }
        lease?.transferToQueue()
        lease = nil
        imported = nil
        _ = presentation.submitted()
        isPresented = false
    }
}
#endif
