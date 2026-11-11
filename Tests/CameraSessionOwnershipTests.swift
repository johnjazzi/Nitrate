import Testing

struct CameraSessionOwnershipTests {
    /// Swift Testing rewrites an expectation's argument into a closure over an
    /// immutable receiver, which cannot call a mutating method. These helpers
    /// evaluate the call first and assert on a plain Bool.
    private func check(_ condition: Bool, _ message: String = "") {
        #expect(condition, Comment(rawValue: message))
    }

    private func require<T>(_ value: T?, _ message: String = "") throws -> T {
        try #require(value, Comment(rawValue: message))
    }

    @Test func oldIdleDeliveryCannotResurrectAStoppedLifecycle() {
        var delivery = CameraSessionDeliveryOwnership()
        delivery.activate(1)
        let old = CameraSessionDeliveryContext(lifecycle: 1, controller: 1)
        check(delivery.accepts(old))
        delivery.deactivate()
        check(!delivery.accepts(old))
        delivery.activate(3)
        check(!delivery.accepts(old))
        check(delivery.accepts(.init(lifecycle: 3, controller: 2)))
        check(!delivery.accepts(.init(lifecycle: 3, controller: 1)))
    }

    @Test func cancelWithMissingVideoACKRequiresBoundaryBeforeNextWriter() throws {
        for kind in [CameraVideoStartupOwnership.Kind.bias, .exposure] {
            var owner = CameraVideoStartupOwnership()
            let a = try require(owner.begin(kind))
            // Cancel changes intent, not ownership. Deadline is still live.
            check(owner.active == a)
            check(owner.expire(a))
            check(owner.requiresRecovery)
            check(owner.begin(kind) == nil)
            check(!owner.finish(a))
            owner.didResetStoppedSession()
            let b = try require(owner.begin(kind))
            check(!owner.finish(a), "late and duplicate ACKs cannot settle B")
            check(owner.active == b)
            check(!owner.expire(a), "A's old deadline cannot expire B")
            check(owner.finish(b))
            check(!owner.finish(b))
        }
    }

    @Test func oldPhotoCompletionCannotCancelNewCaptureWatchdog() throws {
        var captures = CameraPhotoResultOwnership()
        let a = captures.begin()
        captures.invalidate()
        let b = captures.begin()
        check(!captures.finish(a))
        check(captures.owns(b))
        check(captures.finish(b))
        check(!captures.finish(b))
    }
}
