import Foundation
import Testing

/// Regressions for the scoped "too bright" options: both destinations must be
/// real values from the existing owners, and both must move as far as that owner
/// allows in a single tap — a two-stop pull, and the lens' strongest supported
/// f-number. The compact card must stay free of the old editorial copy. Pure —
/// no camera.
struct DaylightRescueOptionTests {
    // MARK: - Pull ladder

    /// The offer itself already means ≥2 EV over target, so one tap must deliver
    /// the two-stop pull — not a single rung that leaves the frame two stops hot.
    @Test func pullJumpsTwoStopsFromANeutralOrPushedTake() {
        #expect(DaylightRescuePullPolicy.nextStops(after: 2, floor: -3) == -2)
        #expect(DaylightRescuePullPolicy.nextStops(after: 1, floor: -3) == -2)
        #expect(DaylightRescuePullPolicy.nextStops(after: 0, floor: -3) == -2)
        // The destination survives the ladder owner unchanged: a real PULL rung.
        #expect(PushPullStops.nearest(to: -2) == .pullTwo)
        #expect(PushPullStops.nearest(to: -2).effectWord == "PULL")
    }

    /// A second request from an already pulled take moves two rungs darker and
    /// clamps at the ladder floor; it never brightens and never overshoots -3.
    @Test func aFurtherRequestFromAnExistingPullMovesTwoRungsAndClamps() {
        #expect(DaylightRescuePullPolicy.nextStops(after: -1, floor: -3) == -3)
        #expect(DaylightRescuePullPolicy.nextStops(after: -2, floor: -3) == -3,
                "Two rungs past -2 is -4; the ladder floor caps it at -3.")
    }

    @Test func pullNeverOvershootsTheFloorOrBrightensAPull() {
        for current in -6...6 {
            for floor in -6 ... -1 {
                guard let next = DaylightRescuePullPolicy.nextStops(after: current, floor: floor) else { continue }
                #expect(next >= floor, "Destination \(next) went past floor \(floor).")
                #expect(next < current, "Destination \(next) from \(current) is not darker.")
            }
        }
        #expect(DaylightRescuePullPolicy.nextStops(after: -3, floor: -3) == nil)
        #expect(DaylightRescuePullPolicy.nextStops(after: -5, floor: -3) == nil)
        // A clamped floor shorter than two stops below neutral still moves two.
        #expect(DaylightRescuePullPolicy.nextStops(after: 0, floor: -2) == -2)
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
        #expect(DaylightRescuePullPolicy.title(forStops: -3) == "Pull 3 stops")
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
        #expect(row.title == "Pull 2 stops")
    }

    @Test func pullRowFromAPushedTakeNamesARealPull() {
        let row = DaylightRescuePresentation.pull(stockSelected: true, currentStops: 2,
                                                  floor: -3, busy: false)
        #expect(row.enabled)
        #expect(row.title == "Pull 2 stops")
        #expect(!row.title.contains("-"))
    }

    @Test func pullRowFromAnAlreadyPulledTakeNamesTheClampedJump() {
        let row = DaylightRescuePresentation.pull(stockSelected: true, currentStops: -1,
                                                  floor: -3, busy: false)
        #expect(row.enabled)
        #expect(row.title == "Pull 3 stops")
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

    /// One tap must stop down as far as the lens reports, so f/4 is chosen
    /// directly from f/1.78 rather than stepping through f/2.8 first.
    @Test func apertureJumpsToTheStrongestSupportedStop() {
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78, 2.8, 4.0]) == 4.0)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 2.8, stops: [1.78, 2.8, 4.0]) == 4.0)
        // The destination is the owner's own value, not a rounded copy of it.
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 2.8, stops: [2.8, 4.0]) == 4.0)
    }

    @Test func apertureTakesTheTrueMaximumOfAnUnsortedOrDuplicatedLadder() {
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [4.0, 1.78, 2.8]) == 4.0)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [2.8, 4.0, 4.0, 1.78]) == 4.0)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 4.0, stops: [4.0, 1.78, 2.8]) == nil)
    }

    /// No guessed f/4 on a lens that stops at f/2.8: the destination is always a
    /// stop the capability reports.
    @Test func apertureNeverGuessesAStopTheLensDoesNotReport() {
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78, 2.8]) == 2.8)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 2.8, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: []) == nil)
        // A fixed lens reports one stop, which is never above itself.
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78]) == nil)
    }

    @Test func apertureOffersNothingWithoutAValidCurrentIris() {
        #expect(DaylightRescueAperturePolicy.strongestStop(after: nil, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 0, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: -1.78, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: .nan, stops: [1.78, 2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: .infinity, stops: [1.78, 2.8]) == nil)
    }

    @Test func apertureIgnoresNonFiniteAndNonPositiveLadderEntries() {
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78, 4.0, .nan, .infinity]) == 4.0)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78, .nan, .infinity]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [1.78, 0, -2.8]) == nil)
        #expect(DaylightRescueAperturePolicy.strongestStop(after: 1.78, stops: [.nan]) == nil)
    }

    @Test func apertureTitlePrintsTheDestinationFNumber() {
        #expect(DaylightRescueAperturePolicy.title(forStop: 2.8) == "Stop down to f/2.8")
        // A whole stop keeps the lens' f/4 form rather than f/4.0.
        #expect(DaylightRescueAperturePolicy.title(forStop: 4.0) == "Stop down to f/4")
        #expect(DaylightRescuePresentation.aperture(nextStop: 4.0, enabled: true)?.title
                == "Stop down to f/4")
        #expect(DaylightRescuePresentation.aperture(nextStop: nil, enabled: true) == nil)
    }

    @Test func apertureRowNamesTheStrongestStopAndItsScope() {
        let row = DaylightRescuePresentation.aperture(nextStop: 4.0, enabled: true)
        #expect(row?.enabled == true)
        #expect(row?.detail == "Strongest stop · applies to the next take")
        // The row never claims the live preview is unchanged or that highlights
        // were recovered from the recorded take.
        #expect(row?.detail.lowercased().contains("clip") == false)
        #expect(row?.detail.lowercased().contains("recover") == false)
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
        #expect(view.contains("DaylightRescueAperturePolicy.strongestStop("))
    }

    /// The row the operator reads and the value the tap writes are resolved by
    /// the same policy call with the same owner-owned floor, so the destination
    /// shown is the destination applied.
    @Test func rescueRowsAndTheirActionsResolveTheSameDestination() throws {
        let view = try source("App/ContentView.swift")
        func occurrences(of needle: String) -> Int {
            view.components(separatedBy: needle).count - 1
        }
        #expect(occurrences(of: "floor: PushPullStops.pullThree.rawValue") == 2,
                "The row and the tap must both use the ladder owner's own floor.")
        // The row renders the same take the tap will read, through the same
        // policy: `pull(...)` for display, `nextStops(after:)` for the write.
        #expect(view.contains("currentStops: daylightRescueCurrentPullStops"))
        #expect(view.contains("let current = daylightRescueCurrentPullStops"))
        #expect(occurrences(of: "DaylightRescuePullPolicy.nextStops(") == 1)
        // Aperture: one destination, resolved above the overlay and forwarded
        // unchanged to the canonical setter.
        #expect(view.contains("let apertureStop = daylightRescueApertureStop"))
        #expect(view.contains("cameraViewModel.setLensAperture(apertureStop)"))
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
