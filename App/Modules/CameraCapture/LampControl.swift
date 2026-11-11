import SwiftUI

/// The flash key for the camera's top bar.
///
/// A press switches native photo flash on/off, or restores the remembered
/// video torch level. Holding the video key opens its level control.
/// Photo has no adjustment popover because the camera owns its flash pulse.
///
/// The key owns its settings because the lamp is a capture fact, not a stock
/// fact: the same level lights a take whichever film is loaded, and the store
/// keeps it across launches.
struct LampControl: View {
    var photoMode: Bool
    var appliedShutterSeconds: Double

    @State private var settings = FlashSettingsStore().settings
    @State private var showsControls = false
    /// The video level the switch returns to. Native photo flash is on/off;
    /// its pulse strength and timing are controlled by the camera.
    @State private var lastVideoLevel: Double = 0.5
    @State private var hapticTick = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().fill(isOn ? Color.yellow.opacity(0.28) : Color.black.opacity(0.45))
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            Image(systemName: isOn ? "bolt.fill" : "bolt.slash.fill")
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(tint)
                .cameraUpright()
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .onTapGesture { toggle() }
        .onLongPressGesture(minimumDuration: 0.4) {
            if photoMode {
                toggle()
            } else {
                showsControls.toggle()
                tick()
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTick)
        // .top puts the card BELOW the key. The arrow edge names the side of
        // the popover the arrow leaves from, so .bottom anchored the card above
        // a key that already sits at the top of the screen and pushed it off.
        .popover(isPresented: $showsControls, arrowEdge: .top) {
            controls.presentationCompactAdaptation(.popover)
        }
        .accessibilityIdentifier("camera.flash")
        .accessibilityLabel("Flash")
        .accessibilityValue(settings.accessibilityValue(photoMode: photoMode))
        .accessibilityAddTraits(.isButton)
        .onChange(of: settings) { _, value in
            FlashSettingsStore().settings = value
        }
        .onChange(of: photoMode) { _, _ in showsControls = false }
    }

    private var isOn: Bool {
        photoMode ? settings.isPhotoLampOn : settings.isVideoLampOn
    }

    private var tint: Color {
        isOn ? .yellow : .secondary
    }

    /// Photo switches native flash on/off. Video restores the adjustable lamp level.
    private func toggle() {
        if photoMode {
            settings.photoIntensity = settings.isPhotoLampOn ? 0 : 1
        } else if settings.videoLevel > 0 {
            lastVideoLevel = settings.videoLevel
            settings.videoLevel = 0
        } else {
            settings.videoLevel = max(lastVideoLevel, FlashSettings.intensityRange.lowerBound + 0.25)
        }
        tick()
    }

    private func tick() {
        CameraHaptics.prepareForCaptureFeedback()
        hapticTick &+= 1
    }

    /// Native still flash has no app-controlled pulse intensity or duration.
    /// Keep video’s continuous lamp slider separate.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Flash")
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(.primary)
            slider("Flash", value: $settings.videoLevel,
                   range: FlashSettings.intensityRange,
                   readout: settings.isVideoLampOn ? "\(settings.videoPercent)%" : "OFF")
        }
        .padding(16)
        .frame(width: 280)
    }

    private func slider(_ caption: String, value: Binding<Double>,
                        range: ClosedRange<Double>, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(caption)
                Spacer(minLength: 0)
                Text(readout)
                    .monospacedDigit()
            }
            .font(NitrateTypography.font(.caption))
            .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 0.05)
        }
    }
}
