import Foundation
import Testing

/// Regressions for the scoped "too bright" options: the pull rung and the
/// aperture target must be real destinations from the existing owners, and the
/// compact card must stay free of the old editorial copy. Pure — no camera.
struct DaylightRescueOptionTests {
    // MARK: - Pull ladder

    @Test func pullTakesTheNextRealRungDarker() {
        #expect(DaylightRescuePullPolicy.nextStops(after: -1, floor: -3) == -2)
        #expect(DaylightRescuePullPolicy.nextStops(after: -2, floor: -3) == -3)
    }

    /// A pushed or neutral take resolves to a **negative** pull. Stops are signed,
    /// so "one step darker" from +2/+1/0 is -1 — not +1 or 0, which would develop
    /// brighter than the take the operator was rescuing.
    @Test func pullFromAPushOrNeutralIsAlwaysARealNegativePull() {
        #expect(DaylightRescuePullPolicy.nextStops(after: 2, floor: -3) == -1)
        #expect(DaylightRescuePullPolicy.nextStops(after: 1, floor: -3) == -1)
        #expect(DaylightRescuePullPolicy.nextStops(after: 0, floor: -3) == -1)
        // The destination survives the ladder owner unchanged: a real PULL rung.
        #expect(PushPullStops.nearest(to: -1) == .pullOne)
        #expect(PushPullStops.nearest(to: -1).effectWord == "PULL")
    }

    @Test func pullStopsAtTheLadderFloor() {
        #expect(DaylightRescuePullPolicy.nextStops(after: -3, floor: -3) == nil)
        // A rung below the floor can only clamp back to the floor, never past it.
        #expect(DaylightRescuePullPolicy.nextStops(after: -5, floor: -3) == nil)
    }

    @Test func pullRefusesANonNegativeFloorRatherThanInventingARung() {
        // A non-negative floor is not a pull ladder minimum; no destination.
        #expect(DaylightRescuePullPolicy.nextStops(after: 0, floor: 0) == nil)
        #expect(DaylightRescuePullPolicy.nextStops(after: 2, floor: 1) == nil)
        #expect(DaylightRescuePullPolicy.nextStops(after: -1, floor: 0) == nil)
    }

    @Test func pullTitleStatesTheAmountWithSingularStops() {
        // Magnitude only: the row says "Pull 2 stops", never "Pull -2 stops".
        #expect(DaylightRescuePullPolicy.title(forStops: -1) == "Pull 1 stop")
        #expect(DaylightRescuePullPolicy.title(forStops: -2) == "Pull 2 stops")
    }

    @Test func pullRowIsRefusedWithoutAStockAndAtTheFloor() {
        #expect(!DaylightRescuePresentation.pull(stockSelected: false, currentStops: nil,
                                                 floor: -3, busy: false).enabled)
        let atFloor = DaylightRescuePresentation.pull(stockSelected: true, currentStops: -3,
                                                      floor: -3, busy: false)
        #expect(!atFloor.enabled)
        #expect(atFloor.title == "Maximum pull")
    }

    @Test func pullRowIsRefusedWhileBusyButStillNamesItsDestination() {
        let row = DaylightRescuePresentation.pull(stockSelected: true, currentStops: 0,
                                                  floor: -3, busy: true)
        #expect(!row.enabled)
        #expect(row.title == "Pull 1 stop")
    }

    @Test func pullRowFromAPushedTakeNamesARealPull() {
        let row = DaylightRescuePresentation.pull(stockSelected: true, currentStops: 2,
                                                  floor: -3, busy: false)
        #expect(row.enabled)
        #expect(row.title == "Pull 1 stop")
        #expect(!row.title.contains("-"))
    }

    @Test func pullRowNeverClaimsACaptureChange() {
        let row = DaylightRescuePresentation.pull(stockSelected: true, currentStops: 0,
                                                  floor: -3, busy: false)
        #expect(row.enabled)
        #expect(row.detail.contains("not a capture change"))
        #expect(!row.detail.lowercased().contains("clip"))
        #expect(!row.detail.lowercased().contains("light"))
    }

    // MARK: - Aperture ladder

    @Test func aperturePicksTheNextSupportedStopNotAnInventedOne() {
        #expect(DaylightRescueAperturePolicy.nextStop(after: 1.78, stops: [1.78, 2.8, 4.0]) == 2.8)
        #expect(DaylightRescueAperturePolicy.nextStop(after: 2.8, stops: [1.78, 2.8, 4.0]) == 4.0)
    }

    @Test func apertureOffersNothingWithoutACurrentOrHigherStop() {
        // Unknown iris, no rung above the current one, and a fixed lens' empty
        // ladder all offer no destination rather than an invented close.
        #expect(DaylightRescueAperturePolicy.nextStop(after: nil, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.nextStop(after: 4.0, stops: [1.78, 2.8, 4.0]) == nil)
        #expect(DaylightRescueAperturePolicy.nextStop(after: 1.78, stops: []) == nil)
    }

    @Test func apertureTitlePrintsTheDestinationFNumber() {
        #expect(DaylightRescueAperturePolicy.title(forStop: 2.8) == "Close to f/2.8")
        #expect(DaylightRescuePresentation.aperture(nextStop: 2.8, enabled: true)?.title
                == "Close to f/2.8")
        #expect(DaylightRescuePresentation.aperture(nextStop: nil, enabled: true) == nil)
    }

    @Test func apertureRowDisablesWhileBusy() {
        let row = DaylightRescuePresentation.aperture(nextStop: 4.0, enabled: false)
        #expect(row?.enabled == false)
    }

    // MARK: - Independence from 60 fps

    @Test func missingSixtySupportDoesNotRemovePullOrAperture() {
        let sixty = DaylightRescuePresentation.sixty(armed: false, available: false, canChange: true)
        #expect(!sixty.enabled)
        // The other two rows are built from their own owners and stay available.
        #expect(DaylightRescuePresentation.pull(stockSelected: true, currentStops: 0,
                                                floor: -3, busy: false).enabled)
        #expect(DaylightRescuePresentation.aperture(nextStop: 2.8, enabled: true)?.enabled == true)
    }

    @Test func armedSixtyRowOffersTheReturnTo24() {
        let row = DaylightRescuePresentation.sixty(armed: true, available: true, canChange: true)
        #expect(row.enabled)
        #expect(row.title == "Return to 24 fps")
    }

    /// Capability gates entering 60 fps only. An armed session whose capability
    /// read has since gone false (lens or format change) must still be able to
    /// return to 24, or it is stranded in 60 fps. The busy gate still wins.
    @Test func armedSixtyRowReturnsTo24EvenWhenTheCapabilityIsGone() {
        let row = DaylightRescuePresentation.sixty(armed: true, available: false, canChange: true)
        #expect(row.enabled)
        #expect(row.title == "Return to 24 fps")
        // Busy still blocks the return leg.
        let busy = DaylightRescuePresentation.sixty(armed: true, available: false, canChange: false)
        #expect(!busy.enabled)
        #expect(busy.title == "Return to 24 fps")
        // And the missing capability still refuses *entering* 60 fps.
        let enter = DaylightRescuePresentation.sixty(armed: false, available: false, canChange: true)
        #expect(!enter.enabled)
    }

    // MARK: - Source wiring

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }

    @Test func rescueCardDropsTheLongEditorialCopy() throws {
        let card = try source("App/Modules/CameraCapture/ExposureRescueControl.swift")
        #expect(!card.contains("The Hobbit"))
        #expect(!card.contains("highly sensitive sensors"))
        #expect(!card.contains("24 fps or 60 fps?"))
        let view = try source("App/ContentView.swift")
        #expect(view.contains("DaylightRescuePresentation.pull("))
        #expect(view.contains("DaylightRescueAperturePolicy.nextStop("))
    }

    @Test func contentViewRoutesTheThreeOptionsToTheirOwners() throws {
        let view = try source("App/ContentView.swift")
        #expect(view.contains("library.setPushPull(PushPullPreference(isAutomatic: false"))
        #expect(view.contains("cameraViewModel.setLensAperture(apertureStop)"))
        #expect(view.contains("cameraViewModel.setDaylight60Enabled(enabled)"))
        // The canonical capability gate still guards the aperture destination.
        #expect(view.contains("guard cameraViewModel.canSelectAperture, !cameraViewModel.isChangingFrameRate"))
        // Submission re-checks busy, and the aperture destination is unwrapped —
        // nil means Auto in the canonical API, so it is never forwarded.
        #expect(view.contains("guard !daylightRescueBusy, let apertureStop else { return }"))
        #expect(view.contains("guard !daylightRescueBusy,\n"))
    }

    @Test func aboutPageCarriesTheFrameRateHeadingAndRealVersionLine() throws {
        let about = try source("App/Modules/Purchase/AboutView.swift")
        #expect(about.contains("24 FPS vs 30 or 60 FPS"))
        #expect(about.contains("AboutPresentation.versionLine()"))
        #expect(about.contains("AboutPresentation.versionRowID"))
        // No invented essay: the body is an explicit, empty edit point.
        #expect(about.contains("static let frameRateSectionCopy: String? = nil"))
    }

    @Test func settingsLinksToTheAboutPage() throws {
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("NavigationLink {"))
        #expect(settings.contains("AboutView()"))
    }
}
