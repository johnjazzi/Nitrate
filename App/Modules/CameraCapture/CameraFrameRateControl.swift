import SwiftUI

/// One selectable actual capture rate, in whole frames per second.
///
/// Plain rates keep this component independent of the capture engine and its
/// session type, so the menu and its presentation can be exercised without a
/// camera. The parent maps its own `CameraFrameRate` values onto these.
struct CameraFrameRateOption: Identifiable, Equatable, Sendable {
    let fps: Int

    var id: Int { fps }

    /// The compact face value. A manual 120 reads "120", never a neighbouring
    /// rate, so the face can never claim the rate that is not running.
    var faceValue: String { "\(fps)" }

    /// The operator-facing unit. The manual block speaks in the same compact
    /// form it paints, so the key and the menu agree.
    var spokenValue: String { "\(fps)FPS" }
}

/// Pure decisions for the compact frame-rate menu: which rates are offered,
/// which of them can actually be selected, and what the face says.
enum CameraFrameRateControlPresentation {
    /// Every rate the manual Video block lists, whether or not this device can
    /// deliver it. 24 is the cold-launch rate, 60 the daylight rescue rate and
    /// 120 the high-rate option, withdrawn entirely unless the build enables it.
    /// Unsupported entries stay listed and are disabled, so the menu never hides
    /// a rate the engine could not offer.
    static let canonicalFPS = [24, 60, 120]

    /// The menu's touch height, matching the other manual keys.
    static let optionHeight: CGFloat = 44

    /// Canonical rates in ascending order, unioned with whatever the session
    /// reports and deduplicated, so a device that reports an extra rate still
    /// shows it in one stable, ordered list.
    static func options(availableFPS: [Int],
                        highFrameRateEnabled: Bool = false) -> [CameraFrameRateOption] {
        let rates = Set(canonicalFPS + availableFPS.filter { $0 > 0 })
            .filter { HighFrameRateFeature.allows(fps: $0, available: highFrameRateEnabled) }
        return rates.sorted().map(CameraFrameRateOption.init(fps:))
    }

    /// Only a rate the session reports can be written.
    static func isSupported(_ fps: Int, availableFPS: [Int]) -> Bool {
        availableFPS.contains(fps)
    }

    /// Selection needs both a supported rate and an unlocked session, so a
    /// recording or in-flight transition can never be rewritten by a tap.
    static func canSelect(_ fps: Int, availableFPS: [Int], canChange: Bool) -> Bool {
        canChange && isSupported(fps, availableFPS: availableFPS)
    }

    /// The standard 24 reads neutral white; any deliberate higher rate reads in
    /// the manual-control orange, so an active 60 or 120 is obvious at a glance.
    static func faceColor(currentFPS: Int) -> Color {
        currentFPS == canonicalFPS.first ? .white.opacity(0.85)
                                        : InlineManualControlPresentation.activeOrange
    }

    /// Honest spoken value: the rate that is actually running.
    static func accessibilityValue(currentFPS: Int) -> String {
        CameraFrameRateOption(fps: currentFPS).spokenValue
    }

    /// Every row reads the same. The rate in force is shown by weight, not by
    /// appending a word, so the row text never changes length mid-take.
    static func rowTitle(fps: Int) -> String { "\(fps)FPS" }

    /// The row for the rate in force is bold; the others stay regular.
    static func isCurrentRow(fps: Int, currentFPS: Int) -> Bool { fps == currentFPS }
}

/// The compact frame-rate key: one native menu in the manual Video block that
/// offers every actual rate the session can run, marks unsupported rates,
/// listens with a 44pt target and writes through the parent's single backend
/// call. It is deliberately one component, used by the default in-frame stack.
struct CameraFrameRateControl: View {
    /// Rates the session reports as available, in frames per second.
    let availableFPS: [Int]
    /// The rate actually in force for the next take.
    let currentFPS: Int
    /// Whether the session will accept a change right now.
    let canChange: Bool
    /// Whether this build and identity ship the manual 120 fps mode. False by
    /// default: a caller that forgets the flag hides the rate instead of
    /// offering one the session will refuse.
    var highFrameRateEnabled: Bool = false
    let select: (Int) -> Void

    private var options: [CameraFrameRateOption] {
        CameraFrameRateControlPresentation.options(availableFPS: availableFPS,
                                                   highFrameRateEnabled: highFrameRateEnabled)
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    choose(option.fps)
                } label: {
                    Text(CameraFrameRateControlPresentation.rowTitle(fps: option.fps))
                        .fontWeight(CameraFrameRateControlPresentation.isCurrentRow(
                            fps: option.fps, currentFPS: currentFPS) ? .bold : .regular)
                }
                .disabled(!CameraFrameRateControlPresentation.canSelect(
                    option.fps, availableFPS: availableFPS, canChange: canChange))
            }
        } label: {
            VStack(spacing: 0) {
                Image(systemName: "speedometer")
                    .font(NitrateTypography.font(size: 12))
                Text(CameraFrameRateOption(fps: currentFPS).faceValue)
                    .font(NitrateTypography.font(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(CameraFrameRateControlPresentation.faceColor(currentFPS: currentFPS))
            .frame(maxWidth: .infinity, minHeight: CameraFrameRateControlPresentation.optionHeight)
        }
        .disabled(!canChange)
        .accessibilityLabel("Capture frame rate")
        .accessibilityValue(CameraFrameRateControlPresentation.accessibilityValue(currentFPS: currentFPS))
        .accessibilityHint("Unavailable rates are listed but cannot be selected.")
    }

    // MARK: - Named guard

    /// The single guard shared by the live menu and the focused tests. It also
    /// refuses the gated rate when the build leaves the switch off, so a stale
    /// row or a direct call cannot start a take the session would reject.
    func choose(_ fps: Int) {
        guard HighFrameRateFeature.allows(fps: fps, available: highFrameRateEnabled) else { return }
        guard CameraFrameRateControlPresentation.canSelect(
            fps, availableFPS: availableFPS, canChange: canChange) else { return }
        select(fps)
    }
}
