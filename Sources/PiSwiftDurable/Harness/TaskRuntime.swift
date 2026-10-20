import Foundation
import PiSwiftChord
import Synchronization

/// Runs each installed hooks value in agent order. A callback selects the typed handler.
public struct HookRunner: Sendable {
    private let runtime: TaskRuntime
    internal init(_ runtime: TaskRuntime) { self.runtime = runtime }
    /// Invokes the matching hooks in selected extension order.
    public func each<Hooks: Sendable>(_ type: Hooks.Type,
                                     context: ChordContext,
                                     invoke: (Hooks) async throws -> Void) async throws {
        try await withTaskCancellationContext(context) { context in
            let agent = try await runtime.agent(context: context)
            for registration in agentHooks(agent, taskName: runtime.taskKind) {
                guard let handlers = registration.handlers(as: type) else { continue }
                do { try await invoke(handlers) }
                catch {
                    if runtime.signal.aborted || context.abortSignal?.aborted == true { throw error }
                    let info = runtime.scheduler.taskInfo(runtime.invocation)
                    runtime.scheduler.report(error, ReportInfo(source: .extension, taskId: info.taskId, taskKind: info.taskKind,
                                                               conversationId: info.conversationId))
                }
            }
        }
    }
}

/// One invocation runtime. The same instance serves each phase in that invocation.
public final class TaskRuntime: Sendable {
    internal let scheduler: TaskScheduler
    internal let invocation: TaskInvocation
    internal let phase: RuntimePhase
    internal init(scheduler: TaskScheduler, invocation: TaskInvocation, phase: RuntimePhase) {
        self.scheduler = scheduler; self.invocation = invocation; self.phase = phase
    }
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID { invocation.taskId }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { invocation.conversationId }
    /// The cancellation signal bound to this invocation.
    public var signal: AbortSignal { invocation.controller.signal }
    /// The context and cancellation signal bound to this invocation.
    public var context: ChordContext { invocation.context }
    /// `HarnessOptions.models`, resolved at each access.
    public var models: any DurableModels { scheduler.models }
    /// The current host settings or resolved task settings.
    public var settings: Settings { scheduler.settings() }
    /// The installed extension and task definitions used by this harness.
    public var registry: RegistrySnapshot { phase.state.withLock { $0.snapshot } }
    /// Hook callbacks supplied by the selected extensions.
    public var hooks: HookRunner { HookRunner(self) }
    internal var taskKind: String { phase.state.withLock { $0.definition.name } }
    /// Returns the clock time in milliseconds.
    public func now() throws -> Int64 { try invocation.check(); return scheduler.now() }
    /// Forward a non-fatal failure to `HarnessOptions.onReport`, with this task in its info.
    public func report(_ error: any Error) throws { try invocation.check(); reportTask(error) }
    /// `report()` without the invocation check, for work that ends with it, such as a progress commit.
    internal func reportTask(_ error: any Error) { scheduler.report(error, scheduler.taskInfo(invocation)) }
    /// Commits state only while this invocation still owns the task. Inside the callback read only through `tx`:
    /// `snapshot`, `documentState`, `watchDoc`, `getTask`, and the other Session and runtime reads may queue on the line
    /// the callback holds, and then never return.
    ///
    /// A `waiting` or `sleeping` state ends the invocation even when its checkpoint is unchanged. A sleep rejects an
    /// `until` that is not a time. A `waiting` state rejects when `on` names a missing task or closes a cycle in the
    /// wait-for graph, which no task on it could finish first. Its edges run from each task to the tasks it waits on, unless it is abort-marked, and to
    /// its live ordinary owned work, which holds it as `completing`. Waiting on itself or on an owner that holds it closes
    /// the shortest such cycles; a background task may wait on the owner of its conversation. The rejection names the
    /// cycle. Only durable waits are edges: `waitForTask` and a nested call's wait are not checked.
    public func commit(_ change: (Transaction, TaskRecord) async throws -> TaskState?,
                       context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try await scheduler.gated(invocation, context: context) { tx, current in
                if let next = try await change(tx, current) { try await scheduler.commitState(tx, invocation: invocation, current: current, next: next) }
            }
        }
    }
    /// Reads a durable task memo or installs the candidate only when the memo is absent.
    public func memo(_ name: String, value: JSONValue? = nil, context: ChordContext) async throws -> JSONValue? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            try context.abortSignal?.throwIfAborted()
            guard let value else { return scheduler.current(taskId)?.memos?[name] }
            return try await scheduler.gated(invocation, context: context) { tx, current in
                if let winner = current.memos?[name] { return winner }
                var memos = current.memos ?? [:]; memos[name] = value
                try tx.setTask(current.replacing(memos: memos)); return value
            }
        }
    }
    /// Returns the resolved agent configuration for the conversation.
    public func agent(context: ChordContext) async throws -> Agent {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            let work = phase.state.withLock { state -> Task<Agent, any Error> in
                if let work = state.agent { return work }
                let snapshot = state.snapshot
                let work = Task { try await scheduler.resolveAgent(conversationId, snapshot, invocation.context) }
                state.agent = work; return work
            }
            return try await awaitWithContext(work, context)
        }
    }
    /// Returns the execution environment selected for this conversation.
    public func env(context: ChordContext) async throws -> (any ExecutionEnv)? {
        try await withTaskCancellationContext(context) { context in try invocation.check(); try context.abortSignal?.throwIfAborted(); return try await scheduler.env(conversationId, context) }
    }
    /// Commit a sleep: the task holds no invocation until the Harness clock reaches `until`, then resumes at `checkpoint`.
    /// Returns once the sleep is stored, not when the time comes; the phase returns right after. Returning
    /// `.sleeping(checkpoint:until:)` from `commit()` is the same sleep, for one that must commit together with other
    /// writes.
    public func sleepUntil<Checkpoint: TaskCheckpoint>(_ until: Int64, checkpoint: Checkpoint, context: ChordContext) async throws {
        let encoded = try encodeTaskCheckpoint(checkpoint)
        try await commit({ _, _ in .sleeping(checkpoint: encoded, until: until) }, context: context)
    }
    /// Call `callback` once after about `delayMs` on the Harness's timer (`HarnessOptions.setTimer`), for pacing work
    /// inside a phase, such as throttled progress commits. Not durable: the invocation's end disarms it, and after its end
    /// nothing is armed. Returns a function that disarms it. Wait for time between phases with `sleepUntil()`.
    public func setTimer(_ callback: @escaping @Sendable () -> Void, delayMs: Int64) -> @Sendable () -> Void {
        let id = UUID(), invocation = self.invocation
        // An ended invocation's timers never fire. Listed before arming, so a timer that fires at once finds itself.
        guard invocation.state.withLock({ state -> Bool in
            if state.ended { return false }
            state.timers[id] = {}
            return true
        }) else { return {} }
        let disarm = scheduler.timers.foreground({
            let live = invocation.state.withLock { state in state.timers.removeValue(forKey: id) != nil && !state.ended }
            if live { callback() }
        }, delayMs)
        let listed = invocation.state.withLock { state -> Bool in
            guard state.timers[id] != nil else { return false }
            state.timers[id] = disarm
            return true
        }
        // Fired, or the invocation ended meanwhile, which disarmed only the placeholder.
        if !listed { disarm() }
        return {
            _ = invocation.state.withLock { $0.timers.removeValue(forKey: id) }
            disarm()
        }
    }
    /// Returns the current durable task record, or nil when it is absent.
    public func getTask(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.task(id, context: context) }
        }
    }
    /// Waits for a terminal task outcome and returns its durable receipt.
    public func waitForTask(_ id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await withTaskCancellationContext(context) { context in
            try invocation.check(); scheduler.resume()
            return try await scheduler.waitForTask(id: id, context: context.withAbortSignal(signal))
        }
    }
    /// Abort a task this task owns, as `Harness.abortTask()` does, and return once it is terminal. Throws for a task
    /// another owns; returns at once for a terminal one. A task abandoned after a restart keeps its `restart` mark, so one
    /// whose definition is missing waits for it instead of becoming orphaned.
    public func abortOwned(_ id: TaskID, context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            let bound = context.withAbortSignal(signal)
            let record = try await scheduler.session.readOnLine { try await scheduler.storage.task(id, context: bound) }
            guard let record, record.owner == taskId else {
                throw SessionError.message("Task \(id.rawValue) is not owned by task \(taskId.rawValue)")
            }
            if record.state.status == "terminal" { return }
            _ = try await scheduler.abort(id: id, context: bound, keepRestart: true)
            _ = try await scheduler.waitForTask(id: id, context: bound)
        }
    }
    /// Live tasks this task owns directly, in ID order: also those an earlier invocation created, before a restart. Tasks
    /// in conversations it owns are not included. Copies of the committed records.
    public func ownedTasks(context: ChordContext) async throws -> [TaskRecord] {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine {
                // The step that ends the invocation may have run on the line before this.
                try invocation.check()
                try context.abortSignal?.throwIfAborted()
                // Every live task is listed under its parent node, its owner task when it has one.
                let owned = scheduler.state.withLock { state in
                    (state.below[.task(taskId)] ?? []).compactMap { node -> TaskRecord? in
                        guard case .task(let id) = node, let record = state.live[id], record.owner == taskId else { return nil }
                        return record
                    }
                }
                return owned.sorted { $0.id < $1.id }
            }
        }
    }
    /// Returns the terminal outcomes of the supplied tasks in ID-list order.
    public func outcomes(_ ids: [TaskID], context: ChordContext) async throws -> [TaskOutcome] {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine {
                var values: [TaskOutcome] = []
                for id in ids {
                    guard let record = try await scheduler.storage.task(id, context: context), case .terminal(let outcome, _) = record.state else { throw SessionError.message("Task \(id.rawValue) is not terminal") }
                    values.append(outcome)
                }
                return values
            }
        }
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationHandle? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.conversation(id, .init(signal: signal, check: { [invocation] in try invocation.check() }), context)
        }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryRecord? {
        try await withTaskCancellationContext(context) { context in
            try invocation.check()
            return try await scheduler.session.readOnLine { try await scheduler.storage.entry(conversationId, id: id, context: context)?.entry }
        }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry<Data>(_ token: EntryKind<Data>, id: EntryID, context: ChordContext) async throws -> TypedEntry<Data>? {
        guard let record = try await entry(id, context: context), record.kind == token.kind else { return nil }
        return try TypedEntry(record)
    }
    /// Reads the visible model context through the optional inclusive entry boundary.
    public func context(_ id: ConversationID, at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await withTaskCancellationContext(context) { context in try await scheduler.readContext(invocation, id: id, at: at, context: context) }
    }
}
