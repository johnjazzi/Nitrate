import AppKit
import SwiftUI
import Testing

struct CameraRulerContrastTests {
    @Test func preferenceIsOffByDefaultAndHasNoClassicEffect() {
        #expect(CameraRulerContrastPreference.preferenceKey == "camera.highContrastRulers")
        #expect(!CameraRulerContrastPreference.defaultValue)
        #expect(!EnvironmentValues().cameraRulerHighContrast)
        #expect(CameraRulerContrastPreference.backdropOpacity(style: .minimal, enabled: false) == 0)
        #expect(CameraRulerContrastPreference.backdropOpacity(style: .classic, enabled: true) == 0)
        let strong = CameraRulerContrastPreference.backdropOpacity(style: .minimal, enabled: true)
        #expect(strong > 0.5 && strong < 1, "Strong remains translucent, not a solid plate")
    }

    @MainActor
    @Test func highContrastDarkensABrightBackdropWithoutChangingGeometry() throws {
        func center(style: CameraUIStyle, enabled: Bool) throws -> (CGFloat, CGSize) {
            let view = Color.clear.frame(width: 64, height: 96)
                .cameraRulerBackdrop()
                .background(.white)
                .environment(\.cameraUIStyle, style)
                .environment(\.cameraRulerHighContrast, enabled)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let color = try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
            return (color.redComponent, CGSize(width: image.width, height: image.height))
        }
        let off = try center(style: .minimal, enabled: false)
        let on = try center(style: .minimal, enabled: true)
        let classic = try center(style: .classic, enabled: true)
        #expect(on.0 < off.0 * 0.5, "Backing must visibly darken bright footage behind the ruler")
        #expect(classic.0 == off.0, "Classic remains unchanged even with the preference saved on")
        #expect(on.1 == off.1)
        #expect(classic.1 == off.1)
    }
}
