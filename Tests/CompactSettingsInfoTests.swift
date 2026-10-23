import Foundation
import Testing

/// Source-contract cover for the compact settings rows in `PurchaseView`.
///
/// `PurchaseView` is SwiftUI and is deliberately not part of this macOS test
/// target's compiled sources, so these tests read the source through
/// `TestRepository` and assert the **written structure and copy** only: the
/// trailing info button, the per-row collapsed-by-default disclosure, the
/// segmented selectors and the preserved qualifiers.
///
/// They are **structural only**. They do not exercise the live gestures,
/// VoiceOver output, the Reduce Motion branch, the animations or the rendered
/// layout — those still need a simulator/device pass.
@Suite struct CompactSettingsInfoTests {
    private static let settingsPath = "App/Modules/Purchase/PurchaseView.swift"

    private func source() throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(Self.settingsPath),
                   encoding: .utf8)
    }

    @Test func everyCompactRowCarriesATrailingInfoButton() throws {
        let source = try source()
        #expect(source.contains("private struct SettingsInfoButton"))
        #expect(source.contains(#"Image(systemName: "info.circle")"#))
        #expect(source.contains(".frame(minWidth: 44, minHeight: 44)"),
                "the info button must keep a >=44pt touch target")
        #expect(source.contains(#".accessibilityLabel("About \(subject)")"#))
        #expect(source.contains(#".accessibilityValue(isExpanded ? "Expanded" : "Collapsed")"#))
        // Both row containers place one info button at the trailing edge.
        #expect(source.components(separatedBy: "SettingsInfoButton(subject: accessibilityTitle,").count - 1 == 2)
    }

    @Test func eachRowDefaultsCollapsedAndOwnsIndependentState() throws {
        let source = try source()
        #expect(source.contains("private(set) var isExpanded = false"),
                "the disclosure default must be collapsed")
        #expect(!source.contains("private(set) var isExpanded = true"))
        #expect(source.contains("mutating func toggle() { isExpanded.toggle() }"))
        // Each row container owns its own instance, so expanding one row cannot
        // change another row's default.
        #expect(source.components(separatedBy: "@State private var disclosure = SettingsRowHelpState()").count - 1 == 2)
    }

    @Test func helpIsRevealedBelowTheControlOnlyWhileExpanded() throws {
        let source = try source()
        let controlRow = try #require(source.components(separatedBy: "private struct SettingsControlRow").last)
        let control = try #require(controlRow.range(of: "control()")?.lowerBound)
        let expanded = try #require(controlRow.range(of: "if disclosure.isExpanded {")?.lowerBound)
        let help = try #require(controlRow.range(of: "Text(help)")?.lowerBound)
        #expect(control < expanded && expanded < help,
                "the help must sit below the control and only while this row is expanded")
        #expect(controlRow.contains(".labelsHidden()"))
    }

    @Test func theInfoButtonOnlyRevealsHelpAndNeverChangesASetting() throws {
        let source = try source()
        let button = try #require(source.components(separatedBy: "private struct SettingsInfoButton").last)
            .components(separatedBy: "private struct SettingsControlRow")[0]
        for setting in ["previewMode", "recordingIndicatorStyle", "recordButtonAppearance",
                        "saveOriginalLog", "renderQuality", "showFramedPreview"] {
            #expect(!button.contains(setting),
                    "the info button must not read or write \(setting)")
        }
        // The shared helper only toggles the row's own disclosure state.
        let helpers = source.components(separatedBy: "private func toggleHelp() {")
        #expect(helpers.count - 1 == 2, "both row containers reveal help through the same helper")
        for remainder in helpers.dropFirst() {
            let end = try #require(remainder.range(of: "\n    }"))
            let helper = String(remainder[remainder.startIndex..<end.lowerBound])
            #expect(helper.contains("disclosure.toggle()"))
            #expect(!helper.contains("disclosure.isExpanded ="))
            #expect(helper.contains("withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2))"),
                    "the reveal must be Reduce Motion safe")
        }
    }

    @Test func allFourExclusiveSelectorsUseSegmentedPickers() throws {
        let source = try source()
        #expect(source.components(separatedBy: ".pickerStyle(.segmented)").count - 1 == 4,
                "the four short exclusive choices must be segmented")
        for label in [#"Picker("Preview Color""#, #"Picker("Recording Indicator""#,
                      #"Picker("Record button""#, #"Picker("Rendered File Size""#] {
            #expect(source.contains(label), "\(label) must keep its semantic label")
        }
        // The two binary settings keep native switches, not a segmented control.
        #expect(source.components(separatedBy: "Toggle(title, isOn: $isOn)").count - 1 == 1)
        #expect(!source.contains(#"Toggle("Save Original Log to Photos""#))
        #expect(!source.contains("Toggle(isOn: $showFramedPreview)"))
    }

    @Test func switchRowsKeepTheInfoButtonOutsideTheToggleLabel() throws {
        let source = try source()
        #expect(source.contains(#"SettingsToggleRow(title: "Frame Mode""#))
        #expect(source.contains(#"SettingsToggleRow(title: "Save Original Log to Photos""#))
        let toggleRow = try #require(source.components(separatedBy: "private struct SettingsToggleRow").last)
        let toggle = try #require(toggleRow.range(of: "Toggle(title, isOn: $isOn)")?.lowerBound)
        let info = try #require(toggleRow.range(of: "SettingsInfoButton(subject: accessibilityTitle,")?.lowerBound)
        #expect(toggle < info, "the info button is a sibling of the toggle, never nested in its label")
    }

    @Test func helpKeepsTheQualifiersWhileTheLongParagraphsAreGone() throws {
        let source = try source()
        for qualifier in ["Monitor only, never recorded",
                          "Recording stays Apple Log 2",
                          "If a preview LUT is unavailable, the",
                          "monitor shows Log with a warning",
                          "Top status lamp and elapsed timer only",
                          "WAIT: capture not yet confirmed",
                          "REC: capture confirmed",
                          "STOP: timer frozen while finalizing",
                          "Classic is raised",
                          "Modern is flat with a red outline",
                          "Viewfinder-style preview with visible controls",
                          "Saves the ungraded original recording alongside the rendered video; uses",
                          "additional storage. Not sensor RAW",
                          "High: 60 Mbps",
                          "30 Mbps",
                          "may soften grain",
                          "newly queued clips"] {
            #expect(source.contains(qualifier), "\(qualifier) must stay reachable behind the info buttons")
        }
        for removed in ["Neutral is the default monitor",
                        "roughly half the video bitrate",
                        "Record-button appearance is configured separately"] {
            #expect(!source.contains(removed),
                    "the long inline paragraph \"\(removed)\" must move behind an info button")
        }
    }

    @Test func pricingAndLegalStayCollapsedAndOutOfTheInfoRows() throws {
        let source = try source()
        #expect(source.contains(#"DisclosureGroup("Pricing""#))
        #expect(source.contains(#"DisclosureGroup("Legal & Support""#))
        #expect(source.contains(#"billing: "per year""#))
        #expect(source.contains(#"billing: "one time""#))
        #expect(source.contains("private func priceAmount"))
        // No price, billing, legal or purchase-error row is hidden behind an
        // info button.
        #expect(!source.contains(#"SettingsControlRow(title: "Yearly""#))
        #expect(!source.contains(#"SettingsControlRow(title: "Lifetime""#))
        #expect(!source.contains("SettingsToggleRow(title: \"Restore"))
    }

    @Test func existingAccessibilityAndPersistenceContractsAreUnchanged() throws {
        let source = try source()
        #expect(source.contains("@AppStorage(CameraPreviewMode.preferenceKey) private var previewMode = CameraPreviewMode.neutral.rawValue"))
        #expect(source.contains("@AppStorage(RecordingIndicatorStyle.preferenceKey)"))
        #expect(source.contains("@AppStorage(RecordButtonAppearance.preferenceKey)"))
        #expect(source.contains("@AppStorage(DeliverySettings.saveOriginalLogKey) private var saveOriginalLog = false"))
        #expect(source.contains("@AppStorage(DeliverySettings.renderQualityKey) private var renderQuality = RenderExportQuality.high.rawValue"))
        // The segmented Preview Color options keep their order and tags.
        let neutral = try #require(source.range(of: #"Text("Neutral").tag(CameraPreviewMode.neutral)"#)?.lowerBound)
        let stock = try #require(source.range(of: #"Text("Stock LUT").tag(CameraPreviewMode.stock)"#)?.lowerBound)
        let log = try #require(source.range(of: #"Text("Log").tag(CameraPreviewMode.log)"#)?.lowerBound)
        #expect(neutral < stock && stock < log)
    }
}
