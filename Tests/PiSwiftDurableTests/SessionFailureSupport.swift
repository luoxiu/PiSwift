import Testing
@testable import PiSwiftDurable

/// A storage failure injected by a test.
struct DiskGone: Error, Equatable, CustomStringConvertible {
    var description: String { "disk gone" }
}

/// Whether `error` is `SessionFailed` caused by `cause`.
func isSessionFailed<Cause: Error & Equatable>(_ error: any Error, cause: Cause) -> Bool {
    (error as? SessionFailed)?.cause as? Cause == cause
}

/// Whether the Session ended `failed` with `cause`.
func endedFailed<Cause: Error & Equatable>(_ end: SessionEnd, _ cause: Cause) -> Bool {
    if case .failed(let error) = end { return error as? Cause == cause }
    return false
}

/// Whether the Session ended by `close()`.
func endedClosed(_ end: SessionEnd) -> Bool {
    if case .closed = end { return true }
    return false
}

/// Whether a watch ended `sessionFailed` with `cause`.
func watchFailed<Cause: Error & Equatable>(_ end: WatchEnd, _ cause: Cause) -> Bool {
    if case .sessionFailed(let error) = end { return error as? Cause == cause }
    return false
}

/// Expects `body` to throw `SessionFailed` caused by `cause`.
func expectSessionFailed<Cause: Error & Equatable>(
    cause: Cause, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected SessionFailed", sourceLocation: sourceLocation)
    } catch {
        #expect(isSessionFailed(error, cause: cause), "Expected SessionFailed(\(cause)); got \(error)", sourceLocation: sourceLocation)
    }
}

/// A failure with a message, injected by a test where any error serves.
struct TestFailure: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
