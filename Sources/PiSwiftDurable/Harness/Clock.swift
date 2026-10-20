import Foundation
import PiSwiftChord

/// Time is measured in epoch milliseconds: `now()` and a cancellable `sleep(until:)`, as `ProgressClock` declares them,
/// so a Harness clock also paces tool progress.
public protocol DurableClock: ProgressClock {}

/// A wall clock with Swift task cancellation during sleep.
public struct SystemDurableClock: DurableClock {
    /// Creates a wall clock backed by the system time source.
    public init() {}
    /// Returns the current system time in epoch milliseconds.
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Waits until the millisecond deadline or Swift task cancellation.
    public func sleep(until deadline: Int64) async throws {
        let delay = deadline - now()
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        try Task.checkCancellation()
    }
}
