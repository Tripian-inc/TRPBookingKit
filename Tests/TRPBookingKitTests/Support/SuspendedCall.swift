import Foundation

/// Holds a mocked call open until the test resumes it, so the test can act while the caller is suspended.
final class SuspendedCall: @unchecked Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        (released, releasedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// Called from inside the mock; returns once `resume()` is called.
    func suspend() async {
        enteredContinuation.yield()
        for await _ in released { return }
    }

    /// Returns once the mocked call has started and is suspended.
    func waitUntilEntered() async {
        for await _ in entered { return }
    }

    func resume() {
        releasedContinuation.yield()
    }
}
