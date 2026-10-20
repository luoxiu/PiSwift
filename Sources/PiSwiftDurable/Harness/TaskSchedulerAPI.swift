import Foundation
import PiSwiftChord

extension TaskScheduler {
    /// Commit the abort mark, or settle a task that no registered definition can take as `orphaned` when nothing it owns
    /// is live, then join the run invocation seen on the line. A request replaces a `restart` mark, so a task abandoned
    /// after a restart that waits for its definition is orphaned; with `keepRestart`, as for an owner's own cleanup, such
    /// a task keeps its mark and waits on.
    func abort(id: TaskID, context: ChordContext, keepRestart: Bool = false) async throws -> TaskAbortResult {
        let marked: (TaskAbortResult, TaskInvocation?) = try await session.commit({ tx in
            guard let record = try await tx.task(id) else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            if record.state.status == "terminal" { return (.terminal, nil) }
            let invocation = state.withLock { $0.invocations[id] }
            // A restart-marked task has no run invocation; it only waits for its abort.
            if keepRestart && record.abortReason == .restart { return (.marked, nil) }
            if invocation == nil && record.state.status != "completing" {
                try await loadScopes()
                if !state.withLock({ $0.hasOwnedLive(id) }), let reason = fit(record, definition: registry.snapshot().task(name: record.kind)).reason {
                    try await terminate(tx, record: record, outcome: .orphaned(reason: reason)); return (.marked, nil)
                }
            }
            if !record.abortRequested || record.abortReason != nil { try tx.setTask(record.withAbortMark()) }
            return (.marked, invocation?.abort == false ? invocation : nil)
        }, context: context)
        // Upstream abortTask does not enable scheduling (harness.ts:275-277, scheduler.ts:282-304).
        // The commit listener signalled the run; join it. A run that ignores its signal can outlive a failed Session,
        // which ends the wait instead.
        if let invocation = marked.1 {
            let work = Task { [session] in try await session.untilFailed { try await invocation.done.value() } }
            try await awaitWithContext(work, context)
        }
        return marked.0
    }
    func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        let promise: HarnessPromise<SettledTask> = try await session.readOnLine {
            if closing { throw closedError(session) }
            if current(id) != nil {
                return try state.withLock { state in
                    if state.closing { throw closedError(session) }
                    return try taskWaiters.add(id, context: context)
                }
            }
            guard let record = try await storage.task(id, context: context) else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            let promise = HarnessPromise<SettledTask>()
            promise.finish(.success(SettledTask(record: record))); return promise
        }
        return try await promise.value()
    }
    func waitForIdle(conversationId: ConversationID?, context: ChordContext) async throws {
        let promise: HarnessPromise<Void>? = try await session.readOnLine {
            if closing { throw closedError(session) }
            try context.abortSignal?.throwIfAborted()
            if idle(conversationId) { return nil }
            scheduleReconcile()
            return try state.withLock { state in
                if state.closing { throw closedError(session) }
                return try idleWaiters.add(conversationId, context: context)
            }
        }
        try await promise?.value()
    }
    func abortConversation(id: ConversationID, background: Bool, context: ChordContext) async throws {
        let reached: [TaskID] = try await session.commit({ tx in
            try await loadScopes()
            let queued = try await loadQueuedScopes()
            let found = state.withLock { state -> [TaskRecord] in
                var found: [TaskID: TaskRecord] = [:]
                state.walkDown(.conversation(id), crossBackground: background) { _, node, live in
                    if let live, !node.background || background { found[live.id] = live }
                    return true
                }
                return state.ordered(found.keys).compactMap { found[$0] }
            }
            var reached: [TaskID] = []
            for record in found {
                reached.append(record.id)
                if !record.abortRequested || record.abortReason != nil { try tx.setTask(record.withAbortMark()) }
            }
            for queuedID in queued where inScope(.conversation(queuedID), conversationId: id, background: background) == true { try await withdrawInputs(tx, queuedID) }
            return reached
        }, context: context)
        resume()
        if background { for id in reached { _ = try await waitForTask(id: id, context: context) } }
        try await waitForIdle(conversationId: id, context: context)
    }
    /// Caller runs this read on the Session line. Migration code is not called.
    func inspect(snapshot: RegistrySnapshot) async throws -> (scheduling: SchedulingState, tasks: [TaskInspection]) {
        try await loadScopes()
        let tasks = records().map { record -> TaskInspection in
            let derived: TaskInspectionState
            if state.withLock({ $0.invocations[record.id] != nil }) { derived = .running }
            else if record.state.status == "completing" { derived = .completing }
            else {
                let on = state.withLock { $0.waitingOn(record) }
                if !on.isEmpty { derived = .waiting(on: on) }
                else {
                    let definition = snapshot.task(name: record.kind), fit = fit(record, definition: definition)
                    if let reason = fit.reason { derived = .blocked(reason: TaskBlockedReason(rawValue: reason)!, error: fit.error) }
                    else if fit.migrates && definition?.migrate == nil {
                        derived = .blocked(reason: .migrationFailed, error: SessionError.message("Task \(record.kind) version \(definition!.version) has no migration from \(record.version)"))
                    } else { derived = .ready(migrates: fit.migrates) }
                }
            }
            return TaskInspection(record: record, state: derived)
        }
        return (state.withLock { $0.closing ? .closing : $0.enabled ? .running : .paused }, tasks)
    }
    func gated<T>(_ invocation: TaskInvocation, context: ChordContext,
                  change: (Transaction, TaskRecord) async throws -> T) async throws -> T {
        try invocation.check()
        return try await session.commitWith({ tx in
            try invocation.check()
            if closing { throw closedError(session) }
            guard let found = current(invocation.taskId) else { throw SessionError.message("Task \(invocation.taskId.rawValue) is terminal") }
            guard found.state.status == "running" else { throw SessionError.message("Task \(invocation.taskId.rawValue) is \(found.state.status)") }
            if !invocation.abort && found.abortRequested { throw SessionError.message("Task \(invocation.taskId.rawValue) has a durable abort mark") }
            let result = try await change(tx, found)
            if invocation.abort {
                let overlay = try TaskOverlay(tx)
                for record in overlay.tasks.values where tx.createdTaskIDs().contains(record.id) {
                    try await loadChain(record.parent, overlay: overlay)
                    if above(record.parent, overlay: overlay).contains(where: { if case .task(let owner, _) = $0 { return owner == invocation.taskId }; return false }) {
                        throw SessionError.message("Abort handler of task \(invocation.taskId.rawValue) cannot create owned children")
                    }
                }
            }
            return result
        }, context: context, scope: .init(conversationId: invocation.conversationId, taskId: invocation.taskId))
    }
    func commitState(_ tx: Transaction, invocation: TaskInvocation, current: TaskRecord, next: TaskState) async throws {
        if case .waiting(_, let on, let policy, _) = next {
            try await validateWait(tx, invocation: invocation, current: current, on: on, policy: policy)
        }
        switch next {
        case .terminal(let outcome, _):
            guard outcome.status != "faulted", outcome.status != "orphaned" else {
                throw SessionError.message("Only the scheduler can commit \(outcome.status) outcomes")
            }
            try await terminate(tx, record: current, outcome: outcome)
        case .running, .waiting: try tx.setTask(current.replacing(state: next))
        default: throw SessionError.message("A task handler can commit only running, waiting, or terminal state")
        }
    }
    /// A wait names existing tasks, and `failFast` only tasks the waiter owns. It may not close a cycle in the wait-for
    /// graph, whose edges run from each task to what it waits on and to its live ordinary owned work (spec §5.5); waiting
    /// on itself or on an owner holding it are the shortest such cycles. An abort handler cannot wait.
    ///
    /// Invariant: the wait-for graph is acyclic. Only a wait adds an edge between existing tasks, as a new task has only
    /// incoming edges, so checking each wait maintains it.
    private func validateWait(_ tx: Transaction, invocation: TaskInvocation, current: TaskRecord, on: [TaskID],
                              policy: JoinPolicy) async throws {
        if invocation.abort { throw SessionError.message("Abort handler of task \(current.id.rawValue) cannot wait") }
        var overlay = try TaskOverlay(tx)
        var targets: [TaskID] = []
        for id in on {
            let record: TaskRecord?
            if let found = overlay.tasks[id] ?? self.current(id) { record = found } else { record = try await storage.task(id, context: context) }
            guard let record else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            if policy == .failFast && record.owner != current.id { throw SessionError.message("Task \(current.id.rawValue) can wait failFast only on tasks it owns; \(id.rawValue) is not one") }
            // A live child already holds the waiter (task-owned tasks are never background): waiting on it adds no edge. A
            // terminal task has no edges.
            if record.state.status != "terminal" && record.owner != current.id { targets.append(id) }
        }
        if targets.isEmpty { return }
        // Owned work is found by walks down, which need the chains of every live task loaded.
        try await loadScopes()
        if let cycle = state.withLock({ $0.waitCycle(current.id, targets, overlay: &overlay) }) {
            let path = ([current.id] + cycle).map { String($0.rawValue) }.joined(separator: " -> ")
            throw SessionError.message("Task \(current.id.rawValue) cannot wait on \(cycle[0].rawValue): \(path) is a wait cycle")
        }
    }
    func settleIdle() {
        for id in idleWaiters.keys { if idle(id) { idleWaiters.resolve(id, value: ()) } }
        let now = now(), retention = settings().contextRetentionMs
        let ids = state.withLock { Array($0.contexts.keys) }
        for id in ids {
            let idle = idle(id)
            state.withLock { state in
                guard var kept = state.contexts[id] else { return }
                if let since = kept.idleSince, now - since >= retention { state.contexts.removeValue(forKey: id) }
                else if !idle { kept.idleSince = nil; state.contexts[id] = kept }
                else if retention > 0 { kept.idleSince = kept.idleSince ?? now; state.contexts[id] = kept }
                else { state.contexts.removeValue(forKey: id) }
            }
        }
        scheduleExpiry()
    }
    private func scheduleExpiry() {
        let retention = settings().contextRetentionMs, now = now()
        state.withLock { state in
            let deadline = state.contexts.values.compactMap { $0.idleSince.map { $0 + retention } }.min()
            if state.expiryAt == deadline { return }
            state.expiry?.cancel(); state.expiry = nil; state.expiryAt = nil
            guard let deadline, !state.closing else { return }
            state.expiryAt = deadline
            let id = UUID(); state.expiryID = id
            state.expiry = Task { [weak self, clock] in
                do { try await clock.sleep(until: now + min(max(0, deadline - now), 2_147_483_647)) }
                catch { return }
                guard let self else { return }
                let valid = self.state.withLock { state -> Bool in
                    guard state.expiryID == id, !state.closing else { return false }
                    state.expiry = nil; state.expiryAt = nil; return true
                }
                if valid { self.settleIdle() }
            }
        }
    }
    func readContext(_ invocation: TaskInvocation, id: ConversationID, at: EntryID?, context: ChordContext) async throws -> ContextView {
        try invocation.check()
        let previous = state.withLock { $0.contexts[id]?.range }
        let result = try await readContextFrom(session: session, storage: storage, id: id, context: context, at: at, previous: previous)
        if let range = result.range {
            let idle = idle(id), retention = settings().contextRetentionMs, now = now()
            state.withLock { state in
                guard !state.closing, !invocation.state.withLock({ $0.ended }), state.contexts[id].map({ $0.range.bounds.tail <= range.bounds.tail }) ?? true else { return }
                if !idle { state.contexts[id] = KeptContext(range: range, idleSince: nil) }
                else if retention > 0 { state.contexts[id] = KeptContext(range: range, idleSince: state.contexts[id]?.idleSince ?? now) }
            }
            scheduleExpiry()
        }
        return result.view
    }
}
