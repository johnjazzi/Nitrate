import CoreText
import SwiftUI

/// App-wide typography for Nitrate.
///
/// Every string of text renders in the bundled Barlow Medium
/// face (`Fonts/Barlow-Medium.ttf`, licensed under the SIL Open
/// Font License and shipped alongside its license text). The family has a
/// single available weight, so the app's hierarchy is expressed through point
/// size only; a call site may still apply `.bold()`/`.weight(_:)` for semantic
/// emphasis, which SwiftUI synthesises on top of the face.
///
/// The face is declared under `UIAppFonts` for iOS. `registerBundledFont()`
/// also loads it explicitly through CoreText, so the family is available in
/// every process — including the macOS test host, which never reads an iOS
/// `UIAppFonts` list.
enum NitrateTypography {
    /// PostScript name of the bundled face, as recorded in the font's `name`
    /// table. This is the identifier passed to `Font.custom` and CoreText, not
    /// the human-readable family name ("Barlow Medium").
    static let postScriptName = "Barlow-Medium"

    /// File name of the bundled face inside the `Fonts` resource directory.
    static let resourceFileName = "Barlow-Medium"
    static let resourceFileExtension = "ttf"
    static let resourceSubdirectory = "Fonts"

    // MARK: - Fonts

    /// Base point size for a Dynamic Type text style, used to build the scaled
    /// custom face. Sizes follow the system's default (Large) content size; the
    /// user's preferred content size then scales them.
    static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// The bundled face at a Dynamic Type text style, scaled by the user's
    /// preferred content size.
    static func font(_ style: Font.TextStyle) -> Font {
        Font.custom(postScriptName, size: baseSize(for: style), relativeTo: style)
    }

    /// The bundled face at an explicit point size. The point size is preserved
    /// exactly; only the family changes. The text scales with the user's
    /// preferred content size relative to `style`.
    static func font(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        Font.custom(postScriptName, size: size, relativeTo: style)
    }

    // MARK: - Registration

    /// Guards the one CoreText registration per process.
    @MainActor private static var didRegister = false

    /// Locates the bundled face in the app, the test host, or any bundle that
    /// carries it. Returns `nil` when no bundle contains the resource.
    static func bundledFontURL(in bundles: [Bundle] = candidateBundles()) -> URL? {
        for bundle in bundles {
            if let url = bundle.url(forResource: resourceFileName,
                                    withExtension: resourceFileExtension,
                                    subdirectory: resourceSubdirectory) {
                return url
            }
            if let url = bundle.url(forResource: resourceFileName,
                                    withExtension: resourceFileExtension) {
                return url
            }
        }
        return nil
    }

    /// Registers the bundled face with CoreText exactly once per process.
    ///
    /// Idempotent: safe to call from `App.init` and from tests. Returns `true`
    /// when the face is registered (or was already), `false` when the resource
    /// could not be found or CoreText rejected it.
    @MainActor @discardableResult
    static func registerBundledFont() -> Bool {
        if didRegister { return true }
        guard let url = bundledFontURL() else { return false }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        let resolved = CTFontCopyPostScriptName(CTFontCreateWithName(postScriptName as CFString, 12, nil)) as String
        didRegister = registered || resolved == postScriptName
        return didRegister
    }

    /// Bundles that may carry the shipped face, in search order.
    static func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.main]
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(contentsOf: Bundle.allFrameworks)
        return bundles
    }
}

#if canImport(UIKit)
import UIKit

extension NitrateTypography {
    /// The bundled face as a `UIFont` at an explicit point size, scaled with the
    /// user's preferred content size. Used by UIKit-drawn camera readouts, which
    /// cannot read a SwiftUI `Font`.
    @MainActor static func uiFont(size: CGFloat, relativeTo style: UIFont.TextStyle = .body) -> UIFont {
        let base = UIFont(name: postScriptName, size: size) ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}
#endif
