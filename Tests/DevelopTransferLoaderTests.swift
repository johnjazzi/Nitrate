import Foundation
import Testing

@MainActor
@Suite("Develop transfer loader", .timeLimit(.minutes(1)))
struct DevelopTransferLoaderTests {
    private enum Failure: Error { case denied }

    private final class Provider {
        let progress = Progress(totalUnitCount: 1)
        var callback: (@Sendable (Result<Int?, Error>) -> Void)?

        func start(_ callback: @escaping @Sendable (Result<Int?, Error>) -> Void) -> Progress {
            self.callback = callback
            return progress
        }
    }

    private func waitForStart(_ provider: Provider) async throws {
        for _ in 0..<100 {
            if provider.callback != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure.denied
    }

    @Test func neverCallingBackTimesOutAndCancelsProgress() async throws {
        let provider = Provider()
        do {
            let _: Int? = try await DevelopTransferLoader.load(
                timeout: .milliseconds(10), start: provider.start)
            Issue.record("Expected timeout")
        } catch DevelopTransferLoader.TransferError.timedOut {
            #expect(provider.progress.isCancelled)
            #expect(DevelopTransferLoader.TransferError.timedOut.errorDescription != nil)
        }
    }

    @Test func cancellationReturnsPromptlyWithoutCallback() async throws {
        let provider = Provider()
        let task = Task {
            try await DevelopTransferLoader.load(timeout: .seconds(2), start: provider.start)
        }
        try await waitForStart(provider)
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(clock.now - cancelledAt < .seconds(1))
            #expect(provider.progress.isCancelled)
        }
        // Neither duplicate nor late callbacks may resume the continuation again.
        provider.callback?(.success(42))
        provider.callback?(.failure(Failure.denied))
    }

    @Test func successPublishesProgressAndIgnoresLaterResults() async throws {
        let provider = Provider()
        var published: Progress?
        let task = Task {
            try await DevelopTransferLoader.load(
                timeout: .seconds(2), onStart: { published = $0 }, start: provider.start)
        }
        try await waitForStart(provider)
        provider.callback?(.success(42))
        #expect(try await task.value == 42)
        #expect(published === provider.progress)
        provider.callback?(.success(99))
        provider.callback?(.failure(Failure.denied))
        #expect(!provider.progress.isCancelled)
    }

    @Test func synchronousNilAndSuccess() async throws {
        for expected in [nil, 7] as [Int?] {
            let progress = Progress(totalUnitCount: 1)
            let value: Int? = try await DevelopTransferLoader.load(timeout: .milliseconds(10)) { callback in
                callback(.success(expected))
                return progress
            }
            #expect(value == expected)
            // A completed transfer must not be cancelled by its old timeout.
            try await Task.sleep(for: .milliseconds(20))
            #expect(!progress.isCancelled)
        }
    }

    @Test func providerErrorIsPreserved() async throws {
        do {
            let _: Int? = try await DevelopTransferLoader.load { callback in
                callback(.failure(Failure.denied))
                return Progress(totalUnitCount: 1)
            }
            Issue.record("Expected provider error")
        } catch Failure.denied {
            // The provider error is not replaced by a timeout or cancellation.
        }
    }

    @Test func alreadyCancelledDoesNotLaunchProvider() async throws {
        var started = false
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let value: Int? = try await DevelopTransferLoader.load { _ in
                started = true
                return Progress(totalUnitCount: 1)
            }
            return value
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!started)
        }
    }

    @Test func cancellationBeforeProgressReturnsCancelsIt() async throws {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            let value: Int? = try await DevelopTransferLoader.load(timeout: .seconds(2)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return progress
            }
            return value
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(progress.isCancelled)
        }
    }

    @Test func callbackCancellationRaceSettlesOnce() async throws {
        for _ in 0..<20 {
            let provider = Provider()
            let task = Task {
                try await DevelopTransferLoader.load(timeout: .seconds(2), start: provider.start)
            }
            try await waitForStart(provider)
            let callback = try #require(provider.callback)
            let completion = Task.detached { callback(.success(1)) }
            task.cancel()
            do {
                #expect(try await task.value == 1)
            } catch is CancellationError {
                #expect(provider.progress.isCancelled)
            }
            await completion.value
        }
    }
}
