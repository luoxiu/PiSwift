import Foundation
import Synchronization

/// What a host timer is for (`SetTimer`). Upstream passes `{ background }`.
public struct TimerOptions: Sendable, Equatable {
    /// A timer that only frees memory, which the host may decline.
    public let background: Bool
    /// Creates timer options.
    public init(background: Bool) { self.background = background }
}

/// A host timer, given as `HarnessOptions.setTimer`: call `callback` once, about `delayMs` from now, and return a
/// function that disarms it. `background` timers only free memory, and a host may decline one by returning nil, for
/// example where a pending timer keeps the process from hibernating; the Harness then frees that memory at later
/// commits. Other timers pace or resume work and must be armed. A timer may fire early or late: callers check their
/// clock again.
///
/// Swift: the Session and the scheduler may hold an internal lock while they arm or disarm a timer, so the function must
/// return without calling back into the Session or Harness, and must not call `callback` before it returns.
public typealias SetTimer = @Sendable (_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64, _ options: TimerOptions)
    throws -> (@Sendable () -> Void)?

/// Longest delay `setTimeout` supports; a longer one fires early, and its caller arms again.
private let maxTimerDelay: Int64 = 2_147_483_647

/// The default `HarnessOptions.setTimer`, upstream `setTimeout`: a task that sleeps, then calls `callback` unless it was
/// disarmed. A Swift task never keeps the process alive, so a background timer is never declined (upstream unreferences
/// it, and declines it where timers cannot be unreferenced).
internal let nativeTimer: SetTimer = { callback, delayMs, _ in
    let task = Task {
        do { try await Task.sleep(for: .milliseconds(min(max(0, delayMs), maxTimerDelay))) } catch { return }
        if !Task.isCancelled { callback() }
    }
    return { task.cancel() }
}

/// Timers the Session and Harness arm through the host's `setTimer`.
internal struct Timers: Sendable {
    let arm: SetTimer
    let report: @Sendable (any Error) -> Void
    /// A timer that paces or resumes work. A host that declines it is reported, and the timer never fires.
    func foreground(_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64) -> @Sendable () -> Void {
        do {
            if let disarm = try arm(callback, delayMs, TimerOptions(background: false)) { return disarm }
            report(SessionError.message("HarnessOptions.setTimer declined a timer that paces work"))
        } catch {
            report(error)
        }
        return {}
    }
    /// A timer that only frees memory; nil when the host declines it.
    func background(_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64) -> (@Sendable () -> Void)? {
        do { return try arm(callback, delayMs, TimerOptions(background: true)) } catch {
            report(error)
            return nil
        }
    }
}

/// Wrap a host `setTimer`: a throw or a declined foreground timer is reported, and arms nothing.
internal func hostTimers(_ setTimer: SetTimer?, report: @escaping @Sendable (any Error) -> Void) -> Timers {
    Timers(arm: setTimer ?? nativeTimer, report: report)
}
