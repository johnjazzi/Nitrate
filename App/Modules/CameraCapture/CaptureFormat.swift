import Foundation

/// Which sensor format the Video capture graph records.
///
/// `uhd16x9` is the shipping 3840x2160 10-bit 4:2:2 Apple Log 2 format and the
/// default: an install that has never touched the row records exactly what it
/// recorded before.
///
/// `openGate2K` is the native 4:3 1920x1440 10-bit 4:2:2 Apple Log 2 format.
/// It is **not** a crop of UHD: the sensor is read at full height and the
/// delivered file is 1920x1440, so framing is decided at capture instead of in
/// the renderer. It is only offered where the hardware exposes that format;
/// a device without it hides the option, and a stored selection the device
/// cannot honour fails visibly instead of falling back to UHD.
enum CaptureFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case uhd16x9 = "uhd-16x9"
    case openGate2K = "open-gate-2k"

    /// `@AppStorage`/`UserDefaults` key. The stored value is the raw string, and
    /// the same string is written into the delivered metadata.
    static let preferenceKey = "capture.format"

    /// UHD 16:9 is the shipping default.
    static let defaultValue: CaptureFormat = .uhd16x9

    var id: String { rawValue }

    /// Missing, empty or unrecognised stored values resolve to the default
    /// rather than inventing a format.
    static func resolved(_ raw: String?) -> CaptureFormat {
        raw.flatMap(CaptureFormat.init(rawValue:)) ?? defaultValue
    }

    /// Read the persisted preference. `string(forKey:)` keeps an absent value
    /// distinct from a deliberately stored one, so only the absent case falls
    /// through to the default.
    static func load(from defaults: UserDefaults = .standard) -> CaptureFormat {
        resolved(defaults.string(forKey: preferenceKey))
    }

    /// Encoded dimensions of one landscape frame, in pixels.
    var width: Int32 {
        switch self {
        case .uhd16x9: return 3840
        case .openGate2K: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .uhd16x9: return 2160
        case .openGate2K: return 1440
        }
    }

    var size: (width: Int32, height: Int32) { (width, height) }

    /// Open gate is already 4:3, so a 4:3 delivery has no crop to apply.
    var isOpenGate: Bool { self == .openGate2K }

    /// The 2K open gate format is contracted to 10-bit 4:2:2. The UHD path keeps
    /// its historical 4:2:0-first preference; a 2K 4:2:0 format is never a
    /// substitute for the 4:2:2 one.
    var requiresTenBit422: Bool { isOpenGate }

    /// Settings label. It states the shape and size, not the request.
    var title: String {
        switch self {
        case .uhd16x9: return "UHD 16:9"
        case .openGate2K: return "Open Gate 2K"
        }
    }

    /// One-line settings detail, including the fact that 2K is not a crop.
    var detail: String {
        switch self {
        case .uhd16x9:
            return "3840x2160, 10-bit Apple Log 2. The shipping widescreen capture."
        case .openGate2K:
            return "1920x1440 native 4:3, 10-bit Apple Log 2. Full sensor height, "
                + "not cropped to 16:9."
        }
    }

    /// Delivered-shape description used by the framing row while open gate is
    /// active: there is no crop left to choose.
    var deliveredFramingDescription: String {
        switch self {
        case .uhd16x9: return "16:9"
        case .openGate2K: return "4:3 (whole frame)"
        }
    }
}
