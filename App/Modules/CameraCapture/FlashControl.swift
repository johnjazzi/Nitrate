import Foundation

// MARK: - Sync point

/// Where in the exposure window the lamp is lit.
///
/// The phone has one LED behind the lens and no shutter curtain, so a "flash"
/// is that LED held on for a while. `front` lights the window from its first
/// instant; `rear` would end the light at the closing edge and is not offered
/// yet — the value stays in the model so it can be added without migrating a
/// stored preference, and so a file written by a build that has it still reads.
enum FlashSync: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case front
    case rear
}

// MARK: - Settings

/// The operator's lamp settings: one global video level, and a photo intensity
/// plus the fraction of the exposure window the lamp covers.
///
/// Nothing here is per stock. The video level is one app-wide setting read once
/// at take start; the photo values are read at the shutter tap. Both are
/// requests to the hardware, not calibrated light — see `FlashTorchController`.
struct FlashSettings: Codable, Equatable, Sendable {
    /// Video: how hard the lamp is driven for a whole take, 0...1. Zero is off
    /// and must behave exactly like a build without the control.
    var videoLevel: Double
    /// Photo: how hard the lamp is driven while it is lit, 0...1.
    var photoIntensity: Double
    /// Photo: how much of the exposure window the lamp covers, 5...100.
    var photoDurationPercent: Double

    static let intensityRange: ClosedRange<Double> = 0...1
    static let durationRange: ClosedRange<Double> = 5...100

    /// 0 %, full intensity, the whole window, lamp off. A photo taken with this
    /// is the photo this app took before the control existed.
    static let standard = FlashSettings()

    init(videoLevel: Double = 0, photoIntensity: Double = 0,
         photoDurationPercent: Double = 100) {
        self.videoLevel = Self.clamped(videoLevel, to: Self.intensityRange, fallback: 0)
        self.photoIntensity = Self.clamped(photoIntensity, to: Self.intensityRange, fallback: 0)
        self.photoDurationPercent = Self.clamped(photoDurationPercent, to: Self.durationRange,
                                                 fallback: 100)
    }

    /// A non-finite request is not a value. It falls back to this setting's own
    /// default rather than to an arbitrary edge of the range, so a corrupt read
    /// cannot quietly become full power.
    static func clamped(_ value: Double, to range: ClosedRange<Double>,
                        fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    var isVideoLampOn: Bool { videoLevel > 0 }

    var isPhotoLampOn: Bool { photoIntensity > 0 }

    /// Whole percent: the unit the control shows and the metadata records.
    var videoPercent: Int { Int((videoLevel * 100).rounded()) }

    var photoPercent: Int { Int((photoIntensity * 100).rounded()) }

    var durationPercent: Int { Int(photoDurationPercent.rounded()) }

    /// The closed pill. Video reads the level, because the level is the only
    /// thing it has. The photo pill reads the *duration*: the duration is the
    /// number that changes the picture, and the intensity is one tap away.
    func pillText(photoMode: Bool) -> String {
        if photoMode { return isPhotoLampOn ? "\(durationPercent)%" : "OFF" }
        return isVideoLampOn ? "\(videoPercent)%" : "OFF"
    }

    /// Spoken value for the pill, matching what it reads.
    func accessibilityValue(photoMode: Bool) -> String {
        if photoMode {
            guard isPhotoLampOn else { return "Lamp off" }
            return "Lamp at \(photoPercent) percent for \(durationPercent) percent of the exposure"
        }
        guard isVideoLampOn else { return "Lamp off" }
        return "Lamp at \(videoPercent) percent for the take"
    }
}

// MARK: - Timing

/// What the lamp is asked to do inside one exposure window.
///
/// `lit` carries fractions of the window, not seconds: the window itself is the
/// applied exposure read back from the device, and the fractions are what make
/// `rear` the exact mirror of `front`.
enum FlashTiming: Equatable, Sendable {
    /// The exposure is too short for the lamp to be shaped at all, with the
    /// reason to show beside the disabled control.
    case unshapable(String)
    case lit(start: Double, end: Double)

    /// The lit interval as fractions of the window, end guaranteed above start.
    var interval: ClosedRange<Double>? {
        guard case .lit(let start, let end) = self else { return nil }
        return min(start, end)...max(start, end)
    }

    var isLit: Bool { interval != nil }

    /// The reason the control is unavailable, when it is.
    var disabledReason: String? {
        guard case .unshapable(let reason) = self else { return nil }
        return reason
    }

    /// How much of the window the lamp covers, in whole percent.
    var durationPercent: Int? {
        guard let interval else { return nil }
        return Int(((interval.upperBound - interval.lowerBound) * 100).rounded())
    }

    /// The lit interval in seconds of an `exposure` window.
    func seconds(in exposure: Double) -> ClosedRange<Double>? {
        guard let interval, exposure.isFinite, exposure > 0 else { return nil }
        return (interval.lowerBound * exposure)...(interval.upperBound * exposure)
    }
}

enum FlashTimingPolicy {
    /// PROVISIONAL AND UNMEASURED. This is a placeholder floor, not a
    /// measurement of this phone: the real value is the exposure at which the
    /// LED reaches 90 % of the requested output, which has not been measured
    /// (spec §5 item 1). It is set to 1/30 s because that is the slowest
    /// shutter the shipped photo ladder reaches before the lamp's ramp stops
    /// dominating the window — when the ramp is measured this constant is the
    /// only thing that changes.
    static let minimumShapableExposure: Double = 1.0 / 30.0

    /// One line, in the operator's terms, for the disabled duration control.
    static let unshapableReason =
        "The shutter is faster than 1/30 s, so the lamp cannot be shaped."

    /// The interval the lamp is lit for, given the *applied* exposure window.
    ///
    /// Below the shaping floor this returns `.unshapable` rather than a clamped
    /// interval: a duration control that silently covers the whole window is a
    /// control that lies about what it did.
    static func timing(exposure: Double, durationPercent: Double, sync: FlashSync) -> FlashTiming {
        guard exposure.isFinite, exposure > 0 else {
            return .unshapable("The camera did not report a usable exposure.")
        }
        guard exposure >= minimumShapableExposure else { return .unshapable(unshapableReason) }
        let duration = FlashSettings.clamped(durationPercent, to: FlashSettings.durationRange,
                                             fallback: 100) / 100
        switch sync {
        case .off:
            // No sync chosen: the lamp is not shaped, it simply holds for the
            // whole window at whatever intensity it was given.
            return .lit(start: 0, end: 1)
        case .front:
            return .lit(start: 0, end: duration)
        case .rear:
            return .lit(start: 1 - duration, end: 1)
        }
    }
}

// MARK: - What the light actually did

/// The mode a file records. `continuous` is video: the lamp held for the whole
/// take. The photo modes name where in the window the light landed.
enum FlashMode: String, Codable, Equatable, Sendable {
    case off
    case front
    case rear
    case continuous
}

/// The lamp as it actually ran: read back from the device and the applied
/// exposure, never from what the slider asked for. This is what the metadata
/// says and what the diagnostics quote.
struct FlashRecord: Equatable, Sendable {
    var mode: FlashMode
    /// Whole percent of the level the lamp was driven at (0 when off).
    var intensityPercent: Int
    /// Photo only: whole percent of the exposure window the lamp covered.
    /// Nil for video, which has no window to shape.
    var durationPercent: Int?
    /// The exposure window the timing was computed against, in seconds.
    var exposureSeconds: Double?
    /// Present when the hardware refused the level (thermal, most often). The
    /// take still runs; the file says the lamp did not.
    var refusalReason: String?

    static let off = FlashRecord(mode: .off, intensityPercent: 0)

    var wasRefused: Bool { refusalReason != nil }

    /// Did the lamp actually light? A refused request did not.
    var didFire: Bool { mode != .off }

    init(mode: FlashMode, intensityPercent: Int, durationPercent: Int? = nil,
         exposureSeconds: Double? = nil, refusalReason: String? = nil) {
        self.mode = mode
        self.intensityPercent = min(max(intensityPercent, 0), 100)
        self.durationPercent = durationPercent.map { min(max($0, 0), 100) }
        self.exposureSeconds = exposureSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.refusalReason = refusalReason
    }

    /// A video take's lamp: `continuous` at the locked level, `off` at zero.
    static func video(level: Double, exposureSeconds: Double?, refusalReason: String?) -> FlashRecord {
        let percent = Int((FlashSettings.clamped(level, to: FlashSettings.intensityRange,
                                                 fallback: 0) * 100).rounded())
        guard refusalReason == nil, percent > 0 else {
            return FlashRecord(mode: .off, intensityPercent: percent,
                               exposureSeconds: exposureSeconds, refusalReason: refusalReason)
        }
        return FlashRecord(mode: .continuous, intensityPercent: percent,
                           exposureSeconds: exposureSeconds)
    }

    /// A photo's lamp. A refused or disabled lamp records `off` with the reason,
    /// because that is what the sensor saw.
    static func photo(settings: FlashSettings, timing: FlashTiming,
                      exposureSeconds: Double, refusalReason: String?) -> FlashRecord {
        guard refusalReason == nil, settings.isPhotoLampOn else {
            return FlashRecord(mode: .off, intensityPercent: settings.photoPercent,
                               exposureSeconds: exposureSeconds, refusalReason: refusalReason)
        }
        return FlashRecord(mode: .front, intensityPercent: settings.photoPercent,
                           durationPercent: timing.durationPercent ?? 100,
                           exposureSeconds: exposureSeconds)
    }

    /// One sentence for a diagnostics line or a test message.
    var summary: String {
        if let refusalReason { return "lamp refused (\(refusalReason))" }
        switch mode {
        case .off:
            return "lamp off"
        case .continuous:
            return "lamp at \(intensityPercent)% for the take"
        case .front, .rear:
            let window = exposureSeconds.map { String(format: "%.4f", $0) } ?? "unknown"
            return "lamp at \(intensityPercent)% for \(durationPercent ?? 100)% of a \(window)s exposure"
        }
    }

    // MARK: Metadata

    /// Keys written to `com.filmemulation.*` (movie and still alike) and into
    /// the still's EXIF. The names are a file contract.
    static let modeKey = "flash-mode"
    static let intensityKey = "flash-intensity-percent"
    static let durationKey = "flash-duration-percent"
    static let exposureKey = "flash-exposure-seconds"
    static let refusedKey = "flash-refused"
    static let refusedReasonKey = "flash-refused-reason"

    var metadataValues: [String: String] {
        var values = [
            Self.modeKey: mode.rawValue,
            Self.intensityKey: String(intensityPercent),
            Self.refusedKey: String(wasRefused)
        ]
        // Video has no window to shape, so it records no duration rather than a
        // misleading 100.
        if let durationPercent { values[Self.durationKey] = String(durationPercent) }
        if let exposureSeconds {
            values[Self.exposureKey] = String(format: "%.6f", exposureSeconds)
        }
        if let refusalReason { values[Self.refusedReasonKey] = refusalReason }
        return values
    }

    /// Read a record back out of a file's metadata. Nil when the file has none,
    /// which is the honest answer for a take made before the lamp existed.
    static func decode(_ values: [String: String]) -> FlashRecord? {
        guard let raw = values[modeKey], let mode = FlashMode(rawValue: raw) else { return nil }
        return FlashRecord(mode: mode,
                           intensityPercent: Int(values[intensityKey] ?? "") ?? 0,
                           durationPercent: values[durationKey].flatMap(Int.init),
                           exposureSeconds: values[exposureKey].flatMap(Double.init),
                           refusalReason: values[refusedReasonKey].flatMap { $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Persistence

/// The lamp settings over `UserDefaults`, under `camera.flash.*`.
///
/// The video level is one app-wide value: it is not remembered per stock and it
/// does not travel with push/pull. The defaults object is injectable so a test
/// never touches the app's own domain.
final class FlashSettingsStore: @unchecked Sendable {
    enum Key {
        static let videoLevel = "camera.flash.video-level"
        static let photoIntensity = "camera.flash.photo-intensity"
        static let photoDurationPercent = "camera.flash.photo-duration-percent"
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    /// Always clamped on the way in and out: a value written by another build,
    /// or by hand, cannot put the lamp outside a range the hardware accepts.
    var settings: FlashSettings {
        get {
            let standard = FlashSettings.standard
            return FlashSettings(
                videoLevel: number(Key.videoLevel) ?? standard.videoLevel,
                photoIntensity: number(Key.photoIntensity) ?? standard.photoIntensity,
                photoDurationPercent: number(Key.photoDurationPercent) ?? standard.photoDurationPercent
            )
        }
        set {
            defaults.set(newValue.videoLevel, forKey: Key.videoLevel)
            defaults.set(newValue.photoIntensity, forKey: Key.photoIntensity)
            defaults.set(newValue.photoDurationPercent, forKey: Key.photoDurationPercent)
        }
    }

    /// A missing key is `nil`, not zero: zero is a real level ("off"), so it must
    /// not stand in for "never set".
    private func number(_ key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }
}
