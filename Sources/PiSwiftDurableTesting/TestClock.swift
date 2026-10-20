import Synchronization
import PiSwiftDurable

/// A manually advanced clock with host timers, for deterministic sleep and retry tests: pass `now` as
/// `HarnessOptions.now` and `setTimer` as `HarnessOptions.setTimer`, in place of upstream's mutable clock and fake timers.
/// Timers fire synchronously, in deadline order, when `advance(by:)` reaches their deadline.
public final class TestClock: Sendable {
    private struct Timer: Sendable {
        let deadline: Int64
        let background: Bool
        let callback: @Sendable () -> Void
    }
    private struct State: Sendable {
        var now: Int64
        var nextID = 0
        var timers: [Int: Timer] = [:]
    }
    private let state: Mutex<State>
    /// Creates a manual clock at the supplied millisecond time.
    public init(now: Int64 = 0) { state = Mutex(State(now: now)) }
    /// The current manually controlled time in milliseconds.
    public func now() -> Int64 { state.withLock { $0.now } }
    /// `now()` as a function, for `HarnessOptions.now`.
    public var nowFunction: @Sendable () -> Int64 { { [self] in now() } }
    /// Armed timers that pace or resume work, such as a sleeping task's or a progress throttle's, not yet fired or
    /// disarmed.
    public var pendingTimerCount: Int { state.withLock { $0.timers.values.filter { !$0.background }.count } }
    /// Armed background timers, which only free memory, not yet fired or disarmed.
    public var pendingBackgroundTimerCount: Int { state.withLock { $0.timers.values.filter(\.background).count } }
    /// Moves the clock forward and fires the timers whose deadline it reached, also those they arm meanwhile.
    public func advance(by milliseconds: Int64) {
        precondition(milliseconds >= 0)
        state.withLock { $0.now += milliseconds }
        while let timer = state.withLock({ state -> Timer? in
            guard let next = state.timers.filter({ $0.value.deadline <= state.now })
                .min(by: { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }) else { return nil }
            state.timers.removeValue(forKey: next.key)
            return next.value
        }) { timer.callback() }
    }
    /// A host `setTimer` on this clock: a timer fires when `advance(by:)` reaches `now() + delayMs`.
    public var setTimer: SetTimer {
        { [self] callback, delayMs, options in
            let id = state.withLock { state in
                state.nextID += 1
                let (deadline, overflow) = state.now.addingReportingOverflow(max(0, delayMs))
                state.timers[state.nextID] = Timer(deadline: overflow ? .max : deadline, background: options.background,
                                                   callback: callback)
                return state.nextID
            }
            return { [self] in _ = state.withLock { $0.timers.removeValue(forKey: id) } }
        }
    }
}
