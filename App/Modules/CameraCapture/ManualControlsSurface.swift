import SwiftUI

/// Shared production surface: native controls with no camera/session dependency.
/// The enclosing overlay owns the single physical-orientation transform.
struct ManualControlsSurface<Aperture: View>: View {
    @Binding var zoom: Double
    @Binding var focus: Double
    @Binding var manualFocus: Bool
    @Binding var expanded: Bool
    let landscape: Bool
    let zoomRange: ClosedRange<Double>
    var zoomIsPerLens = false
    var zoomAvailable = true
    var zoomRevision: UInt64 = 0
    let exposure: String
    let apertureReadout: String
    let stabilization: CameraStabilizationSnapshot
    let canChangeStabilization: Bool
    let selectStabilization: (CameraStabilizationMode) -> Void
    let dismiss: () -> Void
    var beginZoom: (CameraZoomDirection) -> Void = { _ in }
    var endZoom: (UInt64) -> Void = { _ in }
    var stepZoom: (CameraZoomDirection) -> Void = { _ in }
    @ViewBuilder var aperture: () -> Aperture
    @State private var showingHelp = false
    @AppStorage("camera.manualControlsLastEnabledStabilization")
    private var lastEnabledModeRaw = CameraStabilizationMode.standard.rawValue

    private var lastEnabledMode: CameraStabilizationMode {
        CameraStabilizationMode(rawValue: lastEnabledModeRaw) ?? .standard
    }

    var body: some View {
        VStack(spacing: expanded ? 12 : 2) {
            HStack(spacing: 4) {
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MANUAL").font(.caption.weight(.bold))
                        Text(exposure).font(.caption2.monospacedDigit()).lineLimit(1)
                    }
                } else {
                    Text("MANUAL").font(.system(size: 10, weight: .bold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !expanded {
                    zoomHold(.out, symbol: "minus", label: "Zoom Out")
                    zoomHold(.in, symbol: "plus", label: "Zoom In")
                    stabilizationHelp
                }
                Button(action: toggleExpanded) {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(expanded ? "Collapse manual controls" : "Expand manual controls")
                .accessibilityValue(expanded ? "Expanded" : "Compact")
                Button(action: dismiss) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close manual controls")
            }
            HStack(alignment: .top, spacing: expanded ? 10 : 4) {
                column(zoomIsPerLens ? "LENS" : "ZOOM", readout: zoomAvailable ? String(format: "%.1fx", zoom) : "—") {
                    track(value: $zoom, range: zoomRange, step: 0.1, label: "Zoom")
                        .disabled(!zoomAvailable || zoomRange.lowerBound == zoomRange.upperBound)
                }
                VStack(spacing: 0) {
                    title("FOCUS")
                    track(value: $focus, range: 0...1, step: 0.01, label: "Focus")
                        .disabled(!manualFocus).opacity(manualFocus ? 1 : 0.4)
                    Button(action: toggleFocus) {
                        Text(manualFocus ? "MF" : "AF").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel("Manual focus")
                    .accessibilityValue(manualFocus ? "On" : "Off")
                    .accessibilityHint("Switch between autofocus and manual focus")
                }
                .frame(maxWidth: .infinity)
                column("IRIS", readout: apertureReadout) { aperture().frame(height: trackHeight) }
                stabilizationColumn
                    .frame(width: landscape ? 86 : 72)
            }
            if expanded {
                HStack(spacing: 8) {
                    Text(zoomIsPerLens ? "LENS ZOOM" : "ZOOM")
                        .font(.system(size: 10, weight: .bold))
                    Spacer(minLength: 0)
                    zoomHold(.out, symbol: "minus", label: "Zoom Out")
                    zoomHold(.in, symbol: "plus", label: "Zoom In")
                }
                .frame(height: 44)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 6))
        .padding(expanded ? 8 : 4)
        .onAppear { rememberEnabledMode(stabilization.preferred) }
        .onChange(of: stabilization.preferred) { _, mode in rememberEnabledMode(mode) }
        .popover(isPresented: $showingHelp) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recording stabilization").font(.headline)
                        Spacer()
                        Button("Done") { showingHelp = false }.frame(minHeight: 44)
                    }
                    Text(stabilization.statusText)
                    Text("Recording only. Preview is independent. Stronger modes crop more and can delay confirmation.")
                    Text("Confirmation takes about 0.3 s (Off/Standard), 0.9 s (Cinematic), or 2.2 s (Extreme), measured on device. Recording begins about 0.2 s after the tap in every mode. Extreme uses Apple extended cinematic stabilization.")
                    Text("Unavailable modes are not offered. A saved unsupported preference is retained with an Off fallback. Changes are locked during recording and transitions.")
                }.padding()
            }
            .frame(idealWidth: 320, maxWidth: 360, idealHeight: 330, maxHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var trackHeight: CGFloat { landscape ? (expanded ? 100 : 44) : (expanded ? 110 : 44) }
    private var compactTextRowHeight: CGFloat { 18 }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).lineLimit(1)
            .frame(height: expanded ? 44 : compactTextRowHeight).frame(maxWidth: .infinity)
    }

    private func column<Control: View>(_ name: String, readout: String,
                                       @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            title(name)
            control()
            Text(readout).monospacedDigit().lineLimit(1)
                .frame(height: expanded ? 44 : compactTextRowHeight).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity)
    }

    private func track(value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                       label: String) -> some View {
        ManualControlTrack(value: value, range: range, step: step, landscape: landscape,
                           length: expanded ? 110 : 44, label: label)
            .frame(height: trackHeight)
    }

    private var stabilizationColumn: some View {
        VStack(spacing: 0) {
            if expanded {
                HStack(spacing: 0) {
                    Text("STAB").font(.system(size: 10, weight: .bold))
                    stabilizationHelp
                }
            }
            Toggle("Recording stabilization", isOn: Binding(
                get: { stabilization.preferred != .off },
                set: setStabilizationEnabled))
                .labelsHidden().toggleStyle(.switch)
                .frame(height: trackHeight)
                .disabled(!canChangeStabilization || stabilization.capability.availableModes.count < 2)
            Menu {
                ForEach(stabilization.capability.availableModes.filter { $0 != .off }) { mode in
                    Button(mode.title) { selectMode(mode) }
                }
            } label: {
                VStack(spacing: 2) {
                    Text(stabilization.preferred == .off ? lastEnabledMode.title : stabilization.preferred.title)
                    Text("Active \(stabilization.active?.title ?? "—")").font(.system(size: 9))
                }.lineLimit(1).frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Recording stabilization mode")
            .accessibilityValue(stabilization.statusText)
            .disabled(!canChangeStabilization || stabilization.capability.availableModes.count < 2)
        }
    }

    private var stabilizationHelp: some View {
        Button { showingHelp = true } label: {
            Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stabilization help and actual status")
    }

    private func zoomHold(_ direction: CameraZoomDirection, symbol: String, label: String) -> some View {
        ZoomHoldControl(symbol: symbol, label: label, enabled: zoomAvailable,
                        revision: zoomRevision, begin: { beginZoom(direction) },
                        end: endZoom, step: { stepZoom(direction) })
    }

    // Named actions are shared by the live controls and focused binding tests.
    func toggleExpanded() { expanded.toggle() }
    func toggleFocus() { manualFocus.toggle() }

    func setStabilizationEnabled(_ enabled: Bool) {
        guard canChangeStabilization,
              let mode = ManualStabilizationSelection.toggleTarget(
                enabled: enabled, snapshot: stabilization, remembered: lastEnabledMode) else { return }
        selectStabilization(mode)
    }

    func selectMode(_ mode: CameraStabilizationMode) {
        guard canChangeStabilization, stabilization.changesAllowed,
              stabilization.capability.availableModes.contains(mode) else { return }
        selectStabilization(mode)
    }

    private func rememberEnabledMode(_ mode: CameraStabilizationMode) {
        if mode != .off { lastEnabledModeRaw = mode.rawValue }
    }
}

/// A touch begins one hardware ramp; finger-up or drag-off cancels it.
/// VoiceOver activation requests one bounded step, never an endless hold.
private struct ZoomHoldControl: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let revision: UInt64
    let begin: () -> Void
    let end: (UInt64) -> Void
    let step: () -> Void
    @State private var heldRevision: UInt64?
    @State private var cancelledUntilRelease = false

    var body: some View {
        GeometryReader { geometry in
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        let inside = CGRect(origin: .zero, size: geometry.size).contains(value.location)
                        if inside, heldRevision == nil, !cancelledUntilRelease {
                            heldRevision = revision
                            begin()
                        } else if !inside, let heldRevision {
                            end(heldRevision)
                            self.heldRevision = nil
                            cancelledUntilRelease = true
                        }
                    }
                    .onEnded { _ in
                        if let heldRevision { end(heldRevision) }
                        heldRevision = nil
                        cancelledUntilRelease = false
                    })
        }
        .frame(width: 44, height: 44)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .disabled(!enabled)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityHint("Press and hold to zoom slowly")
        .accessibilityAction { step() }
        .onChange(of: revision) { _, _ in
            if let heldRevision { end(heldRevision) }
            heldRevision = nil
            cancelledUntilRelease = false
        }
        .onDisappear {
            if let heldRevision { end(heldRevision) }
            heldRevision = nil
            cancelledUntilRelease = false
        }
    }
}

/// Native Slider is horizontal in the upright landscape face. Only portrait
/// turns its track; the complete panel then receives exactly one outer rotation.
struct ManualControlTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let landscape: Bool
    let length: CGFloat
    let label: String

    var body: some View {
        Group {
            if landscape {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Slider(value: $value, in: range, step: step)
                    .frame(width: length, height: 44)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: length)
            }
        }
        .tint(.white)
        .accessibilityLabel(label)
    }
}

/// No optimistic UI: a requested change is shown only after the snapshot updates.
enum ManualStabilizationSelection {
    static func toggleTarget(enabled: Bool, snapshot: CameraStabilizationSnapshot,
                             remembered: CameraStabilizationMode) -> CameraStabilizationMode? {
        guard snapshot.changesAllowed else { return nil }
        guard enabled else { return .off }
        let supported = snapshot.capability.availableModes.filter { $0 != .off }
        return supported.contains(remembered) ? remembered : supported.first
    }
}
