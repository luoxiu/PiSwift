// Swift-only: the clocks upstream's in-memory adapter (`memory.ts`) and Chord's SQLite adapter
// (`telemetry-sqlite/index.ts`) read directly, `Date.now()`, `performance.now()`, and `setInterval`, at d9025a5f5.
// Upstream's tests replace those globals; Swift tests in this package pass a clock instead. Hosts get the system clock.

import Foundation

/// The clocks a recording adapter reads. Package access: only this package's adapters and tests take one.
package struct TelemetryClock: Sendable {
    /// Whole wall-clock milliseconds since the epoch, as `Date.now()` returns them.
    package var now: @Sendable () -> Double
    /// Monotonic milliseconds, as `performance.now()` returns them.
    package var monotonic: @Sendable () -> Double
    /// Calls `tick` every `intervalMs` milliseconds until the returned function cancels it, as `setInterval` with
    /// `unref()`: a pending tick keeps nothing alive.
    package var every: @Sendable (_ intervalMs: Int, _ tick: @escaping @Sendable () -> Void) -> @Sendable () -> Void

    package init(
        now: @escaping @Sendable () -> Double,
        monotonic: @escaping @Sendable () -> Double,
        every: @escaping @Sendable (_ intervalMs: Int, _ tick: @escaping @Sendable () -> Void) -> @Sendable () -> Void
    ) {
        self.now = now
        self.monotonic = monotonic
        self.every = every
    }

    /// `Date`, `ContinuousClock`, and a task that sleeps between ticks.
    package static let system = TelemetryClock(
        now: { (Date().timeIntervalSince1970 * 1000).rounded(.down) },
        monotonic: {
            let elapsed = ContinuousClock.now - monotonicOrigin
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        },
        every: { intervalMs, tick in
            let task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(intervalMs)) } catch { return }
                    tick()
                }
            }
            return { task.cancel() }
        }
    )
}

private let monotonicOrigin = ContinuousClock.now
