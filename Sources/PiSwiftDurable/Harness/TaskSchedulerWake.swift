import Foundation
import PiSwiftChord

/// When a Session next needs a running process (`Harness.wake()`). `active`: some task can run now or is running, or a
/// reconcile pass such as open's recovery has not landed yet, so a process that dies must be woken again soon, for
/// example by a recovery alarm. `at`: the earliest sleep not yet due,
/// when there is one. Neither: nothing needs a process until new work is submitted. Tasks blocked on a missing or
/// unmigratable definition, `completing` tasks, and waits on live tasks do not count; the work they wait for does.
public struct Wake: Sendable, Equatable {
    /// Some task can run now or is running.
    public let active: Bool
    /// The earliest sleep not yet due, in milliseconds on the Harness clock.
    public let at: Int64?
    /// Creates a wake.
    public init(active: Bool, at: Int64? = nil) { self.active = active; self.at = at }
}

/// Sleeping tasks, timers, and wakeups (spec §5.6).
extension TaskScheduler {
    /// When the Session next needs a process: `active` while some task can run now or is running, `at` for the earliest
    /// sleep not yet due. Synchronous, from memory; a task whose chain is not loaded yet counts as it would alone.
    func wake() -> Wake {
        let now = now(), limit = restartLimit()
        let found = state.withLock { state -> (active: Bool, at: Int64?, unblocked: [TaskRecord]) in
            // A reconcile pass with work to do is work too: it finalizes held outcomes and marks cascades, at open as
            // recovery. A process that dies before it lands must be woken again. A pass with nothing to do is not.
            var active = !state.invocations.isEmpty || state.reconcilingWork > 0 || state.reconcileWork
            var at: Int64?
            // The records to check against the registry, outside the lock: `fit` reads the scheduler's state.
            var unblocked: [TaskRecord] = []
            let live = state.live
            for record in live.values {
                switch record.state {
                case .completing: continue
                case .waiting(_, let on, _, _) where !record.abortRequested && on.contains(where: { live[$0] != nil }): continue
                case .sleeping(_, let until, _) where !record.abortRequested && until > now:
                    at = min(at ?? until, until)
                    continue
                default: break
                }
                if active { continue }
                if record.parked(limit) { continue }
                // An abort invocation waits for the live work below it, which counts itself.
                if record.abortRequested && !state.waitingOn(record, first: true).isEmpty { continue }
                // A task no definition can take waits for a registry change, except an abort-marked one, which is orphaned.
                if !record.abortRequested || record.abortReason != nil { unblocked.append(record); continue }
                active = true
            }
            return (active, at, unblocked)
        }
        var active = found.active
        if !active && !found.unblocked.isEmpty {
            let snapshot = registry.snapshot()
            active = found.unblocked.contains { fit($0, definition: snapshot.task(name: $0.kind)).reason == nil }
        }
        return Wake(active: active, at: found.at)
    }

    /// Recompute the wake off the Session line: arm the built-in timer, or tell `onWake` of a change. Upstream runs it in a
    /// microtask; here one task delivers at a time, and a request made meanwhile runs one more round.
    func scheduleWake() {
        let start = state.withLock { state -> Bool in
            guard !state.closing else { return false }
            state.wakeDirty = true
            if state.wakeScheduled { return false }
            state.wakeScheduled = true
            return true
        }
        if start { Task { [weak self] in self?.deliverWakes() } }
    }
    private func deliverWakes() {
        while state.withLock({ state -> Bool in
            guard state.wakeDirty, !state.closing else { state.wakeScheduled = false; return false }
            state.wakeDirty = false
            return true
        }) {
            let wake = wake()
            guard let onWake else {
                armTimer(state.withLock { $0.enabled } ? wake.at : nil)
                continue
            }
            if state.withLock({ $0.lastWake == wake }) { continue }
            do {
                try onWake(wake)
                // Only a delivered wake counts: after a throw, the next change or kick offers it again.
                state.withLock { $0.lastWake = wake }
            } catch { report(error, ReportInfo(source: .wake)) }
        }
    }

    /// Keep the timer for the earliest sleep. Unlike the context expiry timer, it is a foreground timer: a process with a
    /// sleeping task has work left, such as a retry backoff. Rechecks the clock when it fires, so a wake before `until`
    /// only arms it again.
    private func armTimer(_ at: Int64?) {
        let (previous, id) = state.withLock { state -> ((@Sendable () -> Void)?, Int?) in
            if let timer = state.timer, timer.at == at { return (nil, nil) }
            let previous = state.timer?.disarm
            state.timer = nil
            guard let at, !state.closing else { return (previous, nil) }
            state.nextTimer += 1
            // Held before arming, so a timer that fires at once finds itself.
            state.timer = ArmedTimer(at: at, id: state.nextTimer, disarm: {})
            return (previous, state.nextTimer)
        }
        previous?()
        guard let id, let at else { return }
        let disarm = timers.foreground({ [weak self] in self?.timerFired(id) }, at - now())
        let kept = state.withLock { state -> Bool in
            guard state.timer?.id == id else { return false }
            state.timer = ArmedTimer(at: at, id: id, disarm: disarm)
            return true
        }
        if !kept { disarm() }
    }
    private func timerFired(_ id: Int) {
        let current = state.withLock { state -> Bool in
            guard state.timer?.id == id else { return false }
            state.timer = nil
            return true
        }
        guard current else { return }
        let now = now()
        state.withLock { $0.wakeDue(now: now) }
        kick()
    }

    /// Run `settleIdle()` when the earliest idle context expires, on a background timer, which never keeps the process
    /// alive. Where the host declines it, none is kept: task changes alone check expiry.
    func scheduleExpiry() {
        let retention = settings().contextRetentionMs, now = now()
        let (previous, armed) = state.withLock { state -> ((@Sendable () -> Void)?, (at: Int64, id: Int)?) in
            let at = state.contexts.values.compactMap { $0.idleSince.map { $0 + retention } }.min()
            if let expiry = state.expiry, expiry.at == at { return (nil, nil) }
            let previous = state.expiry?.disarm
            state.expiry = nil
            guard let at, !state.closing else { return (previous, nil) }
            state.nextTimer += 1
            // Held before arming, so a timer that fires at once finds itself and a concurrent call sees it.
            state.expiry = ArmedTimer(at: at, id: state.nextTimer, disarm: {})
            return (previous, (at, state.nextTimer))
        }
        previous?()
        guard let armed else { return }
        let disarm = timers.background({ [weak self] in self?.expiryFired(armed.id) }, armed.at - now)
        let kept = state.withLock { state -> Bool in
            guard state.expiry?.id == armed.id else { return false }
            state.expiry = disarm.map { ArmedTimer(at: armed.at, id: armed.id, disarm: $0) }
            return true
        }
        if !kept { disarm?() }
    }
    private func expiryFired(_ id: Int) {
        let current = state.withLock { state -> Bool in
            guard state.expiry?.id == id else { return false }
            state.expiry = nil
            return true
        }
        if current { settleIdle() }
    }
}
