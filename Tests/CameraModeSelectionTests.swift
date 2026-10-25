import Foundation
import Testing

@MainActor
struct CameraModeLandscapeSwipeTests {
    @Test func swipeFollowsTheVisibleRowRegardlessOfLabelRotation() {
        for degrees in [-90.0, 0.0, 90.0] {
            let view = CameraModeCarousel(selected: .develop, enabled: true,
                                          rotationDegrees: degrees, onSelect: { _ in })
            #expect(view.resolvedSwipe(CGSize(width: -40, height: 0)) == .select(.video))
            #expect(view.resolvedSwipe(CGSize(width: 0, height: -40)) == .none)
            let disabled = CameraModeCarousel(selected: .develop, enabled: false,
                                              rotationDegrees: degrees, onSelect: { _ in })
            #expect(disabled.resolvedSwipe(CGSize(width: -40, height: 0)) == .none)
        }
    }
}

/// Behavioural contract for the pure mode-selection model: which modes the
/// compact carousel may offer, what a selection change means, and the three
/// rejection cases (disabled capture, a repeat selection, and the hidden photo
/// mode) that must leave the current mode untouched.
///
/// These are the real decisions the row makes. The SwiftUI view only forwards
/// taps and swipes into this model, so the cases below are exercised directly
/// rather than through a rendered button.
struct CameraModeSelectionTests {
    @Test func visibleModesAreDevelopAndVideoInOrder() {
        #expect(CameraMode.visibleModes == [.develop, .video])
        #expect(!CameraMode.visibleModes.contains(.photo),
                "Photo is hidden: it must not be a visible mode.")
    }

    @Test func defaultSelectionIsVideo() {
        #expect(CameraModeSelection().selected == .video)
    }

    @Test func selectMovesToAnEnabledVisibleDifferentMode() {
        var selection = CameraModeSelection()
        #expect(selection.select(.develop, enabled: true) == true)
        #expect(selection.selected == .develop)
    }

    @Test func selectRejectsDisabledCapture() {
        var selection = CameraModeSelection()
        #expect(selection.select(.develop, enabled: false) == false)
        #expect(selection.selected == .video, "A denied switch must not move the mode.")
    }

    @Test func selectRejectsTheAlreadySelectedMode() {
        var selection = CameraModeSelection()
        #expect(selection.select(.video, enabled: true) == false)
        #expect(selection.selected == .video)
    }

    @Test func selectRejectsHiddenPhotoEvenWhenEnabled() {
        var selection = CameraModeSelection()
        #expect(selection.select(.photo, enabled: true) == false)
        #expect(selection.selected == .video, "The hidden photo mode can never be selected.")
    }

    @Test func returnToVideoRestoresVideoFromAnotherMode() {
        var selection = CameraModeSelection(selected: .develop)
        selection.returnToVideo()
        #expect(selection.selected == .video)
    }

    @Test func glyphsTitlesAndIdentifiersMapToTheThreeModes() {
        #expect(CameraMode.develop.letter == "D")
        #expect(CameraMode.video.letter == "V")
        #expect(CameraMode.photo.letter == "P")

        #expect(CameraMode.develop.title == "develop")
        #expect(CameraMode.video.title == "video")
        #expect(CameraMode.photo.title == "photo")

        #expect(CameraMode.allCases.map(\.id) == ["develop", "video", "photo"])
    }

    @Test func accessibilityIdentifiersAndVoiceLabelsAreStable() {
        #expect(CameraMode.visibleModes.map(\.accessibilityIdentifier)
                == ["cameraMode.develop", "cameraMode.video"])
        #expect(CameraMode.develop.voiceLabel == "Develop")
        #expect(CameraMode.video.voiceLabel == "Video")
        #expect(CameraMode.photo.voiceLabel == "Photo")
    }
}
