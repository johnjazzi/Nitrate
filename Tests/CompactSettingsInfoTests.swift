import Foundation
import Testing

/// Source-contract cover for the compact settings rows in `PurchaseView` and the
/// standalone controls they use (`SettingsSelectionRow.swift`).
///
/// `PurchaseView` is SwiftUI and is deliberately not part of this macOS test
/// target's compiled sources, so these tests read the sources through
/// `TestRepository` and assert the **written structure and copy** only: the
/// leading icon and label, the trailing compact selected-value buttons, the
/// compact switch style, the per-row collapsed disclosure and the preserved
/// qualifiers.
///
/// They are **structural only**. They do not exercise the live gestures,
/// VoiceOver output, the Reduce Motion branch, the animations or the rendered
/// layout — those still need a simulator/device pass.
@Suite struct CompactSettingsInfoTests {
    private static let settingsPath = "App/Modules/Purchase/PurchaseView.swift"
    private static let controlsPath = "App/Modules/Purchase/SettingsSelectionRow.swift"

    private func source(_ path: String = Self.settingsPath) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
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

    @Test func rowsLeadWithAnIconAndLabel() throws {
        let source = try source()
        let controls = try self.source(Self.controlsPath)
        #expect(controls.contains("struct SettingsRowLabel"))
        #expect(controls.contains(#"Image(systemName: icon)"#))
        #expect(controls.contains(".accessibilityHidden(true)"),
                "the leading icon is decorative; the label carries the name")
        // Both row containers lead with the icon-and-label view.
        #expect(source.components(separatedBy: "SettingsRowLabel(icon: icon, title: title)").count - 1 == 2)
        // The six primary rows each pass a distinct leading symbol.
        for icon in ["camera.filters", "record.circle", "button.programmable",
                     "viewfinder", "square.and.arrow.down", "arrow.up.arrow.down.circle"] {
            #expect(source.contains("icon: \"\(icon)\""), "the \(icon) row must lead with its icon")
        }
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

    @Test func exclusiveChoicesUseTheCompactSelectedValueButtonNotASegmentedStrip() throws {
        let source = try source()
        let controls = try self.source(Self.controlsPath)
        #expect(!source.contains(".pickerStyle(.segmented)"),
                "the enumerated choices must not use a segmented strip")
        #expect(controls.contains("struct SettingsSelectionRow"),
                "the reusable selected-value control must exist")
        #expect(controls.contains("struct SettingsValueLabel"))
        #expect(controls.contains("Menu {"),
                "the value button opens a menu of the choices")
        #expect(controls.contains(#"Image(systemName: "chevron.down")"#),
                "the value button is marked with a chevron")
        // The four short exclusive choices each use the compact value button, and
        // each keeps its semantic native picker at the call site (so the choices
        // stay reachable and the selected one is checked).
        #expect(source.components(separatedBy: "SettingsSelectionRow(title:").count - 1 == 4)
        for title in ["Preview Color", "Recording Indicator", "Record button", "Rendered File Size"] {
            #expect(source.contains("SettingsSelectionRow(title: \"\(title)\""),
                    "\(title) must use the compact value button")
            #expect(source.contains("Picker(\"\(title)\""),
                    "\(title) must keep its native picker for the menu semantics")
        }
        // The two binary settings keep native switches, not a value button.
        #expect(source.components(separatedBy: "Toggle(title, isOn: $isOn)").count - 1 == 1)
        #expect(!source.contains(#"Toggle("Save Original Log to Photos""#))
        #expect(!source.contains("Toggle(isOn: $showFramedPreview)"))
    }

    @Test func compactSwitchStylePreservesNativeToggleSemantics() throws {
        let source = try source()
        let controls = try self.source(Self.controlsPath)
        #expect(controls.contains("struct SettingsToggleStyle"))
        #expect(controls.contains(": ToggleStyle"))
        #expect(controls.contains(".toggleStyle(.switch)"),
                "The accessibility representation must not inherit the custom style recursively")
        #expect(controls.contains(".accessibilityRepresentation"),
                "the custom face must restore the native switch role")
        #expect(controls.contains("Toggle(isOn: configuration.$isOn)"),
                "the switch keeps its native on/off binding and label")
        #expect(controls.contains(".frame(minWidth: 44, minHeight: 44)"),
                "the compact switch keeps a >=44pt hit target")
        #expect(controls.contains("accessibilityReduceMotion"))
        #expect(controls.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOn)"),
                "Reduce Motion must stop the thumb movement")
        // Grayscale inset language, no accent color.
        #expect(controls.contains("SettingsControlChrome.rim"))
        #expect(!controls.contains("orange") && !controls.contains("Orange"),
                "the compact switch must stay grayscale, not take an accent")
        // The toggle row applies the compact style exactly once.
        #expect(source.components(separatedBy: ".toggleStyle(SettingsToggleStyle())").count - 1 == 1)
    }

    @Test func switchRowsKeepTheInfoButtonOutsideTheToggleLabel() throws {
        let source = try source()
        #expect(source.contains(#"SettingsToggleRow(icon: "viewfinder""#))
        #expect(source.contains(#"SettingsToggleRow(icon: "square.and.arrow.down""#))
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
        // The Preview Color choices keep their order and tags.
        let neutral = try #require(source.range(of: #"Text("Neutral").tag(CameraPreviewMode.neutral)"#)?.lowerBound)
        let stock = try #require(source.range(of: #"Text("Stock LUT").tag(CameraPreviewMode.stock)"#)?.lowerBound)
        let log = try #require(source.range(of: #"Text("Log").tag(CameraPreviewMode.log)"#)?.lowerBound)
        #expect(neutral < stock && stock < log)
    }
}
