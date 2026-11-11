import CoreGraphics

/// On-screen framing guide for a cropped delivery.
///
/// The guide is display-only geometry: it never resizes, moves or re-clips the
/// preview surface, so `FramedPreviewLayout` and the tap-to-focus point mapping
/// (`AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`)
/// keep working on exactly the rect they used before. The caller draws a
/// non-interactive scrim outside the returned rect.
///
/// Assumptions, both fixed by the shipping capture contract:
///
/// * The recorded original is the 4K 16:9 Apple Log 2 format
///   (`CameraCaptureFormatPolicy` selects 3840x2160), so the guide can resolve a
///   real crop instead of inventing an aspect.
/// * The app is portrait-locked (`UISupportedInterfaceOrientations`) and the
///   framed preview rect is portrait, so the encoded landscape frame is shown
///   rotated a quarter turn: its width becomes the display height.
enum DeliveryFramingGuide {
    /// Encoded size of the recorded original the renderer crops.
    static let sourceSize = CGSize(width: 3840, height: 2160)

    /// Where the delivered frame will land inside `previewRect`, or nil when the
    /// delivery is the whole frame (nothing to guide) or the geometry is empty.
    ///
    /// The preview shows the recorded frame at aspect-fill, so parts of the
    /// frame can extend beyond the rect; the delivered rect is clipped to the
    /// visible rect, which is what the operator can actually frame with.
    static func deliveredRect(in previewRect: CGRect, framing: DeliveryFraming) -> CGRect? {
        guard previewRect.width > 0, previewRect.height > 0 else { return nil }
        let delivery = framing.delivery(forSourceSize: sourceSize)
        guard delivery.isCropped else { return nil }

        // Rotate the encoded frame into the portrait preview: the encoded width
        // becomes the display height and vice versa.
        let displayedSourceWidth = CGFloat(delivery.sourceHeight)
        let displayedSourceHeight = CGFloat(delivery.sourceWidth)
        let scale = max(previewRect.width / displayedSourceWidth,
                        previewRect.height / displayedSourceHeight)
        let displayedCropWidth = CGFloat(delivery.deliveredHeight) * scale
        let displayedCropHeight = CGFloat(delivery.deliveredWidth) * scale
        let rect = CGRect(x: previewRect.midX - displayedCropWidth / 2,
                          y: previewRect.midY - displayedCropHeight / 2,
                          width: displayedCropWidth,
                          height: displayedCropHeight)
        let clipped = rect.intersection(previewRect)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}
