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
/// commits. Other timers pace or resume work: one the host throws on or declines is armed with the default timer. A
/// timer should not fire early; callers check their clock again when it fires.
///
/// Swift: the Session and the scheduler may hold an internal lock while they arm or disarm a timer, so the function must
/// return without calling back into the Session or Harness, and must not call `callback` before it returns.
public typealias SetTimer = @Sendable (_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64, _ options: TimerOptions)
    throws -> (@Sendable () -> Void)?

/// Longest delay `setTimeout` supports; a longer one is waited for in several steps.
private let maxTimerDelay: Int64 = 2_147_483_647

/// The default `HarnessOptions.setTimer`, upstream `setTimeout`: a task that sleeps, waiting out delays beyond
/// `setTimeout`'s limit in steps, then calls `callback` unless it was disarmed. A Swift task never keeps the process alive,
/// so a background timer is never declined (upstream unreferences it, and declines it in Cloudflare Workers and where
/// timers cannot be unreferenced).
internal let nativeTimer: SetTimer = { callback, delayMs, _ in
    let task = Task {
        var remaining = max(0, delayMs)
        repeat {
            let step = min(remaining, maxTimerDelay)
            do { try await Task.sleep(for: .milliseconds(step)) } catch { return }
            remaining -= step
        } while remaining > 0
        if !Task.isCancelled { callback() }
    }
    return { task.cancel() }
}

/// Timers the Session and Harness arm through the host's `setTimer`.
internal final class Timers: Sendable {
    let arm: SetTimer
    let report: @Sendable (any Error) -> Void
    private let reported = Mutex(false)
    init(arm: @escaping SetTimer, report: @escaping @Sendable (any Error) -> Void) { self.arm = arm; self.report = report }
    private func fallBack(_ error: any Error) {
        if reported.withLock({ value in defer { value = true }; return value }) { return }
        report(error)
    }
    /// A timer that paces or resumes work; when the host throws or declines it, the default timer arms it instead.
    func foreground(_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64) -> @Sendable () -> Void {
        do {
            if let disarm = try arm(callback, delayMs, TimerOptions(background: false)) { return disarm }
            fallBack(SessionError.message("HarnessOptions.setTimer declined a timer that paces work; using setTimeout"))
        } catch {
            fallBack(error)
        }
        // The default timer arms every timer.
        return try! nativeTimer(callback, delayMs, TimerOptions(background: false))!
    }
    /// A timer that only frees memory; nil when the host declines it.
    func background(_ callback: @escaping @Sendable () -> Void, _ delayMs: Int64) -> (@Sendable () -> Void)? {
        do { return try arm(callback, delayMs, TimerOptions(background: true)) } catch {
            report(error)
            return nil
        }
    }
}

/// Wrap a host `setTimer`. A foreground timer must fire, or work stalls: one the host throws on or declines is armed with
/// the default timer, and the first such failure is reported. A background one the host throws on is reported and
/// declined.
internal func hostTimers(_ setTimer: SetTimer?, report: @escaping @Sendable (any Error) -> Void) -> Timers {
    Timers(arm: setTimer ?? nativeTimer, report: report)
}
