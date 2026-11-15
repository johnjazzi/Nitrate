import SwiftUI

/// Decoded grid pixels live only with the on-screen cell, not with every job.
/// The queue continues to own its existing compressed receipt image.
struct HistoryGridThumbnail: View {
    let jpeg: Data
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .task(id: jpeg) {
            let decoded = await Task.detached(priority: .utility) {
                RenderReceiptService.gridPoster(from: jpeg)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onDisappear { image = nil }
    }
}
