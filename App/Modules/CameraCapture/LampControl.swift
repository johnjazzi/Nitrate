import SwiftUI

/// The lamp key for the camera's top bar.
///
/// A short press is the switch: on at the remembered level, off again. A long
/// press is the tooltip: it opens the lamp's controls, and a second long press
/// closes them. Both ticks.
///
/// The key owns its settings because the lamp is a capture fact, not a stock
/// fact: the same level lights a take whichever film is loaded, and the store
/// keeps it across launches.
struct LampControl: View {
    var photoMode: Bool
    var appliedShutterSeconds: Double

    @State private var settings = FlashSettingsStore().settings
    @State private var showsControls = false
    /// The level the switch returns to. Zero is off, so the key needs to know
    /// what "on" meant last time rather than guessing full power.
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
            showsControls.toggle()
            tick()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTick)
        .popover(isPresented: $showsControls, arrowEdge: .bottom) {
            controls.presentationCompactAdaptation(.popover)
        }
        .accessibilityIdentifier("camera.flash")
        .accessibilityLabel("Lamp")
        .accessibilityValue(settings.accessibilityValue(photoMode: photoMode))
        .accessibilityAddTraits(.isButton)
        .onChange(of: settings) { _, value in
            FlashSettingsStore().settings = value
        }
    }

    private var isOn: Bool {
        photoMode ? settings.isPhotoLampOn : settings.isVideoLampOn
    }

    private var tint: Color {
        isOn ? .yellow : .secondary
    }

    /// Short press: off if it is on, on at the last level if it is off. Photo mode
    /// flips the lamp switch; video mode swings the level between zero and the
    /// last level the operator actually dialled.
    private func toggle() {
        if photoMode {
            settings.photoEnabled.toggle()
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

    /// The applied shutter is too fast for the lamp to be shaped at all. The
    /// duration control says why and is disabled: a control that silently does
    /// nothing is worse than one that is visibly unavailable. Below the floor the
    /// lamp still fires, for the whole exposure, at the requested intensity.
    private var shapingReason: String? {
        guard photoMode, settings.isPhotoLampOn else { return nil }
        switch FlashTimingPolicy.timing(exposure: appliedShutterSeconds,
                                        durationPercent: settings.photoDurationPercent,
                                        sync: .front) {
        case .unshapable(let reason): return reason
        case .lit: return nil
        }
    }

    /// One control per mode. Video has a level and nothing else to say; a photo
    /// has the intensity and the fraction of the exposure the lamp covers.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lamp")
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(.primary)
            if photoMode {
                Toggle("Fire the lamp", isOn: $settings.photoEnabled)
                    .font(NitrateTypography.font(.footnote))
                slider("Intensity", value: $settings.photoIntensity,
                       range: FlashSettings.intensityRange,
                       readout: settings.isPhotoLampOn ? "\(settings.photoPercent)%" : "OFF")
                slider("Duration", value: $settings.photoDurationPercent,
                       range: FlashSettings.durationRange,
                       readout: "\(settings.durationPercent)%")
                    .disabled(shapingReason != nil)
                    .opacity(shapingReason == nil ? 1 : 0.45)
                if let reason = shapingReason {
                    Text(reason)
                        .font(NitrateTypography.font(.caption2))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                slider("Lamp", value: $settings.videoLevel,
                       range: FlashSettings.intensityRange,
                       readout: settings.isVideoLampOn ? "\(settings.videoPercent)%" : "OFF")
            }
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
