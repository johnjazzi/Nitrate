import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Example photos are offline LUT-only illustrations, not captured Apple Log
/// frames. Switching stock changes the image, never the selected scene/page.
struct StockSamplePreview: View {
    let stock: FilmStockConfig?
    @State private var sceneID = "daylight"
    private static let catalog = Result { try StockSampleCatalog.load() }

    var body: some View {
        switch Self.catalog {
        case .success(let catalog):
            VStack(spacing: 10) {
                pages(catalog)
                    .frame(height: 310)
                HStack(spacing: 7) {
                    ForEach(catalog.scenes) { scene in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { sceneID = scene.id }
                        } label: {
                            Circle()
                                .fill(sceneID == scene.id ? Color.accentColor : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Example photo: \(scene.title)")
                        .accessibilityAddTraits(sceneID == scene.id ? [.isSelected] : [])
                    }
                }
                Text(catalog.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                if !catalog.scenes.contains(where: { $0.id == sceneID }), let first = catalog.scenes.first {
                    sceneID = first.id
                }
            }
        case .failure:
            ContentUnavailableView("Example photos unavailable", systemImage: "photo.on.rectangle.angled",
                                   description: Text("You can still choose a stock and render your recording."))
                .frame(height: 200)
        }
    }

    private func pages(_ catalog: StockSampleCatalog) -> some View {
        TabView(selection: $sceneID) {
            ForEach(catalog.scenes) { scene in
                StockSamplePhotoPage(
                    url: scene.imageURL(stockID: stock?.stockId, directory: catalog.directory),
                    title: scene.title, stockName: stock?.displayName ?? "Neutral")
                    .id("\(scene.id):\(stock?.stockId ?? "neutral")")
                    .padding(.horizontal, 4)
                    .tag(scene.id)
            }
        }
#if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
#endif
        .accessibilityIdentifier("stock.examplePhotos")
    }
}

private struct StockSamplePhotoPage: View {
    let url: URL?
    let title: String
    let stockName: String
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                StockSamplePhoto(image: image, title: title, stockName: stockName)
            } else if failed || url == nil {
                ContentUnavailableView("Preview unavailable", systemImage: "photo",
                                       description: Text("No example preview for this stock."))
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                StockSamplePhoto.load(url)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// Separate photo face permits native render checks without treating a snapshot
/// as proof of a UIKit paging gesture.
struct StockSamplePhoto: View {
    let image: CGImage
    let title: String
    let stockName: String

    var body: some View {
        GeometryReader { geometry in
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                        Text(stockName).font(.headline).foregroundStyle(.white)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .accessibilityLabel("\(title), \(stockName), illustrative color preview")
        }
    }

    nonisolated static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
