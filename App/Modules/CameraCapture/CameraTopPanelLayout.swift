import SwiftUI

struct CameraTopPanelGeometry {
    let settings: CGRect
    let manual: CGRect
    let lens: CGRect
    let status: CGRect
    let diagnostics: CGRect
    let height: CGFloat

    /// Keep the shipped framed-viewfinder input unchanged when the status leaves
    /// the toolbar. Its old quarter-turn row was 112pt, below 8pt + 50pt chrome.
    /// Actual toolbar bounds still govern the floating/manual overlays.
    static func framingBottom(toolbarBottom: CGFloat, rotationDegrees: Double) -> CGFloat {
        abs(rotationDegrees) == 90 ? max(toolbarBottom, 8 + 50 + 112) : toolbarBottom
    }

    init(width: CGFloat, statusSize: CGSize, diagnosticsHeight: CGFloat) {
        // A quarter-turned face lives in a non-sizing physical-edge overlay.
        // Never reserve its old tall toolbar slot (or let timer ticks size chrome).
        let toolbarStatusSize = statusSize.height > statusSize.width ? .zero : statusSize
        let rowHeight = max(toolbarStatusSize.height, diagnosticsHeight)
        settings = CGRect(x: 0, y: 0, width: 44, height: 44)
        manual = CGRect(x: 56, y: 0, width: 44, height: 44)
        lens = CGRect(x: width - 84, y: 0, width: 84, height: 44)
        status = CGRect(x: (width - toolbarStatusSize.width) / 2,
                        y: 50 + (rowHeight - toolbarStatusSize.height) / 2,
                        width: toolbarStatusSize.width, height: toolbarStatusSize.height)
        diagnostics = CGRect(x: 0, y: 50 + (rowHeight - diagnosticsHeight) / 2,
                             width: 64, height: diagnosticsHeight)
        height = 50 + rowHeight
    }
}

/// Ordered children: settings, manual, lens, complete status face, diagnostic rail.
struct CameraTopPanelLayout: Layout {
    private func geometry(width: CGFloat, subviews: Subviews) -> CameraTopPanelGeometry {
        CameraTopPanelGeometry(width: width, statusSize: subviews[3].sizeThatFits(.unspecified),
                               diagnosticsHeight: subviews[4].sizeThatFits(ProposedViewSize(width: 64, height: nil)).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 5 else { return .zero }
        let width = proposal.width ?? 288
        return CGSize(width: width, height: geometry(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let geometry = geometry(width: bounds.width, subviews: subviews)
        let frames = [geometry.settings, geometry.manual, geometry.lens, geometry.status, geometry.diagnostics]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
