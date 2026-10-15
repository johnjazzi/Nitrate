import Foundation

/// What the centre REC control should show and do.
///
/// The control acknowledges the press immediately: capture cannot report that
/// it started until the session queue, the custom-exposure settle and the asset
/// writer have all run, so gating all feedback on that made the button feel
/// dead for a few hundred milliseconds after the tap. `.starting` is the
/// pressed-but-not-yet-capturing state that closes that gap.
enum RecordButtonPresentation: Equatable, Sendable {
    /// Nothing in flight: tap starts a recording.
    case idle
    /// Press accepted, capture still spinning up: tap cancels the pending start.
    case starting
    /// Stop requested, recorder still finalising: tap does nothing.
    case stopping
    /// Capture is running: tap stops.
    case recording
}

/// The action a tap should perform for a given presentation.
enum RecordButtonAction: Equatable, Sendable {
    case start
    case stop
    /// The press is acknowledged but has nothing left to do; no feedback fires.
    case none
}

enum RecordButtonPresentationPolicy {
    /// Stopping wins over everything: finalising can take seconds, and until it
    /// finishes the take is still live, so the control must not fall back to the
    /// running look or accept another tap.
    static func presentation(isRecording: Bool, isStarting: Bool, isStopping: Bool) -> RecordButtonPresentation {
        if isStopping { return .stopping }
        if isRecording { return .recording }
        if isStarting { return .starting }
        return .idle
    }

    /// A running or pending take stays tappable even when storage is critical,
    /// so the user can always stop or cancel what they began.
    static func isEnabled(isSpaceCritical: Bool, presentation: RecordButtonPresentation) -> Bool {
        presentation != .idle || !isSpaceCritical
    }

    /// Both `.starting` and `.recording` resolve to stop: `stopRecording()`
    /// already cancels a pending start. `.stopping` ignores the tap so a second
    /// press cannot queue another stop or re-fire feedback.
    static func action(for presentation: RecordButtonPresentation) -> RecordButtonAction {
        switch presentation {
        case .idle: .start
        case .starting, .recording: .stop
        case .stopping: .none
        }
    }

    static func accessibilityLabel(for presentation: RecordButtonPresentation) -> String {
        switch presentation {
        case .idle: "Start recording"
        case .starting: "Cancel starting recording"
        case .stopping: "Stopping recording"
        case .recording: "Stop recording"
        }
    }
}
