import AppKit
import CoreGraphics
import SwiftUI
import Testing

/// Pure palette and guard behaviour for the in-frame manual control stack, plus
/// a native render of each stabilization state.
///
/// The binding assertions run against the real `InlineManualControls` type, so
/// the guards are exercised once and not re-implemented in the test. The render
/// assertions measure warm (orange) pixels over a fixed frame, so the
/// stabilization face's intensity is compared rather than merely counted.
struct InlineManualControlsTests {
    // MARK: - Pure presentation

    @Test func stabilizationIntensityIsMonotonicWithOffAtZero() {
        #expect(InlineManualControlPresentation.stabilizationIntensity(.off) == 0)
        #expect(InlineManualControlPresentation.stabilizationIntensity(.standard) == 0.4)
        #expect(InlineManualControlPresentation.stabilizationIntensity(.cinematic) == 0.7)
        #expect(InlineManualControlPresentation.stabilizationIntensity(.extreme) == 1)
        // Standard < Cinematic < Extreme holds as one ordered ramp.
        #expect(InlineManualControlPresentation.stabilizationIntensity(.standard)
                < InlineManualControlPresentation.stabilizationIntensity(.cinematic))
        #expect(InlineManualControlPresentation.stabilizationIntensity(.cinematic)
                < InlineManualControlPresentation.stabilizationIntensity(.extreme))
    }

    @Test func offIsGreyAndEnabledModesAreOrange() {
        #expect(InlineManualControlPresentation.stabilizationColor(for: .off)
                == InlineManualControlPresentation.inactiveGrey)
        #expect(InlineManualControlPresentation.stabilizationColor(for: .standard)
                == InlineManualControlPresentation.activeOrange.opacity(0.4))
        #expect(InlineManualControlPresentation.stabilizationColor(for: .cinematic)
                == InlineManualControlPresentation.activeOrange.opacity(0.7))
        #expect(InlineManualControlPresentation.stabilizationColor(for: .extreme)
                == InlineManualControlPresentation.activeOrange.opacity(1))
    }

    @Test func unsupportedPreferredPaintsItsEffectiveOffFallback() {
        // Extreme is preferred but the format only supports Standard.
        let snapshot = manualSnapshot(preferred: .extreme, formats: [.standard], activeRawValue: 0)
        #expect(InlineManualControlPresentation.effectiveMode(snapshot) == .off)
        #expect(InlineManualControlPresentation.stabilizationColor(
            for: InlineManualControlPresentation.effectiveMode(snapshot))
            == InlineManualControlPresentation.inactiveGrey)
        // A supported preference keeps its effective mode and its orange.
        let supported = manualSnapshot(preferred: .cinematic, formats: [.cinematic])
        #expect(InlineManualControlPresentation.effectiveMode(supported) == .cinematic)
    }

    @Test func abbreviationsAreDistinctForEveryMode() {
        let abbreviations = CameraStabilizationMode.allCases.map {
            InlineManualControlPresentation.stabilizationAbbreviation($0)
        }
        #expect(abbreviations == ["OFF", "ST", "CIN", "EXT"])
        #expect(Set(abbreviations).count == CameraStabilizationMode.allCases.count)
        #expect(abbreviations.allSatisfy { !$0.isEmpty })
    }

    @Test func focusTitleAndValueTrackTheBinding() {
        #expect(InlineManualControlPresentation.focusTitle(manualFocus: true) == "MF")
        #expect(InlineManualControlPresentation.focusTitle(manualFocus: false) == "AF")
        #expect(InlineManualControlPresentation.focusValue(manualFocus: true) == "On")
        #expect(InlineManualControlPresentation.focusValue(manualFocus: false) == "Off")
    }

    @Test func apertureIsLightPurpleOnlyWhenAdjustable() {
        #expect(InlineManualControlPresentation.apertureColor(canChange: true)
                == SettingsControlChrome.lightPurple)
        #expect(InlineManualControlPresentation.apertureColor(canChange: false)
                == InlineManualControlPresentation.inactiveGrey)
    }

    // MARK: - Binding actions on the real view

    @MainActor @Test func toggleFocusFlipsTheSharedRulerBinding() {
        var manual = false
        let binding = Binding(get: { manual }, set: { manual = $0 })
        let view = makeView(manualFocus: binding)
        #expect(!manual)

        view.toggleFocus()
        #expect(manual)
        view.toggleFocus()
        #expect(!manual)
    }

    @MainActor @Test func selectApertureHonoursTheAdjustabilityGuard() {
        var recorded: [Float?] = []

        let locked = makeView(canChangeAperture: false, setAperture: { recorded.append($0) })
        locked.selectAperture(1.8)
        locked.selectAperture(nil)
        #expect(recorded.isEmpty, "a fixed lens must not emit an aperture change")

        let adjustable = makeView(canChangeAperture: true, setAperture: { recorded.append($0) })
        adjustable.selectAperture(2.8)
        adjustable.selectAperture(nil)
        #expect(recorded == [2.8, nil])
    }

    @MainActor @Test func selectModeValidatesChangeAvailabilityAndSupport() {
        var selected: [CameraStabilizationMode] = []

        // Available, supported and unlocked: the one accepted path.
        var view = makeView(stabilization: manualSnapshot(preferred: .off),
                            selectStabilization: { selected.append($0) })
        view.selectMode(.cinematic)
        #expect(selected == [.cinematic])

        // A locked snapshot never writes, even for a supported mode.
        view = makeView(stabilization: manualSnapshot(preferred: .off, changesAllowed: false),
                        selectStabilization: { selected.append($0) })
        view.selectMode(.cinematic)
        #expect(selected == [.cinematic])

        // An unsupported mode never writes.
        view = makeView(stabilization: manualSnapshot(preferred: .off, formats: [.standard]),
                        selectStabilization: { selected.append($0) })
        view.selectMode(.extreme)
        #expect(selected == [.cinematic])

        // A false change capability never writes.
        view = makeView(stabilization: manualSnapshot(preferred: .off),
                        canChangeStabilization: false,
                        selectStabilization: { selected.append($0) })
        view.selectMode(.standard)
        #expect(selected == [.cinematic])

        // Off is always available, even with no hardware support reported.
        view = makeView(stabilization: manualSnapshot(preferred: .standard, formats: []),
                        selectStabilization: { selected.append($0) })
        view.selectMode(.off)
        #expect(selected == [.cinematic, .off])
    }

    // MARK: - Native render

    @MainActor @Test func realStackKeepsThreeKeysWithin140ptInEveryState() {
        for mode in CameraStabilizationMode.allCases {
            let host = NSHostingView(rootView: InlineManualControlsHarness(stabilization: manualSnapshot(preferred: mode))
                .environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            #expect(size.height <= 140, "\(mode) must keep the three 44pt keys within 140pt")
            #expect(size.height >= 132, "\(mode) must keep the three 44pt keys")
            #expect(size.width <= 45, "\(mode) must keep the authored 44pt column")
        }
    }

    @MainActor @Test func realStackRaisesStabilizationWarmthMonotonically() throws {
        var warmth: [Double] = []
        for mode in CameraStabilizationMode.allCases {
            warmth.append(try renderedWarmth(stabilization: manualSnapshot(preferred: mode)))
        }
        // Off < Standard < Cinematic < Extreme, matching the intensity ramp.
        #expect(warmth[0] < 1, "Off draws no orange")
        #expect(warmth[0] < warmth[1], "an enabled mode must add orange over Off")
        #expect(warmth[1] < warmth[2], "Cinematic must read warmer than Standard")
        #expect(warmth[2] < warmth[3], "Extreme must read warmer than Cinematic")
    }
}

// MARK: - Helpers

/// One immutable snapshot; formats default to every non-off mode.
private func manualSnapshot(preferred: CameraStabilizationMode,
                            formats: Set<CameraStabilizationMode> = [.standard, .cinematic, .extreme],
                            changesAllowed: Bool = true,
                            activeRawValue: Int? = nil) -> CameraStabilizationSnapshot {
    CameraStabilizationSnapshot(
        preferred: preferred,
        capability: CameraStabilizationPolicy.Capability(connectionSupported: true, formatModes: formats),
        activeRawValue: activeRawValue,
        cameraRevision: 1,
        changesAllowed: changesAllowed
    )
}

@MainActor
private func makeView(manualFocus: Binding<Bool> = .constant(false),
                      canChangeAperture: Bool = true,
                      setAperture: @escaping (Float?) -> Void = { _ in },
                      stabilization: CameraStabilizationSnapshot = manualSnapshot(preferred: .off),
                      canChangeStabilization: Bool = true,
                      selectStabilization: @escaping (CameraStabilizationMode) -> Void = { _ in })
    -> InlineManualControls {
    InlineManualControls(
        manualFocus: manualFocus,
        apertureReadout: "f/1.8",
        apertureStops: [1.8, 2.0, 2.8],
        selectedAperture: 1.8,
        canChangeAperture: canChangeAperture,
        setAperture: setAperture,
        stabilization: stabilization,
        canChangeStabilization: canChangeStabilization,
        selectStabilization: selectStabilization
    )
}

/// Renders the stack over a fixed dark frame and sums its warm pixels. Only the
/// stabilization face changes between modes, so a larger sum means a brighter
/// orange face rather than a wider one.
@MainActor
private func renderedWarmth(stabilization: CameraStabilizationSnapshot) throws -> Double {
    let host = NSHostingView(rootView: ZStack {
        Color.black
        InlineManualControlsHarness(stabilization: stabilization)
    }
    .frame(width: 44, height: 140).environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = CGRect(x: 0, y: 0, width: 44, height: 140)
    host.layoutSubtreeIfNeeded()

    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)

    var warmth = 0.0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            // Orange has red well above blue; grey and the light-purple
            // aperture tint (blue above red) contribute nothing.
            warmth += max(0, Double(color.redComponent) - Double(color.blueComponent))
        }
    }
    return warmth
}

/// Standalone harness so the rendered stack holds a real focus binding.
private struct InlineManualControlsHarness: View {
    var stabilization: CameraStabilizationSnapshot
    @State private var manualFocus = false

    var body: some View {
        InlineManualControls(
            manualFocus: $manualFocus,
            apertureReadout: "f/1.8",
            apertureStops: [1.8, 2.0, 2.8],
            selectedAperture: 1.8,
            canChangeAperture: true,
            setAperture: { _ in },
            stabilization: stabilization,
            canChangeStabilization: true,
            selectStabilization: { _ in }
        )
    }
}
