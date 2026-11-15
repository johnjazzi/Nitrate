import SwiftUI
import UIKit

/// Native zoom/pan for an image nested inside the History page swiper. A fitted
/// image does not bounce or consume horizontal scrolling; zoomed content pans.
struct HistoryZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String

    func makeUIView(context: Context) -> HistoryImageScrollView {
        let view = HistoryImageScrollView()
        view.setImage(image, label: label)
        return view
    }

    func updateUIView(_ view: HistoryImageScrollView, context: Context) {
        view.setImage(image, label: label)
    }
}

final class HistoryImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var viewport = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetZoom))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { return nil }

    func setImage(_ image: UIImage, label: String) {
        imageView.accessibilityLabel = label
        guard imageView.image !== image else { return }
        imageView.image = image
        viewport = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != viewport, bounds.width > 0, bounds.height > 0,
           let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            viewport = bounds.size
            setZoomScale(1, animated: false)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero,
                size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = imageView.frame.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        imageView.accessibilityValue = "Zoom \(Int(zoomScale * 100)) percent"
    }

    private func centerImage() {
        contentInset = UIEdgeInsets(
            top: max((bounds.height - contentSize.height) / 2, 0), left: max((bounds.width - contentSize.width) / 2, 0),
            bottom: 0, right: 0)
    }

    @objc private func resetZoom() {
        setZoomScale(1, animated: true)
    }
}
