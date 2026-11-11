import Foundation
import Testing

struct PhotoExposureCadenceTests {
    @Test func meteringWaitsForTheSensorButTheOperatorDoesNot() {
        // A metering correction must not chase an exposure it just applied.
        #expect(PhotoExposureCadence.measurementInterval(duration: 0.25) >= 0.65)
        #expect(PhotoExposureCadence.measurementInterval(duration: 1) >= 2.15)
        #expect(PhotoExposureCadence.measurementInterval(duration: .nan) == 0.3)
    }

    @Test func commandCadenceIsIndependentOfTheExposureSoASlowRailStaysResponsive() {
        // Regression: the command interval used to be the measurement interval,
        // so at a 1 s shutter a user-driven write waited 2.15 s and the rail felt
        // frozen exactly at the slow end. Command pacing is now flat.
        #expect(PhotoExposureCadence.commandInterval <= 0.2)
        #expect(PhotoExposureCadence.commandInterval < PhotoExposureCadence.measurementInterval(duration: 1))
        #expect(PhotoExposureCadence.commandInterval < PhotoExposureCadence.measurementInterval(duration: 0.05))
    }
    @Test func unchangedAndQuantizedValuesDoNotWriteHardware() {
        #expect(!PhotoExposureCadence.needsWrite(iso: 400, duration: 0.25, actualISO: 400.039, actualDuration: 0.25))
        #expect(!PhotoExposureCadence.needsWrite(iso: 400, duration: 0.000014, actualISO: 400, actualDuration: 0.000018))
        #expect(PhotoExposureCadence.needsWrite(iso: 800, duration: 0.25, actualISO: 400, actualDuration: 0.25))
        #expect(PhotoExposureCadence.needsWrite(iso: 400, duration: 1, actualISO: 400, actualDuration: 0.25))
    }

    @Test func aDroppedAcknowledgementCannotOutlastTheShutter() {
        // Regression: an acknowledgement that never arrived (observed after a
        // profile rebuild) held the in-flight flag forever, and the shutter was
        // greyed out for the rest of the session. The watchdog has to fire well
        // inside the window an operator would call a lag.
        #expect(PhotoExposureCadence.setterTimeout > PhotoExposureCadence.commandInterval)
        #expect(PhotoExposureCadence.setterTimeout <= 2)
        #expect(PhotoExposureCadence.captureTimeout > PhotoExposureCadence.setterTimeout)
        #expect(PhotoExposureCadence.captureTimeout <= 5)
    }

    @Test func awaitingCaptureGivesUpOnTheExposureInsideAPerceptibleWindow() {
        // Regression: the tap was queued behind the exposure loop and could sit
        // there for the whole capture timeout, which reads as a dead shutter. The
        // photo is a snapshot of the exposure already installed, so the wait for
        // the operator's own unwritten intent is capped at a gesture debounce.
        #expect(PhotoExposureCadence.captureImpatience > 0)
        #expect(PhotoExposureCadence.captureImpatience <= 0.25)
        #expect(PhotoExposureCadence.captureImpatience < PhotoExposureCadence.captureTimeout)
        #expect(PhotoExposureCadence.captureImpatience <= PhotoExposureCadence.setterTimeout)
    }

    @Test func aDroppedCaptureTerminalCannotOutlastTheShutter() {
        // Regression: a capture transaction whose framework terminal callback never
        // arrived held `capturing` forever — the shutter stopped working for the
        // rest of the session and the readiness reported only "not ready". The
        // session now closes the transaction itself well inside a session-length
        // wait, and the view model's backstop sits behind it.
        #expect(PhotoExposureCadence.captureTransactionTimeout > PhotoExposureCadence.captureTimeout)
        #expect(PhotoExposureCadence.captureTransactionTimeout <= 10)
        #expect(PhotoExposureCadence.captureImpatience < PhotoExposureCadence.captureTimeout)
    }
}
