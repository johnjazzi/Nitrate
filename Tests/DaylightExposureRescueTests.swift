import CoreGraphics
import Foundation
import Testing

/// Pure gate for the daylight exposure-rescue affordance. The button must appear
/// only when the live meter reads at least two stops brighter than the selected
/// exposure target, so it never fires on a matched or under-exposed scene.
struct DaylightExposureRescuePolicyTests {
    @Test func offersAtExactlyTwoStopsOverTarget() {
        #expect(DaylightExposureRescuePolicy.shouldOffer(meteredEV: 2, targetEV: 0, isAvailable: true))
        #expect(DaylightExposureRescuePolicy.shouldOffer(meteredEV: 2.01, targetEV: 0, isAvailable: true))
    }

    @Test func doesNotOfferJustBelowTwoStops() {
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 1.99, targetEV: 0, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 0, targetEV: 0, isAvailable: true))
    }

    @Test func usesTheSignedDifferenceNotAnAbsoluteDistance() {
        // A nonzero target still compares metered − target.
        #expect(DaylightExposureRescuePolicy.shouldOffer(meteredEV: 1, targetEV: -1, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: -1, targetEV: 1, isAvailable: true))
        // Under target by any amount never offers, however far the gap.
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 0, targetEV: 2, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: -8, targetEV: -2, isAvailable: true))
    }

    @Test func negativeReadingsCompareBySignedDifference() {
        #expect(DaylightExposureRescuePolicy.shouldOffer(meteredEV: -3, targetEV: -5, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: -4, targetEV: -5, isAvailable: true))
    }

    @Test func nonFiniteReadingsNeverOffer() {
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: .nan, targetEV: 0, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 0, targetEV: .nan, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: .infinity, targetEV: 0, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: -.infinity, targetEV: 0, isAvailable: true))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 100, targetEV: .infinity, isAvailable: true))
    }

    @Test func missingMeterNeverOffers() {
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 5, targetEV: 0, isAvailable: false))
        #expect(!DaylightExposureRescuePolicy.shouldOffer(meteredEV: 5, targetEV: -5, isAvailable: false))
    }

    @Test func confirmRequiresBothAvailabilityAndAnAllowedSwitch() {
        #expect(DaylightExposureRescuePolicy.canConfirm(available: true, canChange: true))
        #expect(!DaylightExposureRescuePolicy.canConfirm(available: false, canChange: true))
        #expect(!DaylightExposureRescuePolicy.canConfirm(available: true, canChange: false))
        #expect(!DaylightExposureRescuePolicy.canConfirm(available: false, canChange: false))
    }
}

/// Pure placement for the idle-only armed 60 fps badge. It mirrors the mood
/// timer: centred in the stationary toolbar row in portrait, at the physical top
/// edge in a quarter-turn hold. It can never claim a control slot and so never
/// hides the lens key or reserves toolbar height.
struct DaylightIdleBadgeGeometryTests {
    private let viewport = CGSize(width: 390, height: 844)

    @Test func portraitBadgeIsCenteredInTheStationaryToolbarRowWithoutASlot() throws {
        let rect = try #require(DaylightIdleBadgeGeometry.rect(
            viewport: viewport, toolbarBottom: 58, controlsTop: 664, rotationDegrees: 0))
        #expect(rect.size == DaylightIdleBadgeGeometry.badgeSize)
        #expect(rect.midX == viewport.width / 2)
        // Wholly inside the 50pt stationary row above the measured bottom edge.
        #expect(rect.maxY <= 58)
        #expect(rect.minY >= 8)
        // It never touches the leading keys (settings/manual) or the trailing lens.
        #expect(rect.minX > CameraTopPanelGeometry(width: viewport.width - 32, statusSize: .zero,
                                                   diagnosticsHeight: 0).manual.maxX + 16)
    }

    @Test func quarterTurnBadgeFloatsAtThePhysicalTopEdge() throws {
        for degrees in [90.0, -90.0] {
            let rect = try #require(DaylightIdleBadgeGeometry.rect(
                viewport: viewport, toolbarBottom: 150, controlsTop: 664, rotationDegrees: degrees))
            let edge = try #require(RecordingStatusOverlayGeometry.rect(
                viewport: viewport, toolbarBottom: 150, controlsTop: 664, rotationDegrees: degrees))
            #expect(abs(rect.midX - edge.midX) < 0.001)
            #expect(abs(rect.midY - edge.midY) < 0.001)
            #expect(!rect.intersects(CGRect(x: 0, y: 0, width: viewport.width, height: 58)))
        }
    }

    @Test func badgeIsOmittedWhenTheCanvasCannotHoldIt() {
        #expect(DaylightIdleBadgeGeometry.rect(viewport: CGSize(width: 390, height: 20),
                                               toolbarBottom: 58, controlsTop: 664,
                                               rotationDegrees: 0) == nil)
        #expect(DaylightIdleBadgeGeometry.rect(viewport: CGSize(width: 80, height: 844),
                                               toolbarBottom: 58, controlsTop: 664,
                                               rotationDegrees: 0) == nil)
    }
}

/// Pure placement for the rescue button: a full-canvas sibling above the measured
/// exposure column, never a child of `CameraShootingLayout`, so it cannot enlarge
/// the control bar's measured footprint. 92×44 portrait, 44×92 when held on a
/// quarter turn, always 6pt above the column.
struct DaylightExposureRescueGeometryTests {
    private let viewport = CGSize(width: 390, height: 844)
    private let exposure = CGRect(x: 298, y: 520, width: 92, height: 300)

    @Test func buttonSitsDirectlyAboveTheExposureColumn() throws {
        let rect = try #require(DaylightExposureRescueGeometry.buttonRect(above: exposure, in: viewport))
        #expect(rect.width == 92)
        #expect(rect.height == 44)
        #expect(rect.minX == exposure.minX)
        #expect(rect.maxY == exposure.minY - 6)
    }

    @Test func reservesRotatedBoundsWithoutChangingTheFaceSize() throws {
        let portrait = try #require(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, rotationDegrees: 0))
        #expect(portrait.size == CGSize(width: 92, height: 44))
        for degrees in [90.0, -90.0] {
            let landscape = try #require(DaylightExposureRescueGeometry.buttonRect(
                above: exposure, in: viewport, rotationDegrees: degrees))
            #expect(landscape.size == CGSize(width: 44, height: 92),
                    "A quarter-turn hold reserves the 44×92 rotated bound, not a shrunk face.")
        }
        // A half turn is not a quarter turn: the reserved bound stays 92×44.
        let upsideDown = try #require(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, rotationDegrees: 180))
        #expect(upsideDown.size == CGSize(width: 92, height: 44))
    }

    @Test func everyHoldKeepsTheSlotInsideTheViewportAndAboveTheMeter() throws {
        for degrees in [0.0, 90.0, -90.0] {
            let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
                above: exposure, in: viewport, rotationDegrees: degrees))
            let canvas = CGRect(origin: .zero, size: viewport)
            #expect(canvas.contains(rect), "The reserved slot must never leave the canvas.")
            #expect(rect.maxY == exposure.minY - 6, "The anchor is the exposure column's top edge, not the hold.")
            #expect(!rect.intersects(exposure), "The slot must not change the exposure footprint.")
        }
    }

    @Test func clampsHorizontallyInsideTheViewport() throws {
        let offRight = CGRect(x: 360, y: 520, width: 92, height: 300)
        let clampedRight = try #require(DaylightExposureRescueGeometry.buttonRect(above: offRight, in: viewport))
        #expect(clampedRight.maxX <= viewport.width)
        #expect(clampedRight.width == 92)

        let offLeft = CGRect(x: -30, y: 520, width: 92, height: 300)
        let clampedLeft = try #require(DaylightExposureRescueGeometry.buttonRect(above: offLeft, in: viewport))
        #expect(clampedLeft.minX == 0)
    }

    @Test func returnsNilWhenThereIsNoRoomAboveTheExposureColumn() {
        let high = CGRect(x: 298, y: 40, width: 92, height: 300)
        #expect(DaylightExposureRescueGeometry.buttonRect(above: high, in: viewport) == nil)
    }

    @Test func returnsNilWhenTheViewportCannotHoldTheButton() {
        #expect(DaylightExposureRescueGeometry.buttonRect(above: exposure,
                                                          in: CGSize(width: 60, height: 844)) == nil)
        #expect(DaylightExposureRescueGeometry.buttonRect(above: exposure,
                                                          in: CGSize(width: 390, height: 20)) == nil)
    }

    // MARK: - Manual-control exclusion

    /// The manual controls hug the physical right of the preview, overlapping the
    /// exposure column's own footprint — the case that made the "Too bright"
    /// affordance collide with them.
    private let manualControls = CGRect(x: 346, y: 120, width: 44, height: 500)

    @Test func keepsThePlainAnchorWhenTheManualControlsDoNotReachIt() throws {
        // A left-hand exclusion leaves the historical above-the-column slot clear.
        let far = CGRect(x: 20, y: 120, width: 44, height: 500)
        let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, excluding: far))
        #expect(rect == DaylightExposureRescueGeometry.buttonRect(above: exposure, in: viewport))
        #expect(rect.size == CGSize(width: 92, height: 44))
        #expect(rect.maxY == exposure.minY - 6)
        #expect(!rect.intersects(far))
    }

    @Test func portraitAvoidsTheManualControlsAboveLeftWithoutOverlap() throws {
        let base = try #require(DaylightExposureRescueGeometry.buttonRect(above: exposure, in: viewport))
        #expect(base.intersects(manualControls), "The unadjusted anchor really does collide here.")

        let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, excluding: manualControls))
        #expect(rect.size == CGSize(width: 92, height: 44))
        #expect(!rect.intersects(manualControls), "The slot must never overlap the manual controls.")
        // Above-left: both edges clear the controls by the gap.
        #expect(rect.maxY <= manualControls.minY - DaylightExposureRescueGeometry.gapBesideControls)
        #expect(rect.maxX <= manualControls.minX - DaylightExposureRescueGeometry.gapBesideControls)
        // Still above the exposure column and inside the canvas.
        #expect(rect.maxY <= exposure.minY - DaylightExposureRescueGeometry.gapAboveExposure)
        #expect(CGRect(origin: .zero, size: viewport).contains(rect))
    }

    @Test func quarterTurnAvoidsTheManualControlsWithRotatedBounds() throws {
        for degrees in [90.0, -90.0] {
            let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
                above: exposure, in: viewport, rotationDegrees: degrees, excluding: manualControls))
            #expect(rect.size == CGSize(width: 44, height: 92),
                    "The reserved bound turns for the hold; the face does not shrink.")
            #expect(!rect.intersects(manualControls))
            #expect(rect.maxY <= manualControls.minY - DaylightExposureRescueGeometry.gapBesideControls)
            #expect(rect.maxX <= manualControls.minX - DaylightExposureRescueGeometry.gapBesideControls)
            #expect(CGRect(origin: .zero, size: viewport).contains(rect))
        }
    }

    @Test func fallsBackToALeftOffsetWhenThereIsNoRoomAboveTheControls() throws {
        // A full-height manual column leaves no vertical room, but the left of the
        // column is still free: keep the exposure anchor and shift left.
        let tall = CGRect(x: 346, y: 0, width: 44, height: 844)
        let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, excluding: tall))
        #expect(rect.maxY == exposure.minY - DaylightExposureRescueGeometry.gapAboveExposure)
        #expect(rect.maxX <= tall.minX - DaylightExposureRescueGeometry.gapBesideControls)
        #expect(!rect.intersects(tall))
        #expect(CGRect(origin: .zero, size: viewport).contains(rect))
    }

    @Test func returnsNilWhenNoPlacementClearsTheControls() {
        // The controls span the whole canvas: no slot can stay inside the
        // viewport and clear them, so the affordance is omitted rather than drawn
        // over the controls.
        let everything = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        #expect(DaylightExposureRescueGeometry.buttonRect(
            above: exposure, in: viewport, excluding: everything) == nil)
    }

    @Test func degenerateExclusionFallsBackToThePlainAnchor() throws {
        for degenerate in [CGRect.zero, CGRect(x: 100, y: 100, width: 0, height: 50),
                           CGRect(x: 100, y: 100, width: 50, height: 0)] {
            let rect = try #require(DaylightExposureRescueGeometry.buttonRect(
                above: exposure, in: viewport, excluding: degenerate))
            #expect(rect == DaylightExposureRescueGeometry.buttonRect(above: exposure, in: viewport))
        }
    }

    @Test func neverIntersectsTheManualControlsAcrossHolds() throws {
        let canvases = [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568),
                        CGSize(width: 430, height: 932)]
        for canvas in canvases {
            let column = CGRect(x: canvas.width - 92, y: canvas.height - 340, width: 92, height: 300)
            let controls = CGRect(x: canvas.width - 44, y: 120, width: 44, height: canvas.height - 320)
            for degrees in [0.0, 90.0, -90.0, 180.0] {
                guard let rect = DaylightExposureRescueGeometry.buttonRect(
                    above: column, in: canvas, rotationDegrees: degrees,
                    excluding: controls) else { continue }
                #expect(!rect.intersects(controls),
                        "Hold \(degrees) on \(canvas) must not overlap the manual controls.")
                #expect(CGRect(origin: .zero, size: canvas).contains(rect))
            }
        }
    }
}