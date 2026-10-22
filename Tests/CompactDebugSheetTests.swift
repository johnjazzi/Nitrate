import Foundation
import Testing

/// Source-contract cover for the condensed DEBUG single-frame sheet.
///
/// `DebugFrameSheet` is a `#if DEBUG` SwiftUI/UIKit view; the macOS RenderCLI
/// test target cannot instantiate it (no UIKit, no Metal setup, no camera) and
/// the sheet is deliberately not part of that target's compiled sources. These
/// tests therefore read `DebugFrameSheet.swift` through `TestRepository.root`
/// and assert the **source contract** only:
///   * all seven control sections are collapsible and start collapsed,
///   * no section repeats a disclosure header inside its own content,
///   * the preview stays pinned outside the scrolling controls with its height
///     formula, aspect policy and zoom/pan/reset gestures intact,
///   * the retained controls keep their ranges, selection and callback route.
///
/// They prove the structure was preserved, not that the live gestures or the
/// Metal render behave — that still needs a device/simulator pass.
@Suite struct CompactDebugSheetTests {
    private static let sheetPath = "App/Modules/CameraCapture/DebugFrameSheet.swift"

    private func source() throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(Self.sheetPath),
                   encoding: .utf8)
    }

    /// Body of `private var <name>: some View { ... }`, up to the next
    /// top-level `private var <something>Section`/helper declaration.
    private func section(_ name: String, in source: String) throws -> String {
        let remainder = try #require(source.components(separatedBy: "private var \(name): some View {").last)
        return remainder
    }

    private static let titles = ["Stock", "Stock hint", "Grain", "Halation", "Glow",
                                 "Realized", "Debug controls"]

    @Test func everyControlSectionIsCollapsible() throws {
        let source = try source()
        #expect(source.components(separatedBy: "DebugCollapsibleSection(").count - 1 == 7,
                "all seven sections must be built from the collapsible container")
        for title in Self.titles {
            #expect(source.contains("title: \"\(title)\""),
                    "section \(title) must carry a disclosure header")
        }
        // One disclosure header per section: the titles must be unique.
        #expect(Set(Self.titles).count == Self.titles.count)
    }

    @Test func everySectionStartsCollapsed() throws {
        let source = try source()
        for flag in ["stockExpanded", "hintExpanded", "grainExpanded", "halationExpanded",
                     "glowExpanded", "realizedExpanded", "debugControlsExpanded"] {
            #expect(source.contains("@State private var \(flag) = false"),
                    "\(flag) must default to collapsed")
            #expect(!source.contains("@State private var \(flag) = true"),
                    "\(flag) must not start expanded")
        }
    }

    @Test func sectionsDoNotRepeatTheirDisclosureHeader() throws {
        let source = try source()
        // Each section's own content must not re-title it with a heading that
        // would duplicate the disclosure header above it.
        let stock = try section("stockSection", in: source)
        #expect(!stock.contains("Text(\"Stock\")"), "Stock header must not be duplicated in content")

        let hint = try section("hintPreviewSection", in: source)
        #expect(!hint.contains("Text(\"Stock hint\")"),
                "Stock hint header must not be duplicated in content")

        let realized = try section("realizedValues", in: source)
        #expect(!realized.contains("Text(\"Realized\")"),
                "Realized header must not be duplicated in content")

        let debug = try section("debugControlsSection", in: source)
        #expect(!debug.contains("Text(\"Debug controls\")"),
                "Debug controls header must not be duplicated in content")
    }

    @Test func orderingKeepsStockFirstThenEffectsThenDiagnostics() throws {
        let source = try source()
        let order = ["stockSection", "hintPreviewSection", "grainSection", "halationSection",
                     "glowSection", "realizedValues", "debugControlsSection"]
        let body = try #require(source.components(separatedBy: "ScrollView {").last)
            .components(separatedBy: ".padding()")[0]
        var cursor = body.startIndex
        for name in order {
            let index = try #require(body.range(of: name, range: cursor..<body.endIndex)?.lowerBound,
                                     "\(name) must appear after the previous section")
            cursor = index
        }
    }

    @Test func previewStaysPinnedOutsideTheScrollingControls() throws {
        let source = try source()
        let body = try #require(source.components(separatedBy: "VStack(spacing: 0) {").last)
        let previewIndex = try #require(body.range(of: "preview(height:")?.lowerBound)
        let scrollIndex = try #require(body.range(of: "ScrollView {")?.lowerBound)
        #expect(previewIndex < scrollIndex,
                "the preview must sit above the ScrollView, not inside it")
        // The pinned height formula and cap must be unchanged.
        #expect(source.contains("min(Self.maxPreviewHeight,"))
        #expect(source.contains("geometry.size.height * 0.45"))
        #expect(source.contains("maxPreviewHeight: CGFloat = 420"))
    }

    @Test func previewKeepsZoomPanDoubleTapResetAndAspectPolicy() throws {
        let source = try source()
        #expect(source.contains("zoomGesture.simultaneously(with: panGesture)"))
        #expect(source.contains(".onTapGesture(count: 2) { resetZoom() }"))
        #expect(source.contains("MagnifyGesture()"))
        #expect(source.contains("maxZoom: CGFloat = 8"))
        #expect(source.contains(".aspectRatio(contentMode: .fit)"))
        #expect(source.contains(".onChange(of: previewAspect)"))
        #expect(source.contains("fallbackAspect: CGFloat = 4.0 / 3.0"))
    }

    @Test func retainedControlsKeepRangesSelectionAndCallbackRoute() throws {
        let source = try source()
        let halation = try section("halationSection", in: source)
            .components(separatedBy: "private var glowSection: some View {")[0]
        #expect(halation.contains("in: 0...8, step: 0.01"))
        #expect(halation.contains("in: 0.0005...0.0030, step: 0.0001"))
        #expect(halation.components(separatedBy: "in: 0...1, step: 0.01").count == 4,
                "the three halation tint dials must retain their range")

        let glow = try section("glowSection", in: source)
        #expect(glow.contains("glowStrength"))

        let grain = try section("grainSection", in: source)
        #expect(grain.contains("gaugeBinding"))
        #expect(grain.contains("PrintGauge.allCases"))

        let stock = try section("stockSection", in: source)
        #expect(stock.contains("selectStock"))
        #expect(stock.contains(".pickerStyle(.menu)"))

        // Preview stock outline: record the request, then dismiss.
        let hint = try section("hintPreviewSection", in: source)
        let call = try #require(hint.range(of: "onPreviewStockOutline()")?.lowerBound)
        let dismiss = try #require(hint.range(of: "dismiss()")?.lowerBound)
        #expect(call < dismiss, "the outline request must be recorded before the sheet dismisses")

        let debug = try section("debugControlsSection", in: source)
        #expect(debug.contains("$showsDebugButton"))
        #expect(debug.contains("$showsFaultButton"))
    }

    @Test func realizedValuesKeepTruthfulOrderAndErrorDisplay() throws {
        let source = try source()
        let realized = try section("realizedValues", in: source)
        #expect(realized.contains("halation (scene-linear, pre-LUT)"),
                "the render order statement must stay truthful")
        #expect(realized.contains("viewModel.message"), "the error text must stay visible")
        #expect(realized.contains("lastRenderMilliseconds"))
    }

    @Test func disclosureHeadersKeepNativeTouchTargets() throws {
        let source = try source()
        let header = try #require(source.components(separatedBy: "private struct DebugCollapsibleSection").last)
        #expect(header.contains(".frame(minHeight: 44)"),
                "disclosure headers must keep a >=44pt touch target")
    }
}
