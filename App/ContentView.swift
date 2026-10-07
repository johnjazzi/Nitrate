import SwiftUI

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
    @State private var currentSourceURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Single CameraView — always in the hierarchy with identical modifiers.
            // Frame mode toggles clip shape & padding only — no view identity change.
            cameraLayer

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, showFramedPreview ? 8 : 0)

                if showFramedPreview {
                    Spacer()
                } else {
                    Spacer().frame(height: 0)
                }

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
            if let url = newURL {
                currentSourceURL = url
                showStockSheet = true
            }
        }
    }

    // MARK: - Camera Layer

    /// The camera layer is always present at full size.
    /// In frame mode we clip it and overlay a border — the view itself never changes identity.
    private var cameraLayer: some View {
        CameraView(viewModel: cameraViewModel)
            .ignoresSafeArea()
            .clipShape(showFramedPreview
                ? AnyShape(RoundedRectangle(cornerRadius: 16))
                : AnyShape(Rectangle()))
            .padding(.horizontal, showFramedPreview ? 8 : 0)
            .overlay {
                if showFramedPreview {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.25), lineWidth: 2)
                        .padding(.horizontal, 8)
                }
            }
    }

    private var topBar: some View {
        HStack {
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
            .padding(.leading, 16)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            bottomButton(icon: "film", label: "Stock") { showStockSheet = true }
            recordButton.frame(maxWidth: .infinity)
            queueButton
        }
        .frame(height: 90)
    }

    private var queueButton: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "list.bullet").font(.title2)
                if renderQueueViewModel.pendingCount > 0 {
                    Text("\(renderQueueViewModel.pendingCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.red)
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
            isPresented: $showStockSheet
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

// MARK: - View Extension

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Stock Sheet

private struct StockSheetView: View {
    let library: FilmStockLibrary
    let renderQueueViewModel: RenderQueueViewModel
    var sourceURL: URL?
    @Binding var isPresented: Bool

    @State private var stocks: [FilmStockConfig] = []
    @State private var selectedStock: FilmStockConfig?
    @State private var iso: Float = 400

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                stockPicker
                if selectedStock != nil { isoSlider }

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
                if selectedStock == nil, let first = stocks.first {
                    selectStock(first)
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
                        StockCard(
                            stock: stock,
                            isSelected: selectedStock?.stockId == stock.stockId,
                            action: { selectStock(stock) }
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
            guard let stock = selectedStock else {
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
                Text("Render with \(selectedStock?.displayName ?? "Stock")")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func selectStock(_ stock: FilmStockConfig) {
        selectedStock = stock
        iso = library.lastISO(for: stock.stockId)
    }
}

// MARK: - Queue Sheet

private struct QueueSheetView: View {
    @State var viewModel: RenderQueueViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.jobs.isEmpty {
                    ContentUnavailableView(
                        "No Render Jobs",
                        systemImage: "tray",
                        description: Text("Record a video and select a film stock to start rendering.")
                    )
                } else {
                    List {
                        if let current = viewModel.currentJob {
                            Section("Processing") { JobRow(job: current, isCurrent: true) }
                        }
                        let pending = viewModel.jobs.filter { $0.status == .pending }
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
                        let completed = viewModel.completedJobs
                        if !completed.isEmpty {
                            Section("Completed (\(completed.count))") {
                                ForEach(completed) { job in JobRow(job: job) }
                            }
                        }
                        let failed = viewModel.jobs.filter { $0.status == .failed }
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
        }
    }
}

private struct JobRow: View {
    let job: RenderJob
    var isCurrent = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.stockId).font(.headline)
                Text("ISO \(Int(job.iso))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:  Image(systemName: "clock").foregroundStyle(.secondary)
        case .processing: ProgressView()
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Stock Card

private struct StockCard: View {
    let stock: FilmStockConfig
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(stockColor)
                    .frame(width: 80, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                Text(stock.displayName).font(.caption).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var stockColor: Color {
        if stock.stockId.contains("250d") { return .orange.opacity(0.6) }
        if stock.stockId.contains("500t85a") { return .purple.opacity(0.5) }
        if stock.stockId.contains("500t") { return .blue.opacity(0.5) }
        if stock.stockId.contains("200t") { return .teal.opacity(0.5) }
        if stock.stockId.contains("50d") { return .mint.opacity(0.5) }
        return .gray
    }
}