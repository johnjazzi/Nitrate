import Foundation
import Testing

struct PhotoExposureReconciliationTests {
    private func snapshot(iso: Float = 700, duration: Double = 1.0 / 30,
                          isoLocked: Bool = false, shutterLocked: Bool = true) -> PhotoExposureSnapshot {
        PhotoExposureSnapshot(iso: iso, durationSeconds: duration, isoRange: 50...800,
            shutterRange: 1.0 / 8000...1, isoLocked: isoLocked, shutterLocked: shutterLocked,
            ev: 0, meteringOffset: 0, isSettling: false, canCapture: true, targetLimited: false)
    }

    @Test(arguments: [Float(1), -6])
    func limitedISOCommandIsInstalledOnceThenSuppressesIdenticalWrites(_ ev: Float) throws {
        let before = snapshot()
        let decision = try PhotoExposurePolicy.decide(snapshot: before,
            request: .init(ev: ev, measuredEV: 0, maxCorrectionEV: 6))
        #expect(decision.targetLimited)
        #expect(!decision.isSettling)
        let command = try #require(decision.command(for: before))
        #expect(command.iso == (ev > 0 ? 800 : 50))
        #expect(command.durationSeconds == before.durationSeconds)
        let applied = snapshot(iso: command.iso)
        let next = try PhotoExposurePolicy.decide(snapshot: applied,
            request: .init(ev: ev, measuredEV: 0, maxCorrectionEV: 6))
        #expect(next.command(for: applied) == nil)
    }

    @Test func limitedTargetCanReturnInsideRange() throws {
        let state = snapshot(iso: 800)
        let decision = try PhotoExposurePolicy.decide(snapshot: state,
            request: .init(ev: -1, measuredEV: 0, maxCorrectionEV: 1))
        #expect(!decision.targetLimited)
        #expect(decision.command(for: state)?.iso == 400)
    }

    @Test func apertureAutoReentersNativeAEOnlyWithNeitherExposureLegHeld() {
        #expect(PhotoExposurePolicy.usesNativeAutoExposure(isoLocked: false, shutterLocked: false, apertureHeld: false))
        for holds in [(true, false), (false, true), (true, true)] {
            #expect(!PhotoExposurePolicy.usesNativeAutoExposure(isoLocked: holds.0,
                shutterLocked: holds.1, apertureHeld: false))
        }
        #expect(!PhotoExposurePolicy.usesNativeAutoExposure(isoLocked: false, shutterLocked: false, apertureHeld: true))
    }

    @Test func apertureHeldBothAutoUsesBoundedISOLever() throws {
        let state = snapshot(isoLocked: false, shutterLocked: false)
        let decision = try PhotoExposurePolicy.decide(snapshot: state,
            request: .init(ev: 1, measuredEV: 0, maxCorrectionEV: 1), apertureHeld: true)
        #expect(!decision.usesAutoExposure)
        #expect(decision.targetLimited)
        #expect(decision.command(for: state)?.iso == 800)
        #expect(decision.command(for: state)?.durationSeconds == state.durationSeconds)
    }

    @Test func nativeBiasedAndCustomMeterReadingsShareNeutralCoordinates() {
        #expect(PhotoExposureSnapshot.neutralMeteringOffset(rawOffset: 0, installedBias: -1.2) == -1.2)
        #expect(PhotoExposureSnapshot.neutralMeteringOffset(rawOffset: -1.2, installedBias: 0) == -1.2)
        let native = PhotoExposureSnapshot.neutralMeteringOffset(rawOffset: 2.1, installedBias: -1.2)
        let custom = PhotoExposureSnapshot.neutralMeteringOffset(rawOffset: 0.9, installedBias: 0)
        #expect(abs(native - custom) < 0.000001)
    }

    @Test func sameRangeNewControllerCancelsPendingPresentation() {
        var first = snapshot()
        first.sourceID = UUID()
        var state = PhotoExposureIntentPresentation(snapshot: first)
        state.select(duration: 0.5)
        state.selectISO(400)
        var replacement = snapshot(iso: 200)
        replacement.sourceID = UUID()
        state.reconcile(replacement)
        #expect(state.pendingDuration == nil)
        #expect(state.pendingISO == nil)
        #expect(state.duration == replacement.durationSeconds)
        #expect(state.iso == replacement.iso)
    }
}
