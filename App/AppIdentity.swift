import Foundation

/// Product identity shared by the UI. `INFOPLIST_KEY_CFBundleDisplayName` in
/// project.yml is the home-screen counterpart — keep the two in sync.
enum AppIdentity {
    static let name = "Nitrate"
}

/// Version strings resolve from the bundle, which Xcode fills from
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in project.yml.
///
/// Formatting is split from the bundle lookup so it can be tested without a
/// host application.
enum AppVersion {
    enum Stage: String {
        case alpha
        case beta
    }

    static let fallbackMarketing = "0.0.0"
    static let fallbackBuild = "0"

    /// The stage suffix shown by the splash and Settings → About. TestFlight
    /// builds are `.beta`; set this to `nil` for an App Store release. Both
    /// surfaces read this value, so they cannot disagree.
    static let stage: Stage? = .beta

    static func marketing(bundle: Bundle = .main) -> String {
        string(forKey: "CFBundleShortVersionString", in: bundle) ?? fallbackMarketing
    }

    static func build(bundle: Bundle = .main) -> String {
        string(forKey: "CFBundleVersion", in: bundle) ?? fallbackBuild
    }

    /// `0.1.3 (3) · BETA`
    static func display(marketing: String, build: String, stage: Stage?) -> String {
        let base = "\(marketing) (\(build))"
        guard let stage else { return base }
        return "\(base) · \(stage.rawValue.uppercased())"
    }

    static func current(bundle: Bundle = .main) -> String {
        display(marketing: marketing(bundle: bundle), build: build(bundle: bundle), stage: stage)
    }

    private static func string(forKey key: String, in bundle: Bundle) -> String? {
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
