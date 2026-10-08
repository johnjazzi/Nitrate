import SwiftUI
import PhotosUI

/// Single camera screen with stock/queue sheets and a settings gear.
/// Toggle "Frame Mode" in Settings to show a viewfinder-style preview.
/// Never destroys the CameraView — orientation and frame mode use the same view.
struct ContentView: View {
    @State var cameraViewModel: CameraViewModel
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    let purchaseViewModel: PurchaseViewModel

    @State private var showStockSheet = false
    @State private var showQueueSheet = false
    @State private var showSettings = false
    @State private var showFramedPreview = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var currentSourceURL: URL?

    /// Persisted stock selection — survives across recordings.
    @State private var selectedStock: FilmStockConfig?
    @State private var currentISO: Float = 400

    /// Camera controls state
    @State private var zoomFactor: Double = 1.0
    @State private var isFrontCamera = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraLayer

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, showFramedPreview ? 8 : 0)

                Spacer()

                bottomBar
                    .padding(.top, showFramedPreview ? 8 : 0)
                    .padding(.bottom, 40)
            }

            errorOverlays
        }
        .sheet(isPresented: $showStockSheet) { stockSheet }
        .sheet(isPresented: $showQueueSheet) { queueSheet }
        .sheet(isPresented: $showSettings) {
            PurchaseView(viewModel: purchaseViewModel, showFramedPreview: $showFramedPreview)
        }
        .onChange(of: cameraViewModel.lastRecordedURL) { _, newURL in
            guard let url = newURL else { return }
            currentSourceURL = url

            // Auto-render: skip stock sheet if already selected
            if let stock = selectedStock {
                enqueueRender(sourceURL: url, stock: stock)
            } else {
                showStockSheet = true
            }
        }
        .onAppear {
            // Restore persisted stock selection
            if let lastId = library.lastSelectedStockId,
               let stock = library.videoStocks().first(where: { $0.stockId == lastId }) {
                selectedStock = stock
                currentISO = library.lastISO(for: stock.stockId)
            }
        }
    }

    // MARK: - Helpers

    private func enqueueRender(sourceURL: URL, stock: FilmStockConfig) {
        renderQueueViewModel.enqueue(
            sourceURL: sourceURL,
            stockId: stock.stockId,
            iso: currentISO
        )
    }

    // MARK: - Camera Layer

    private var cameraLayer: some View {
        CameraView(viewModel: cameraViewModel)
            .ignoresSafeArea()
            .clipShape(RoundedRectangle(cornerRadius: showFramedPreview ? 16 : 0))
            .padding(.horizontal, showFramedPreview ? 8 : 0)
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.25), lineWidth: 2)
                        .padding(.horizontal, 8)
                }
            }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }

            // Import from Photos
            PhotosPicker(selection: $selectedPhotoItem, matching: .videos) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let importURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("imported_\(UUID().uuidString).mov") {
                        try data.write(to: importURL)
                        currentSourceURL = importURL
                        if let stock = selectedStock {
                            enqueueRender(sourceURL: importURL, stock: stock)
                        } else {
                            showStockSheet = true
                        }
                    }
                    selectedPhotoItem = nil
                }
            }

            // Camera switch (front/back)
            Button {
                switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }

            // Zoom slider
            zoomControl

            Spacer()
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    private var zoomControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "minus.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            Slider(value: $zoomFactor, in: 1.0...5.0, step: 0.1)
                .frame(width: 80)
                .onChange(of: zoomFactor) { _, value in
                    Task { try? cameraViewModel.session.setZoom(CGFloat(value)) }
                }

            Image(systemName: "plus.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4))
        .clipShape(Capsule())
    }

    private func switchCamera() {
        isFrontCamera.toggle()
        let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
        Task {
            do {
                try cameraViewModel.session.switchCamera(to: position)
            } catch {
                cameraViewModel.errorMessage = "Camera switch failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Left: Stock chip or stock button — fixed width for centering
            Group {
                if let stock = selectedStock {
                    stockChip(stock)
                } else {
                    bottomButton(icon: "film", label: "Stock") { showStockSheet = true }
                }
            }
            .frame(width: 90)

            recordButton.frame(maxWidth: .infinity)

            // Right: Queue button — fixed width to match left
            queueButton
                .frame(width: 90)
        }
        .frame(height: 90)
    }

    // MARK: - Stock Chip

    /// Duotone stripe card with ISO + D/T badge overlaid in black.
    /// 5 horizontal slices: 1,2,5 = primary color; 3,4 = secondary.
    private func stockChip(_ stock: FilmStockConfig) -> some View {
        Button {
            showStockSheet = true
        } label: {
            ZStack {
                // Duotone stripe card
                VStack(spacing: 0) {
                    ForEach(0..<5) { idx in
                        let isPrimary = idx == 0 || idx == 1 || idx == 4
                        (isPrimary ? stock.primaryColor : stock.secondaryColor)
                            .frame(height: 6)
                    }
                }
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // ISO + D/T overlay
                Text("\(Int(currentISO))\(stock.lightType)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    // MARK: - Queue Button

    private var queueButton: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                // Progress circle when processing
                if renderQueueViewModel.isProcessing {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 2.5)
                            .frame(width: 34, height: 34)
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(.orange, lineWidth: 2.5)
                            .frame(width: 34, height: 34)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: renderQueueViewModel.isProcessing)
                    }
                    Image(systemName: "list.bullet").font(.title2)
                } else {
                    Image(systemName: "list.bullet").font(.title2)
                }

                // Badge with count
                let count = renderQueueViewModel.pendingCount + (renderQueueViewModel.isProcessing ? 1 : 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(renderQueueViewModel.isProcessing ? .orange : .red)
                        .clipShape(Circle())
                        .offset(x: 10, y: -6)
                }
            }
            Text("Queue").font(.caption2)
            freeSpaceBar.frame(width: 48, height: 3)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { showQueueSheet = true }
    }

    private func bottomButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
    }

    private var recordButton: some View {
        Button {
            if cameraViewModel.isRecording {
                cameraViewModel.stopRecording()
            } else {
                cameraViewModel.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(cameraViewModel.isRecording ? .red : .white)
                    .frame(width: 72, height: 72)
                if cameraViewModel.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 82, height: 82)
                }
            }
        }
        .disabled(cameraViewModel.isSpaceCritical && !cameraViewModel.isRecording)
        .overlay(alignment: .top) {
            if cameraViewModel.isRecording {
                Text(formatDuration(cameraViewModel.recordingDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.8))
                    .clipShape(Capsule())
                    .offset(y: -18)
            }
        }
    }

    private var freeSpaceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.15))
                RoundedRectangle(cornerRadius: 1)
                    .fill(cameraViewModel.isSpaceCritical ? Color.red : Color.white.opacity(0.5))
                    .frame(width: max(0, geo.size.width * CGFloat(cameraViewModel.freeSpacePercent)))
            }
        }
    }

    // MARK: - Error Overlays

    private var errorOverlays: some View {
        Group {
            if let error = cameraViewModel.errorMessage {
                VStack {
                    cameraErrorBanner(error)
                    Spacer()
                }
            }
            if let renderError = renderQueueViewModel.rendererErrorMessage {
                VStack {
                    Spacer()
                    renderErrorBanner(renderError)
                        .padding(.bottom, 140)
                }
            }
        }
    }

    private func cameraErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).foregroundStyle(.white).font(.caption)
            Spacer()
            Button(action: cameraViewModel.dismissError) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func renderErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).foregroundStyle(.white).font(.caption)
            Spacer()
            Button {
                renderQueueViewModel.rendererErrorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Sheets

    private var stockSheet: some View {
        StockSheetView(
            library: library,
            renderQueueViewModel: renderQueueViewModel,
            sourceURL: currentSourceURL,
            isPresented: $showStockSheet,
            selectedStock: $selectedStock,
            currentISO: $currentISO
        )
    }

    private var queueSheet: some View {
        QueueSheetView(
            viewModel: renderQueueViewModel,
            isPresented: $showQueueSheet
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - Stock Sheet

private struct StockSheetView: View {
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    var sourceURL: URL?
    @Binding var isPresented: Bool
    @Binding var selectedStock: FilmStockConfig?
    @Binding var currentISO: Float

    @State private var stocks: [FilmStockConfig] = []
    @State private var localSelection: FilmStockConfig?
    @State private var iso: Float = 400

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                stockPicker
                if localSelection != nil { isoSlider }

                if let url = sourceURL {
                    renderButton(sourceURL: url)
                } else {
                    Text("Record a video to render.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Film Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear {
                stocks = library.videoStocks()
                if localSelection == nil {
                    localSelection = selectedStock ?? stocks.first
                    iso = localSelection.flatMap { library.lastISO(for: $0.stockId) } ?? 400
                }
            }
            .onDisappear {
                if let stock = localSelection {
                    selectedStock = stock
                    currentISO = iso
                    library.setSelectedStock(stock.stockId)
                    library.setISO(iso, for: stock.stockId)
                }
            }
        }
    }

    private var stockPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Stock").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stocks, id: \.stockId) { stock in
                        DuotoneStockCard(
                            stock: stock,
                            isSelected: localSelection?.stockId == stock.stockId,
                            action: {
                                localSelection = stock
                                iso = library.lastISO(for: stock.stockId)
                            }
                        )
                    }
                }
            }
        }
    }

    private var isoSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ISO: \(Int(iso))").font(.headline)
            Slider(value: $iso, in: 100...6400, step: 100)
            HStack {
                Text("100").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("6400").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func renderButton(sourceURL: URL) -> some View {
        Button {
            guard let stock = localSelection else {
                renderQueueViewModel.rendererErrorMessage = "Select a film stock first."
                return
            }
            renderQueueViewModel.enqueue(
                sourceURL: sourceURL,
                stockId: stock.stockId,
                iso: iso
            )
            isPresented = false
        } label: {
            HStack {
                Image(systemName: "play.rectangle.fill")
                Text("Render with \(localSelection?.displayName ?? "Stock")")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Duotone Stock Card

private struct DuotoneStockCard: View {
    let stock: FilmStockConfig
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Duotone swatch
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        ForEach(0..<5) { i in
                            let isPrimary = i == 0 || i == 1 || i == 4
                            (isPrimary ? stock.primaryColor : stock.secondaryColor)
                                .frame(height: geo.size.height / 5.0)
                        }
                    }
                }
                .frame(width: 48, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? .white : .clear, lineWidth: 2)
                }

                Text(stock.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)

                Text(stock.lightType)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? stock.primaryColor : .secondary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 72)
        }
    }
}

// MARK: - Queue Sheet

private struct QueueSheetView: View {
    @State var viewModel: RenderQueueViewModel
    @Binding var isPresented: Bool
    @State private var showAll = false
    @State private var shareTarget: RenderJob?

    private var sessionJobs: [RenderJob] {
        viewModel.jobs.filter { $0.sessionId == RenderJob.currentSessionId }
    }

    private var olderCount: Int {
        viewModel.jobs.count - sessionJobs.count
    }

    private var visibleJobs: [RenderJob] {
        showAll ? viewModel.jobs : sessionJobs
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleJobs.isEmpty {
                    ContentUnavailableView(
                        "No Render Jobs",
                        systemImage: "tray",
                        description: Text("Record a video and select a film stock to start rendering.")
                    )
                } else {
                    List {
                        if let current = visibleJobs.first(where: { $0.status == .processing }) {
                            Section("Processing") { JobRow(job: current, isCurrent: true) }
                        }
                        let pending = visibleJobs.filter { $0.status == .pending }
                        if !pending.isEmpty {
                            Section("Pending (\(pending.count))") {
                                ForEach(pending) { job in
                                    JobRow(job: job)
                                        .swipeActions {
                                            Button("Remove", role: .destructive) {
                                                viewModel.remove(jobId: job.id)
                                            }
                                        }
                                }
                            }
                        }
                        let completed = visibleJobs.filter { $0.status == .completed }
                        if !completed.isEmpty {
                            Section("Completed (\(completed.count))") {
                                ForEach(completed) { job in
                                    Button {
                                        shareVideo(job)
                                    } label: {
                                        JobRow(job: job)
                                    }
                                }
                            }
                        }
                        let failed = visibleJobs.filter { $0.status == .failed }
                        if !failed.isEmpty {
                            Section("Failed (\(failed.count))") {
                                ForEach(failed) { job in
                                    VStack(alignment: .leading, spacing: 4) {
                                        JobRow(job: job)
                                        if let error = job.errorMessage {
                                            Text(error).font(.caption).foregroundStyle(.red)
                                        }
                                        Button("Retry") { viewModel.retry(jobId: job.id) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }

                        if !showAll && olderCount > 0 {
                            Section {
                                Button {
                                    showAll = true
                                } label: {
                                    HStack {
                                        Image(systemName: "clock.badge.checkmark")
                                        Text("Show all (\(olderCount) older jobs)")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
            .sheet(item: $shareTarget) { job in
                if let url = job.outputURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private func shareVideo(_ job: RenderJob) {
        guard job.outputURL != nil else { return }
        shareTarget = job
    }
    }

// MARK: - Job Row

private struct JobRow: View {
    let job: RenderJob
    var isCurrent = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.stockId).font(.caption.weight(.semibold))
                Text("ISO \(Int(job.iso))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            statusLabel
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch job.status {
        case .pending:   Text("Pending").font(.caption2).foregroundStyle(.secondary)
        case .processing:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Rendering").font(.caption2).foregroundStyle(.orange)
            }
        case .completed: Label("Done", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }
}

// MARK: - Share Sheet

import UIKit

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}