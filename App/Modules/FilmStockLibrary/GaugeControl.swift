#if os(iOS)
import SwiftUI

/// The print-gauge control, shared by the stock sheet and the Develop panel.
///
/// Extracted so Develop offers the SAME control rather than a second one: one
/// segmented picker, one info sheet, one set of identifiers. The caller owns the
/// binding and the width (see `StockSheetLayout`), so both surfaces size it the
/// same way.
///
/// The gauge owns grain size, grain presence AND the lens diffusion radius and
/// amount — the format's enlargement is what sets how far the light spreads. The
/// info sheet says so; halation is the stock's, not the gauge's.
struct GaugeControl: View {
    @Binding var gauge: PrintGauge
    /// Sheet state is owned here so every caller gets the same explanation
    /// without wiring a presentation up itself.
    @State private var showsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Gauge · mm")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Button { showsInfo = true } label: {
                    Image(systemName: "info.circle.fill")
                        .font(NitrateTypography.font(.footnote))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stock.gaugeInfo")
                .accessibilityLabel("What the print gauge changes")
                Spacer(minLength: 0)
            }
            Picker("Print Gauge", selection: $gauge) {
                ForEach(PrintGauge.allCases, id: \.self) { candidate in
                    Text(Self.shortLabel(candidate)).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(height: 34)
            .accessibilityIdentifier("stock.gauge")
            .accessibilityValue(gauge.displayName)
        }
        .sheet(isPresented: $showsInfo) { GaugeInfoSheet(isPresented: $showsInfo) }
    }

    /// Segment label only: the caption above carries the unit, so four gauges fit
    /// a third of a 320pt row without truncating.
    static func shortLabel(_ gauge: PrintGauge) -> String {
        gauge.displayName.replacingOccurrences(of: "mm", with: "")
    }
}

/// What the gauge actually does, and what it does not.
///
/// Every claim here must be one the render can back: the gauge sets grain size,
/// grain presence and the diffusion ladder; halation, glow and push/pull are not
/// the gauge's.
struct GaugeInfoSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Print gauge",
                            "The film format the stock is printed on. It sets the grain and the "
                            + "lens diffusion, and nothing else in the look.")
                    section("8 mm", "Coarsest and loudest. Grain reads as a texture over the frame, "
                            + "and the diffusion spreads furthest — 35 px at a 1080p frame.")
                    section("16 mm", "Coarse, about half the footprint of 8 mm, with a 16 px "
                            + "diffusion radius.")
                    section("35 mm", "The standard look and the middle of the ladder: the sharpest "
                            + "gauge that diffuses at all, at 4 px.")
                    section("75 mm", "Fine and nearly grain-free, and the only format that does not "
                            + "diffuse: the halo is skipped entirely. Grain is made quiet by "
                            + "lowering its presence, not by shrinking it out of existence.")
                    Divider().overlay(Color.white.opacity(0.12))
                    section("Not changed by the gauge",
                            "Halation belongs to the stock: it comes from the emulsion, so "
                            + "switching gauge leaves the halo alone. Glow and output contrast are "
                            + "the stock's too.")
                    section("Push / pull",
                            "Develops the take at -3 to +2 stops before the grade. Pulling holds "
                            + "the highlights down and darkens the image; pushing lifts it. It does "
                            + "not change grain size, the gauge, or the halo.")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Print gauge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(NitrateTypography.font(.subheadline))
                .foregroundStyle(.primary)
            Text(body)
                .font(NitrateTypography.font(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
