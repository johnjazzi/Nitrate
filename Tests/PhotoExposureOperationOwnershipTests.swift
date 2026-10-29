import Foundation
import Testing

struct PhotoExposureOperationOwnershipTests {
    /// Swift Testing's expectation macros evaluate their expression in a
    /// non-mutating closure, so the value-type owner lives behind a reference to
    /// let the assertions call its mutating API directly.
    private final class Owner {
        var value = PhotoExposureOperationOwnership()
    }

    // Swift Testing rewrites `#expect` arguments into a closure over an immutable
    // receiver, which cannot call a mutating method. Evaluating the call as an
    // ordinary argument keeps the assertion macro on a plain Bool.
    private func check(_ condition: Bool, _ message: String = "") {
        #expect(condition, Comment(rawValue: message))
    }

    private func require<T>(_ value: T?, _ message: String = "") throws -> T {
        try #require(value, Comment(rawValue: message))
    }

    @Test func expiredBiasACKCannotChangeNewLease() throws {
        let owner = Owner()
        let first = try require(owner.value.begin(.bias, now: 0))
        check(owner.value.expire(first, now: PhotoExposureCadence.setterTimeout))
        check(owner.value.requiresRecovery)
        let second = try require(owner.value.begin(.bias, now: 2))
        check(!owner.value.acknowledge(first, now: 2.1))
        check(owner.value.biasPendingCount == 1)
        check(!owner.value.expire(first, now: 10))
        check(owner.value.biasPendingCount == 1)
        check(owner.value.acknowledge(second, now: 2.2))
        check(owner.value.biasPendingCount == 0)
        check(!owner.value.acknowledge(second, now: 2.3))
        check(owner.value.biasPendingCount == 0)
    }

    @Test func lateCustomACKCannotReleaseNewSetter() throws {
        let owner = Owner()
        let first = try require(owner.value.begin(.custom, now: 0))
        check(owner.value.expire(first, now: 2))
        let second = try require(owner.value.begin(.custom, now: 2))
        owner.value.stop()
        check(!owner.value.acknowledge(first, now: 2.1))
        check(owner.value.customPending)
        check(!owner.value.canDrain(capturing: false))
        check(owner.value.acknowledge(second, now: 2.2))
        check(owner.value.canDrain(capturing: false))
    }

    @Test(arguments: [PhotoExposureOperationOwnership.Kind.custom, .bias])
    func stoppedControllerEventuallySettlesExpiredSetter(_ kind: PhotoExposureOperationOwnership.Kind) throws {
        let owner = Owner()
        let token = try require(owner.value.begin(kind, now: 5))
        owner.value.stop()
        check(owner.value.begin(.custom, now: 5.1) == nil)
        check(owner.value.begin(.bias, now: 5.1) == nil)
        check(!owner.value.canDrain(capturing: false))
        check(!owner.value.expire(token, now: 5.1))
        check(owner.value.expire(token, now: 5 + PhotoExposureCadence.setterTimeout))
        check(owner.value.requiresRecovery)
        check(owner.value.canDrain(capturing: false))
        check(!owner.value.acknowledge(token, now: 10))
        check(owner.value.canDrain(capturing: false))
    }

    @Test func setterExpiryNeverInventsRAWTerminal() throws {
        let owner = Owner()
        let custom = try require(owner.value.begin(.custom, now: 0))
        let bias = try require(owner.value.begin(.bias, now: 0))
        owner.value.stop()
        check(owner.value.expire(custom, now: 2))
        check(!owner.value.canDrain(capturing: false))
        check(owner.value.expire(bias, now: 2))
        check(!owner.value.canDrain(capturing: true))
        check(owner.value.canDrain(capturing: false))
    }

    @Test func duplicateACKDoesNotMoveAppliedFreshness() throws {
        let owner = Owner()
        let token = try require(owner.value.begin(.custom, now: 0))
        check(owner.value.acknowledge(token, now: 1))
        check(!owner.value.acknowledge(token, now: 9))
        check(owner.value.meteringReady(now: 1.31, duration: 0.01))
    }

    @Test func expiredSetterCannotResumeMeteringEvenAfterTheFreshnessWindow() throws {
        let owner = Owner()
        let token = try require(owner.value.begin(.custom, now: 0))
        check(owner.value.expire(token, now: 2))
        check(!owner.value.acknowledge(token, now: 3))
        check(owner.value.requiresRecovery)
        check(!owner.value.meteringReady(now: 100, duration: 0.01))
    }

    @Test func unacknowledgedSetterCannotProvideFreshMetering() throws {
        let owner = Owner()
        _ = try require(owner.value.begin(.custom, now: 0))
        check(!owner.value.meteringReady(now: 100, duration: 0.01))
    }

    @Test func delayedACKRestartsMeterFreshnessWithoutDelayingUserIntent() throws {
        let owner = Owner()
        let token = try require(owner.value.begin(.custom, now: 0))
        check(owner.value.acknowledge(token, now: 1))
        check(!owner.value.meteringReady(now: 1.15, duration: 0.25))
        // User writes are gated only by live leases/stop, not the sensor clock.
        let userWrite = try require(owner.value.begin(.custom, now: 1.15))
        check(owner.value.acknowledge(userWrite, now: 1.2))
        check(!owner.value.meteringReady(now: 1.7, duration: 0.25))
        check(owner.value.meteringReady(now: 1.86, duration: 0.25))
    }

    @Test func biasAndNativeModeApplicationAlsoInvalidateOldMeterReadings() throws {
        let owner = Owner()
        owner.value.noteApplied(now: 2)
        check(!owner.value.meteringReady(now: 2.15, duration: 0.01))
        let bias = try require(owner.value.begin(.bias, now: 2.2))
        check(owner.value.acknowledge(bias, now: 3))
        check(!owner.value.meteringReady(now: 3.15, duration: 0.01))
        check(owner.value.meteringReady(now: 3.31, duration: 0.01))
        owner.value.noteMeteringRead(now: 3.31)
        check(!owner.value.meteringReady(now: 3.4, duration: 0.01))
    }

    @Test func oneLeasePerKindCannotBeOverwritten() throws {
        let owner = Owner()
        let custom = try require(owner.value.begin(.custom, now: 0))
        check(owner.value.begin(.custom, now: 0.1) == nil)
        let bias = try require(owner.value.begin(.bias, now: 0.1))
        check(owner.value.begin(.bias, now: 0.2) == nil)
        check(owner.value.acknowledge(custom, now: 0.3))
        check(owner.value.biasPendingCount == 1)
        check(owner.value.acknowledge(bias, now: 0.4))
    }
}
