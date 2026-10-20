// Swift-only: stands in for upstream tests' `vi.spyOn(Date, "now")`, `vi.spyOn(performance, "now")`, and
// `vi.useFakeTimers()`, which replace globals the adapters read. Swift adapters in this package take a clock instead.

import Synchronization
import PiSwiftTelemetry

/// A wall clock the test sets, an optional manual monotonic clock, and intervals that fire as the test advances time.
package final class ManualTelemetryClock: Sendable {
    private struct Interval {
        let id: Int
        let period: Double
        var due: Double
        let tick: @Sendable () -> Void
    }

    private struct State {
        var now: Double
        var monotonic: Double?
        var timerTime = 0.0
        var intervals: [Interval] = []
        var nextId = 0
    }

    private let state: Mutex<State>

    /// A clock at wall time `now`. Without `monotonic`, the monotonic clock is the system's.
    package init(now: Double = 0, monotonic: Double? = nil) {
        state = Mutex(State(now: now, monotonic: monotonic))
    }

    /// The wall time `Date.now()` returns. Setting it fires nothing, as `vi.setSystemTime`.
    package var now: Double {
        get { state.withLock { $0.now } }
        set { state.withLock { $0.now = newValue } }
    }

    /// The monotonic time `performance.now()` returns, or nil for the system's.
    package var monotonic: Double? {
        get { state.withLock { $0.monotonic } }
        set { state.withLock { $0.monotonic = newValue } }
    }

    /// Intervals that are not cancelled.
    package var activeIntervals: Int { state.withLock { $0.intervals.count } }

    /// Advances the wall time and the timers by `milliseconds`, then fires every interval tick that came due, in time
    /// order, as `vi.advanceTimersByTimeAsync`. Ticks run outside the clock's lock.
    package func advance(by milliseconds: Double) {
        let ticks = state.withLock { state -> [@Sendable () -> Void] in
            state.now += milliseconds
            state.timerTime += milliseconds
            var due: [(time: Double, id: Int, tick: @Sendable () -> Void)] = []
            for index in state.intervals.indices {
                while state.intervals[index].due <= state.timerTime {
                    due.append((state.intervals[index].due, state.intervals[index].id, state.intervals[index].tick))
                    state.intervals[index].due += state.intervals[index].period
                }
            }
            return due.sorted { ($0.time, $0.id) < ($1.time, $1.id) }.map(\.tick)
        }
        for tick in ticks { tick() }
    }

    /// The adapter's view of this clock.
    package var clock: TelemetryClock {
        TelemetryClock(
            now: { [self] in now },
            monotonic: { [self] in monotonic ?? TelemetryClock.system.monotonic() },
            every: { [self] intervalMs, tick in
                let id = state.withLock { state in
                    state.nextId += 1
                    state.intervals.append(Interval(
                        id: state.nextId, period: Double(intervalMs), due: state.timerTime + Double(intervalMs), tick: tick))
                    return state.nextId
                }
                return { [self] in state.withLock { $0.intervals.removeAll { $0.id == id } } }
            })
    }
}
