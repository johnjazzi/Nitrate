import SwiftUI

struct CameraTopPanelGeometry {
    let settings: CGRect
    let manual: CGRect
    let lens: CGRect
    let status: CGRect
    let diagnostics: CGRect
    let height: CGFloat

    /// The framed viewfinder input is the stationary toolbar's own bottom edge.
    /// The previous landscape branch reserved a phantom 112pt quarter-turn row
    /// (`max(toolbarBottom, 170)`), which shrank the preview only while a hold
    /// was sideways. That reservation is gone: one rotation-agnostic bottom edge
    /// governs portrait and both landscape holds. The two-argument signature is
    /// kept so existing callers and their bounds measurement stay unchanged.
    static func framingBottom(toolbarBottom: CGFloat, rotationDegrees: Double) -> CGFloat {
        toolbarBottom
    }

    /// `lensSize` is the round trigger's measured natural width, never a fixed
    /// reserve. A quarter-turned face lives in a non-sizing physical-edge
    /// overlay, so it is never a toolbar slot. The portrait timer is a pure
    /// overlay position: centered on the toolbar at its natural size, never
    /// right-slotted against the lens and never resized to fit a control.
    /// The toolbar height is the stationary 44pt keys plus the existing 6pt
    /// gap — it never tracks the diagnostic rail or the measured status size,
    /// so idle, live, DEBUG/FAULT and both holds share one toolbar height.
    init(width: CGFloat, statusSize: CGSize, lensSize: CGSize = CGSize(width: 44, height: 44),
         diagnosticsHeight: CGFloat) {
        let toolbarStatusSize = statusSize.height > statusSize.width ? .zero : statusSize
        settings = CGRect(x: 0, y: 0, width: 44, height: 44)
        manual = CGRect(x: 56, y: 0, width: 44, height: 44)
        if toolbarStatusSize == .zero {
            lens = CGRect(x: width - lensSize.width, y: (44 - lensSize.height) / 2,
                          width: lensSize.width, height: lensSize.height)
            status = .zero
        } else {
            // Portrait: horizontally screen-centered, independent of the keys
            // to its left and right, at its own measured size.
            lens = .zero
            status = CGRect(x: (width - toolbarStatusSize.width) / 2, y: (44 - toolbarStatusSize.height) / 2,
                            width: toolbarStatusSize.width, height: toolbarStatusSize.height)
        }
        // Bookkeeping only, for the existing geometry contracts. The DEBUG/FAULT
        // rail now renders in a non-sizing sibling overlay, so this rect is
        // never used to size the toolbar or the framed preview.
        diagnostics = CGRect(x: 0, y: 50, width: 64, height: diagnosticsHeight)
        height = 50
    }
}

/// Ordered children: settings, manual, lens, complete status face, diagnostic rail.
struct CameraTopPanelLayout: Layout {
    private func geometry(width: CGFloat, subviews: Subviews) -> CameraTopPanelGeometry {
        CameraTopPanelGeometry(width: width, statusSize: subviews[3].sizeThatFits(.unspecified),
                               lensSize: subviews[2].sizeThatFits(.unspecified),
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
