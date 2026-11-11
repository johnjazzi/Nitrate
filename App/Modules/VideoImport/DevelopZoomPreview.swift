#if os(iOS)
import SwiftUI
import CoreGraphics

/// Aspect-fit both inline and enlarged: the preview never silently crops the source.
struct DevelopExpandableStill: View {
    let image: CGImage
    let label: String
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Expand image. Pinch to zoom in the expanded view.")
        .fullScreenCover(isPresented: $expanded) {
            DevelopZoomPreview(image: image, label: label)
        }
    }
}

struct DevelopZoomPreview: View {
    let image: CGImage
    let label: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var drag = CGSize.zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(DevelopWorkflowPresentation.zoom(scale * magnification))
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .gesture(MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            scale = DevelopWorkflowPresentation.zoom(scale * value.magnification)
                            if scale == 1 { offset = .zero }
                        })
                    .simultaneousGesture(DragGesture()
                        .updating($drag) { value, state, _ in
                            if scale > 1 { state = value.translation }
                        }
                        .onEnded { value in
                            guard scale > 1 else { return }
                            // Keep part of the image reachable after panning.
                            let xLimit = geometry.size.width * (scale - 1) / 2
                            let yLimit = geometry.size.height * (scale - 1) / 2
                            offset = CGSize(
                                width: min(max(offset.width + value.translation.width, -xLimit), xLimit),
                                height: min(max(offset.height + value.translation.height, -yLimit), yLimit))
                        })
                    .onTapGesture(count: 2, perform: reset)
                    .accessibilityLabel(label)
                    .accessibilityValue("Zoom \(Int(scale * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: scale = DevelopWorkflowPresentation.zoom(scale + 1)
                        case .decrement: scale = DevelopWorkflowPresentation.zoom(scale - 1)
                        @unknown default: break
                        }
                        if scale == 1 { offset = .zero }
                    }
            }
            .clipped()
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", action: reset)
                        .accessibilityIdentifier("develop.zoom.reset")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("develop.zoom.done")
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private func reset() {
        scale = 1
        offset = .zero
    }
}
#endif
