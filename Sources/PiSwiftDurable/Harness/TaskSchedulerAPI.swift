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
    /// Run a task parked by the restart limit again: clears its restart count and enables scheduling. Does nothing for a
    /// task that is not parked; throws for an unknown one.
    func retry(id: TaskID, context: ChordContext) async throws {
        try await session.commit({ tx in
            guard let current = try await tx.task(id) else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            if !current.parked(restartLimit()) { return }
            try tx.setTask(current.progressed())
        }, context: context)
        resume()
    }
    /// Why a live task cannot run here, if it cannot: its definition (missing, too old, failed migration) or the restart
    /// limit. A running task, an abort-requested one, and one holding its outcome are never blocked.
    func blockedReason(_ record: BlockedSubject) -> TaskBlockedReason? {
        let status = record.status
        if status == "running" || status == "completing" || status == "terminal" { return nil }
        // An abort request runs its handler or orphans the task; a `restart` mark waits for the definition, blocked.
        if record.abortRequested && record.abortReason == nil { return nil }
        if parked(abortRequested: record.abortRequested, restarts: record.restarts) { return .restartLimit }
        let definition = registry.snapshot().task(name: record.kind)
        let fit = fit(id: record.id, version: record.version, definition: definition)
        if let reason = fit.reason { return TaskBlockedReason(rawValue: reason) }
        return fit.migrates && definition?.migrate == nil ? .migrationFailed : nil
    }
    /// Call `listener` when blocked reasons may have changed without a commit: a registry change or a failed migration.
    func subscribeBlocked(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.blockedListeners[id] = listener }
        return { [weak self] in _ = self?.state.withLock { $0.blockedListeners.removeValue(forKey: id) } }
    }
    /// Make parked tasks that a raised `settings.restartLimit` no longer parks candidates again, and tell the graph.
    func unparkRaised(_ limit: Double) {
        let unparked = state.withLock { state -> Bool in
            var unparked = false
            for id in state.parkedTasks {
                let record = state.live[id]
                if let record, record.parked(limit) { continue }
                state.parkedTasks.remove(id)
                guard record != nil else { continue }
                state.runnable.insert(id)
                unparked = true
            }
            return unparked
        }
        if unparked { notifyBlocked() }
    }
    func notifyBlocked() {
        for listener in state.withLock({ Array($0.blockedListeners.values) }) { listener() }
    }
    /// `settings.restartLimit`.
    func restartLimit() -> Double { settings().restartLimit }
    /// A task cut off `restartLimit` times in a row; an abort mark still runs its abort handler.
    func parked(abortRequested: Bool, restarts: Int?) -> Bool {
        guard let restarts else { return false }
        return !abortRequested && Double(restarts) >= restartLimit()
    }
    /// The report info of a task's failure, with the extension that installed its definition: the code that failed is
    /// that extension's. Built-in tasks have none.
    func taskInfo(taskId: TaskID, kind: String, conversationId: ConversationID, faulted: Bool? = nil,
                  blocked: TaskBlockedReason? = nil) -> ReportInfo {
        let snapshot = registry.snapshot()
        let installer = snapshot.task(name: kind).flatMap { installerOf(snapshot, $0) }
        return ReportInfo(source: .task, taskId: taskId, taskKind: kind, conversationId: conversationId,
                          extension: installer, faulted: faulted, blocked: blocked)
    }
    func taskInfo(_ invocation: TaskInvocation, faulted: Bool? = nil) -> ReportInfo {
        taskInfo(taskId: invocation.taskId, kind: invocation.kind, conversationId: invocation.conversationId, faulted: faulted)
    }
    /// The info of a report a task's runtime makes: the task's own failure names the task's extension; any other names
    /// whose code failed, if anyone's.
    func reportInfo(_ invocation: TaskInvocation, from: ReportFrom) -> ReportInfo {
        switch from {
        case .task: taskInfo(invocation)
        case .extension(let name):
            ReportInfo(source: .extension, taskId: invocation.taskId, taskKind: invocation.kind,
                       conversationId: invocation.conversationId, extension: name)
        case .host:
            ReportInfo(source: .host, taskId: invocation.taskId, taskKind: invocation.kind, conversationId: invocation.conversationId)
        }
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
                else if record.notDue(now()), case .sleeping(_, let until, _) = record.state { derived = .sleeping(until: until) }
                else if parked(abortRequested: record.abortRequested, restarts: record.restarts) { derived = .blocked(reason: .restartLimit) }
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
        if case .sleeping(_, let until, _) = next { try validateSleep(invocation, task: current.id, until: until) }
        switch next {
        case .terminal(let outcome, _):
            guard outcome.status != "faulted", outcome.status != "orphaned" else {
                throw SessionError.message("Only the scheduler can commit \(outcome.status) outcomes")
            }
            try await terminate(tx, record: current.progressed(), outcome: outcome)
        // A state the task committed that differs from its current one is progress: its restart count starts over. The
        // same checkpoint committed again, for example as intent before an effect, is not.
        case .running, .waiting, .sleeping:
            let same = try jsonStructurallyEqual(JSONValue(encoding: current.state), JSONValue(encoding: next))
            try tx.setTask((same ? current : current.progressed()).replacing(state: next))
        default: throw SessionError.message("A task handler can commit only running, waiting, sleeping, or terminal state")
        }
    }
    /// A sleep's `until` is a time on the Harness clock; an abort handler cannot sleep.
    private func validateSleep(_ invocation: TaskInvocation, task: TaskID, until: Int64) throws {
        if invocation.abort { throw SessionError.message("Abort handler of task \(task.rawValue) cannot sleep") }
        if until < 0 { throw SessionError.message("Task \(task.rawValue) cannot sleep until \(until): not a time in milliseconds") }
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

/// What `blockedReason()` reads of a task: the task graph keeps only this of each record.
internal struct BlockedSubject: Sendable, Equatable {
    let id: TaskID
    let kind: String
    let version: Double
    let abortRequested: Bool
    let abortReason: TaskAbortReason?
    let restarts: Int?
    let status: String
    /// The part of `record` `blockedReason()` reads.
    init(_ record: TaskRecord) {
        id = record.id; kind = record.kind; version = record.version; abortRequested = record.abortRequested
        abortReason = record.abortReason; restarts = record.restarts; status = record.state.status
    }
}

/// The extension that installed `task` in `snapshot`, the last one that lists it; none for a built-in task.
internal func installerOf(_ snapshot: RegistrySnapshot, _ task: AnyTaskDefinition?) -> String? {
    guard let task else { return nil }
    return snapshot.installed().last { $0.tasks.contains { $0.identity == task.identity } }?.name
}
