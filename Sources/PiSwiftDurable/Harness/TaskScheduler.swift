import Foundation
import PiSwiftChord
import Synchronization

internal struct InvocationBinding: Sendable {
    let signal: AbortSignal
    let check: @Sendable () throws -> Void
}
internal final class TaskInvocation: Sendable {
    let taskId: TaskID
    let kind: String
    let conversationId: ConversationID
    let abort: Bool
    let controller = AbortController()
    let context: ChordContext
    let done = HarnessPromise<Void>()
    struct State: Sendable {
        var ended = false
        var work: Task<Void, Never>?
        var watches: [UUID: @Sendable () -> Void] = [:]
        /// Timers armed through the runtime; disarmed at invocation end.
        var timers: [UUID: @Sendable () -> Void] = [:]
    }
    let state = Mutex(State())
    init(_ record: TaskRecord, abort: Bool, context: ChordContext) {
        taskId = record.id; kind = record.kind; conversationId = record.conversationId; self.abort = abort
        self.context = context.withoutAbortSignal().withAbortSignal(controller.signal)
    }
    func check() throws {
        if state.withLock({ $0.ended }) { throw SessionError.message("Task \(taskId.rawValue) invocation has ended") }
    }
}
internal final class RuntimePhase: Sendable {
    struct State: Sendable {
        var definition: AnyTaskDefinition
        var snapshot: RegistrySnapshot
        var agent: Task<Agent, any Error>?
        var reported: UUID?
        var reportedMissing = false
    }
    let state: Mutex<State>
    init(_ definition: AnyTaskDefinition, _ snapshot: RegistrySnapshot) { state = Mutex(State(definition: definition, snapshot: snapshot)) }
}

/// Every decision that changes a task runs in one callback on the Session line.
///
/// Tasks and conversations form one ownership tree (spec §5.5): a task's parent is its owner task, or its conversation;
/// a conversation's parent is its owner task, if any. Walks up that tree decide what reaches one task: a cancelling
/// owner, a scope. `below` lists the tree downward around live work, so what lies below one node is a walk down from
/// it: a task's live ordinary owned work, which holds its outcome as `completing` and delays its abort handler, a
/// scope's tasks, a cascade's reach. No pass visits every live task; the sets in `State` hold each pass's candidates.
///
/// The ownership indexes are bounded by live work: an owner edge and an ended task's ownership fields are kept only while
/// something is listed below them in `below`, so only the chains above live tasks are known, whole. Work that appears
/// later below a dropped node finds it unknown and loads its chain from storage again.
internal final class TaskScheduler: Sendable {
    internal let toolServices = ToolServices()
    let session: Session
    let storage: any DurableStorage
    let registry: any RegistryReader
    /// The host's current model access (`HarnessOptions.models`); read at each access.
    let currentModels: @Sendable () -> any DurableModels
    var models: any DurableModels { currentModels() }
    let now: @Sendable () -> Int64
    /// `HarnessOptions.onWake`: replaces the timer for sleeping tasks.
    let onWake: (@Sendable (Wake) throws -> Void)?
    /// The host's timers (`HarnessOptions.setTimer`).
    let timers: Timers
    let settings: @Sendable () -> Settings
    let resolveAgent: @Sendable (ConversationID, RegistrySnapshot, ChordContext) async throws -> Agent
    let env: @Sendable (ConversationID, ChordContext) async throws -> (any ExecutionEnv)?
    let conversation: @Sendable (ConversationID, InvocationBinding, ChordContext) async throws -> ConversationHandle?
    let report: @Sendable (any Error, ReportInfo) -> Void
    let context: ChordContext
    let settleOutcome: @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void
    let withdrawInputs: @Sendable (Transaction, ConversationID) async throws -> Void
    struct KeptContext: Sendable { let range: ContextRange; var idleSince: Int64? }
    /// A timer the scheduler keeps, by ID: a callback that arrives after it was disarmed or replaced does nothing.
    struct ArmedTimer: Sendable { let at: Int64; let id: Int; let disarm: @Sendable () -> Void }
    struct State: Sendable {
        var live: [TaskID: TaskRecord] = [:]
        /// When each live task became live; listings and reservation passes follow this order.
        var order: [TaskID: Int] = [:]
        var nextOrder = 0
        // Owner task of each known conversation; an entry with nil owner is a known, ownerless conversation.
        var edges: [ConversationID: TaskID?] = [:]
        /// Ownership fields of the known terminal tasks, which walks pass through.
        var settled: [TaskID: TaskNode] = [:]
        /// Ended tasks and conversations found unneeded, dropped by `sweep()` at the end of the commit's publication unless
        /// needed again by then: a chain load installs nodes before the work below them is listed.
        var dropQueue: Set<OwnershipUp> = []
        /// The tree downward around live work: each node's child nodes that are live tasks or have nodes listed below
        /// them. A conversation's parent is its owner task; ownerless ones with work are in `roots`.
        var below: [OwnershipUp: Set<OwnershipUp>] = [:]
        var roots: Set<ConversationID> = []
        /// Known tasks whose chain may not be loaded; every other known task's chain is, and stays, loaded.
        var unloaded: Set<TaskID> = []
        /// Live tasks with cancellation intent, the sources of abort cascades (spec §5.4).
        var intent: Set<TaskID> = []
        /// Live tasks that are not `completing`, the candidates of a reservation pass; ones found waiting leave it.
        var runnable: Set<TaskID> = []
        /// Sleeping live tasks, due or not: the candidates of `wakeDue(now:)`.
        var sleeping: Set<TaskID> = []
        /// `completing` tasks the next finalize pass checks: those that started holding, and holders of ended work.
        var finalizeChecks: Set<TaskID> = []
        /// Live waiting tasks by each task in their `on`.
        var waiters: [TaskID: Set<TaskID>] = [:]
        /// `failFast` waiters the next reconcile checks for a failed task in `on`: at open, when they start waiting, and
        /// when one of their tasks fails.
        var failFastChecks: Set<TaskID> = []
        // Internal probe: the task nodes walks down reached, so tests can bound what a pass visits.
        var walked = 0
        var invocations: [TaskID: TaskInvocation] = [:]
        var joining: [UUID: TaskInvocation] = [:]
        var failedMigrations: [TaskID: (UUID, any Error)] = [:]
        var enabled = false
        var closing = false
        var dirty = false
        var pumping = false
        var worker: Task<Void, Never>?
        var cascadePending = false
        /// Live tasks with `abandonOnRestart` found at open, from an earlier Harness. The first reservation pass
        /// abort-marks them with reason `restart`, so nothing of them or below them runs a phase again.
        var abandoned: Set<TaskID> = []
        var reconcileScheduled = false
        var sweepScheduled = false
        var reconciles: [UUID: Task<Void, Never>] = [:]
        var subscriptions: [SessionSubscription] = []
        var unsubscribe: (@Sendable () -> Void)?
        var contexts: [ConversationID: KeptContext] = [:]
        /// Background timer for the earliest expiry of an idle context, unless the host declined it (see `scheduleExpiry`).
        var expiry: ArmedTimer?
        /// Timer for the earliest sleep, without `onWake` while scheduling runs.
        var timer: ArmedTimer?
        var nextTimer = 0
        /// Last value given to `onWake`, so an unchanged one is not repeated.
        var lastWake: Wake?
        /// A wake delivery is running; `wakeDirty` asks it for one more round.
        var wakeScheduled = false
        var wakeDirty = false
        var blockedListeners: [UUID: @Sendable () -> Void] = [:]
    }
    let state = Mutex(State())
    let taskWaiters = Waiters<TaskID, SettledTask>()
    let idleWaiters = Waiters<ConversationID?, Void>()
    init(session: Session, registry: any RegistryReader, models: @escaping @Sendable () -> any DurableModels,
         now: @escaping @Sendable () -> Int64, onWake: (@Sendable (Wake) throws -> Void)?, timers: Timers,
         settings: @escaping @Sendable () -> Settings,
         agent: @escaping @Sendable (ConversationID, RegistrySnapshot, ChordContext) async throws -> Agent,
         env: @escaping @Sendable (ConversationID, ChordContext) async throws -> (any ExecutionEnv)?,
         conversation: @escaping @Sendable (ConversationID, InvocationBinding, ChordContext) async throws -> ConversationHandle?,
         report: @escaping @Sendable (any Error, ReportInfo) -> Void, context: ChordContext,
         settleOutcome: @escaping @Sendable (Transaction, TaskRecord, TaskOutcome) async throws -> Void = { _, _, _ in },
         withdrawInputs: @escaping @Sendable (Transaction, ConversationID) async throws -> Void = { _, _ in }) {
        self.session = session; storage = session.storage; self.registry = registry; currentModels = models
        self.now = now; self.onWake = onWake; self.timers = timers; self.settings = settings; resolveAgent = agent; self.env = env
        self.conversation = conversation; self.report = report; self.context = context.withoutAbortSignal()
        self.settleOutcome = settleOutcome; self.withdrawInputs = withdrawInputs
    }
    var closing: Bool { state.withLock { $0.closing } }
    func records() -> [TaskRecord] { state.withLock { state in state.ordered(state.live.keys).compactMap { state.live[$0] } } }
    func current(_ id: TaskID) -> TaskRecord? { state.withLock { $0.live[id] } }
    /// Load live tasks and change surviving `running` tasks back to `pending`, counting the restart. Dispatches nothing. A
    /// task that reaches the restart limit this way is parked and reported.
    func open(context: ChordContext) async throws {
        let commits = try session.observeCommits { [weak self] publication, _ in self?.observe(publication) }
        let close = try session.subscribeClose { [weak self] in self?.seal() }
        let unsubscribe = registry.subscribe { [weak self] in
            self?.notifyBlocked()
            self?.kick()
        }
        state.withLock { $0.subscriptions = [commits, close]; $0.unsubscribe = unsubscribe }
        let limit = restartLimit()
        var parked: [TaskRecord] = []
        try await session.commit({ tx in
            var found: [TaskRecord] = []
            for status in [TaskStatus.pending, .running, .waiting, .sleeping, .completing] {
                found += try await scanAll { cursor in try await tx.scanTasks(.init(status: status), limit: 256, cursor: cursor) }
            }
            // No chain is loaded yet: every task starts in `unloaded`, and the first pass loads them.
            state.withLock { state in
                for record in found {
                    state.track(nil, record)
                    if record.abandonOnRestart { state.abandoned.insert(record.id) }
                    if case .waiting(_, _, .failFast, _) = record.state { state.failFastChecks.insert(record.id) }
                }
            }
            for record in found {
                if case .running(let checkpoint, _) = record.state {
                    let restarts = (record.restarts ?? 0) + 1
                    try tx.setTask(record.replacing(state: .pending(checkpoint: checkpoint)).withRestarts(restarts))
                    if Double(restarts) >= limit && !record.abortRequested { parked.append(record) }
                }
            }
        }, context: context)
        for record in parked {
            let restarts = (record.restarts ?? 0) + 1
            let error = SessionError.message("Task \(record.id.rawValue) (\(record.kind)) was cut off \(restarts) times without progress; it is parked until retryTask()")
            report(error, taskInfo(taskId: record.id, kind: record.kind, conversationId: record.conversationId))
        }
        state.withLock { $0.cascadePending = true }
        scheduleReconcile()
        scheduleWake()
    }
    /// Enable scheduling, and make sleeping tasks that are due runnable: a host wakeup, such as an alarm, calls this.
    /// Idempotent; the kick does nothing once closing.
    func resume() {
        let now = now()
        state.withLock { state in state.enabled = true; state.wakeDue(now: now) }
        kick()
    }
    /// Signal every invocation and wait for them; writes nothing. Close calls this after every close listener has run,
    /// so waits, watches, and streams a task holds end with the Session's reason, not as cancelled by its signal.
    func join() async {
        let (invocations, worker, reconciles) = state.withLock { (Array($0.joining.values), $0.worker, Array($0.reconciles.values)) }
        for invocation in invocations { invocation.controller.abort() }
        for invocation in invocations { _ = try? await invocation.done.value() }
        await worker?.value
        for work in reconciles { await work.value }
    }
    /// Close listener: runs synchronously once admission is sealed, before `join()`, or when the Session fails.
    private func seal() {
        let (timers, unsubscribe) = state.withLock { state in
            state.closing = true; state.contexts = [:]
            let timers = [state.expiry, state.timer].compactMap { $0 }; state.expiry = nil; state.timer = nil
            let unsubscribe = state.unsubscribe; state.unsubscribe = nil
            return (timers, unsubscribe)
        }
        unsubscribe?(); for timer in timers { timer.disarm() }
        taskWaiters.rejectAll(closedError(session)); idleWaiters.rejectAll(closedError(session))
    }
    /// Fail the Session, which reports it, for a throw in one of the scheduler's own commits; ignored once closing.
    /// Close seals the Session before its listeners seal the scheduler, and another thread can commit in between, so
    /// the Session's own closing counts too: a commit refused by close is not a failure.
    func failSession(_ error: any Error) {
        if !closing && !session.isClosing { session.fail(error) }
    }
    private func observe(_ publication: CommitPublication) {
        var aborts: [TaskInvocation] = [], settled: [TaskRecord] = []
        var repair = false, changed = false
        state.withLock { state in
            // Edges first, so the tasks a commit creates in a new conversation hang from it.
            for change in publication.changes {
                if case .conversation(let record) = change, state.edges[record.id] == nil { state.setEdge(record.id, record.owner?.taskId) }
            }
            var failed: [TaskID] = [], updated: [TaskRecord] = []
            for change in publication.changes {
                guard case .task(let record) = change else { continue }
                changed = true
                let previous = state.live[record.id]
                if record.failedOutcome && previous?.failedOutcome != true { failed.append(record.id) }
                state.track(previous, record)
                if record.state.status == "terminal" {
                    state.failedMigrations.removeValue(forKey: record.id); state.failFastChecks.remove(record.id)
                    // Its owner may finalize now.
                    settled.append(record); repair = true
                    continue
                }
                if record.abortRequested && previous?.abortRequested != true {
                    state.cascadePending = true
                    if let invocation = state.invocations[record.id], !invocation.abort { aborts.append(invocation) }
                }
                // A request replacing a `restart` mark upgrades the marks of the work below.
                if previous?.abortReason != nil && record.abortReason == nil { state.cascadePending = true }
                if record.state.status == "completing" && previous?.state.status != "completing" {
                    repair = true
                    if record.cancellationIntent { state.cascadePending = true }
                }
                if case .waiting(_, _, .failFast, _) = record.state, previous?.state.status != "waiting" {
                    state.failFastChecks.insert(record.id); repair = true
                }
                // Its owners and place never change: what is above it is checked once, when it becomes live.
                if previous == nil { updated.append(record) }
            }
            for id in failed {
                for waiter in state.waiters[id] ?? [] {
                    if case .waiting(_, _, .failFast, _)? = state.live[waiter]?.state { state.failFastChecks.insert(waiter); repair = true }
                }
            }
            for change in publication.changes {
                // A queued input below a cancelled owner is withdrawn, even after its cascade.
                guard case .submission(let input) = change, input.type == "input", input.status == "queued" else { continue }
                // Only an owner with cancellation intent withdraws it; a later intent's mark runs the cascade then.
                if state.intent.isEmpty { continue }
                let up = OwnershipUp.conversation(input.conversationId)
                if !state.known(up) || state.belowCancelled(up) { state.cascadePending = true }
            }
            for record in updated {
                // Work created below a cancelled owner, even after its cascade, is aborted too.
                if state.unloaded.contains(record.id) { repair = true }
                else if !record.background && !record.abortRequested && state.belowCancelled(record.parent) { state.cascadePending = true }
            }
            if state.cascadePending { repair = true }
            state.sweep()
        }
        for invocation in aborts { invocation.controller.abort() }
        for record in settled { taskWaiters.resolve(record.id, value: SettledTask(record: record)) }
        if repair { scheduleReconcile() }
        if changed { settleIdle(); kick() }
    }
    /// A Task is created under the lock. It cannot enter the pump until the lock is released.
    func kick() {
        scheduleWake()
        state.withLock { state in
            guard !state.closing else { return }
            state.dirty = true
            guard !state.pumping && state.enabled else { return }
            state.pumping = true
            state.worker = Task { [weak self] in await self?.pump() }
        }
    }
    private func pump() async {
        while state.withLock({ state in
            guard state.dirty && !state.closing else { state.pumping = false; return false }
            state.dirty = false; return true
        }) {
            do {
                if state.withLock({ $0.enabled && !$0.closing }) {
                    let reservations = try await reserve()
                    for reservation in reservations { start(reservation) }
                }
            } catch {
                // As in `reconcile()`: the reservation commit runs no extension code but `migrate`, whose throw is caught.
                failSession(error)
            }
            settleIdle()
        }
    }
    /// Repair durable intent separately from handler scheduling, including while paused.
    func scheduleReconcile() {
        state.withLock { state in
            guard !state.closing, !state.reconcileScheduled else { return }
            state.reconcileScheduled = true
            let id = UUID()
            state.reconciles[id] = Task { [weak self] in
                guard let self else { return }
                let checks = self.state.withLock { state -> Set<TaskID> in
                    state.reconcileScheduled = false; state.cascadePending = false
                    defer { state.failFastChecks = [] }
                    return state.failFastChecks
                }
                do { try await self.reconcile(checks: checks) }
                catch {
                    // No extension code runs in this commit: a throw is a storage failure, a host callback, or a bug.
                    // None is fixed by running the pass again, so it fails the Session, which reports it.
                    self.failSession(error)
                }
                self.settleIdle()
                _ = self.state.withLock { $0.reconciles.removeValue(forKey: id) }
            }
        }
    }
    /// Sweep in a job of its own on the Session line, after the operation underway: a rejected commit, one with nothing to
    /// write, and a read publish nothing, so the sweep at the end of `observe` would not run for what they loaded. The
    /// index methods only queue nodes, as `State` cannot reach the line; a chain load calls this after them.
    func scheduleSweep() {
        let schedule = state.withLock { state -> Bool in
            guard !state.dropQueue.isEmpty, !state.sweepScheduled, !state.closing else { return false }
            state.sweepScheduled = true; return true
        }
        guard schedule else { return }
        Task { [weak self] in
            guard let self else { return }
            // Rejected only once the Session is closing or failed, when nothing is kept anyway.
            _ = try? await session.readOnLine { state.withLock { state in state.sweepScheduled = false; state.sweep() } }
        }
    }
    /// Load the owner edges and task nodes from `start` up to its ownerless root. A known task outside `unloaded` ends the
    /// walk, as its chain is loaded; the `unloaded` tasks passed have a loaded chain afterwards. Loading a node can reveal
    /// a cancelled owner, so it makes the next reconcile derive cascade marks.
    func loadChain(_ start: OwnershipUp, overlay: TaskOverlay = .empty) async throws {
        enum Known { case loaded, node(TaskNode), absent }
        var at: OwnershipUp? = start, seen = Set<OwnershipUp>(), passed: [TaskID] = []
        walk: while let step = at, seen.insert(step).inserted {
            switch step {
            case .task(let id):
                let known = state.withLock { state -> Known in
                    if let node = state.live[id].map(TaskNode.init) ?? state.settled[id] {
                        return state.unloaded.contains(id) ? .node(node) : .loaded
                    }
                    // Created in this commit: the load from its own record covers what is above it.
                    return overlay.tasks[id] == nil ? .absent : .loaded
                }
                let node: TaskNode
                switch known {
                case .loaded: break walk
                case .node(let found): node = found
                case .absent:
                    guard let record = try await storage.task(id, context: context) else { return }
                    node = TaskNode(record)
                    if record.state.status == "terminal" { state.withLock { $0.settle(id, node) }; scheduleSweep() }
                    // A loaded node can reveal a cancelling owner: the next reconcile derives marks again.
                    scheduleReconcile()
                }
                passed.append(id); at = node.parent
            case .conversation(let id):
                var edge = state.withLock { $0.edge(id, overlay) }
                if edge == nil {
                    let owner = try await storage.conversation(id, context: context)?.owner?.taskId
                    state.withLock { $0.setEdge(id, owner) }
                    scheduleSweep()
                    edge = .some(owner)
                    // A loaded node can reveal a cancelling owner: the next reconcile derives marks again.
                    scheduleReconcile()
                }
                at = (edge ?? nil).map(OwnershipUp.task)
            }
        }
        state.withLock { state in for id in passed { state.unloaded.remove(id) } }
    }
    /// Load the owner chains of the tasks in `unloaded`, on the Session line.
    func loadScopes() async throws {
        for id in state.withLock({ Array($0.unloaded) }) {
            // An earlier load in this loop may have passed it.
            if state.withLock({ $0.unloaded.contains(id) }) { try await loadChain(.task(id)) }
        }
    }
    /// Load the owner chains of every conversation with queued inputs, on the Session line; returns them.
    func loadQueuedScopes() async throws -> Set<ConversationID> {
        let submissions = try await scanAll { cursor in
            try await storage.scanSubmissions(.init(status: .queued), limit: 256, cursor: cursor, context: context)
        }
        let ids = Set(submissions.filter { $0.type == "input" }.map(\.conversationId))
        for id in ids { try await loadChain(.conversation(id)) }
        return ids
    }
    func above(_ start: OwnershipUp, overlay: TaskOverlay = .empty) -> [OwnershipStep] { state.withLock { $0.above(start, overlay: overlay) } }
    func inScope(_ start: OwnershipUp, conversationId: ConversationID?, background: Bool = false) -> Bool? {
        state.withLock { $0.inScope(start, conversationId: conversationId, background: background) }
    }
    func belowCancelled(_ start: OwnershipUp) -> Bool { state.withLock { $0.belowCancelled(start) } }
    func hasOwnedLive(_ owner: TaskID, overlay: inout TaskOverlay, done: Set<TaskID> = []) -> Bool {
        state.withLock { $0.hasOwnedLive(owner, overlay: &overlay, done: done) }
    }
    func idle(_ id: ConversationID?) -> Bool { state.withLock { $0.idle(id) } }
    private func reconcile(checks: Set<TaskID>) async throws {
        try await session.commit({ tx in
            guard !closing else { return }
            try await loadScopes()
            let queued = try await loadQueuedScopes()
            // A cascade from an abandoned owner passes its `restart` reason on; any other intent marks, or upgrades a
            // `restart` mark, as a request. Collected first, so a request wins over a `restart` mark of the same pass.
            var marks: [TaskID: (record: TaskRecord, reason: TaskAbortReason?)] = [:]
            func mark(_ record: TaskRecord, _ reason: TaskAbortReason?) {
                if let staged = marks[record.id], staged.reason == nil { return }
                if record.abortRequested && (record.abortReason == nil || reason != nil) { return }
                marks[record.id] = (record, reason)
            }
            // Derived again on every pass, as loading edges can reveal a cancelled owner.
            for (record, reason) in state.withLock({ $0.cascades() }) { mark(record, reason) }
            for id in state.withLock({ $0.ordered(checks) }) {
                guard let waiter = current(id), case .waiting(_, let on, .failFast, _) = waiter.state, try await anyFailed(on) else { continue }
                // Every other live task: the failed one keeps its own outcome.
                for member in on { if let live = current(member), !live.failedOutcome { mark(live, nil) } }
            }
            for id in state.withLock({ $0.ordered(marks.keys) }) { let staged = marks[id]!; try tx.setTask(staged.record.withAbortMark(staged.reason)) }
            for id in queued where belowCancelled(.conversation(id)) { try await withdrawInputs(tx, id) }
            try await finalize(tx)
        }, context: context)
    }
    /// Whether any of `ids` holds or ended with an outcome other than `completed`.
    private func anyFailed(_ ids: [TaskID]) async throws -> Bool {
        for id in ids {
            let found: TaskRecord?
            if let live = current(id) { found = live } else { found = try await storage.task(id, context: context) }
            if found?.failedOutcome == true { return true }
        }
        return false
    }
    /// Write the terminal record of every `completing` task without live ordinary owned work. A held scheduler outcome
    /// gets its Harness cleanup here.
    private func finalize(_ tx: Transaction) async throws {
        // A worklist: the tasks that started holding, and the holders of work that ended. Finalizing one can free the
        // nearest live task above it, which goes on the list. Tasks finalized here have no live work below them, so walks
        // down skip them.
        // In rounds: the holders the tasks of one round free are checked once, in the next, so a holder of many tasks that
        // end together is walked once, not once per task.
        var round = state.withLock { state in defer { state.finalizeChecks = [] }; return state.ordered(state.finalizeChecks) }
        var done = Set<TaskID>(), overlay = try TaskOverlay(tx)
        while !round.isEmpty {
            var next = Set<TaskID>()
            for id in round {
                guard let record = overlay.tasks[id] ?? current(id), case .completing(let outcome, _) = record.state, !done.contains(id) else { continue }
                if hasOwnedLive(id, overlay: &overlay, done: done) { continue }
                let terminal = record.replacing(state: .terminal(outcome: outcome))
                try tx.setTask(terminal)
                overlay.tasks[id] = terminal; done.insert(id)
                // Only the scheduler writes `faulted` and `orphaned` (spec §5.4); their cleanup waits for this commit.
                if outcome.status == "faulted" || outcome.status == "orphaned" { try await settleOutcome(tx, record, outcome) }
                let above = state.withLock { $0.nearestLiveAbove(TaskNode(record), overlay: overlay) }
                if let above, above.state.status == "completing" { next.insert(above.id) }
            }
            round = state.withLock { $0.ordered(next) }
        }
    }
    /// Write an outcome the scheduler decided, or one a task committed. While the task's ordinary owned work is live, judged
    /// on the commit's candidates, it holds as `completing` and its Harness cleanup waits for the final commit (spec §5.5).
    func terminate(_ tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
        try await loadScopes()
        var overlay = try TaskOverlay(tx)
        for record in overlay.tasks.values { try await loadChain(record.parent, overlay: overlay) }
        let held = hasOwnedLive(record.id, overlay: &overlay)
        try tx.setTask(record.replacing(state: held ? .completing(outcome: outcome) : .terminal(outcome: outcome)))
        if !held && (outcome.status == "faulted" || outcome.status == "orphaned") { try await settleOutcome(tx, record, outcome) }
    }
    func fit(_ record: TaskRecord, definition: AnyTaskDefinition?) -> (reason: String?, error: (any Error)?, migrates: Bool) {
        guard let definition else { return ("missing_task", nil, false) }
        if definition.version < record.version { return ("task_too_old", nil, false) }
        if definition.version == record.version { return (nil, nil, false) }
        if let failed = state.withLock({ $0.failedMigrations[record.id] }), failed.0 == definition.identity { return ("migration_failed", failed.1, false) }
        return (nil, nil, true)
    }
    struct Reservation: Sendable { let invocation: TaskInvocation; let definition: AnyTaskDefinition; let snapshot: RegistrySnapshot; let joinID: UUID }
    /// Reserve every eligible task in one commit; orphan abort-marked tasks no definition can take, unless abandoned
    /// after a restart. The first pass after open only abort-marks the abandoned tasks, so later passes see the marks.
    private func reserve() async throws -> [Reservation] {
        var reservations: [Reservation] = []
        var abandoned: [TaskID] = []
        let limit = restartLimit()
        do {
            try await session.commit({ tx in
                guard !closing else { return }
                let pending = state.withLock { Array($0.abandoned) }
                for id in pending {
                    if let record = current(id), !record.abortRequested { try tx.setTask(record.withAbortMark(.restart)) }
                }
                if !pending.isEmpty { abandoned = pending; return }
                try await loadScopes()
                // Every pass picks up sleeps whose time has come: a pass started by any change may be the first to run after
                // a deadline, and the wake it schedules no longer keeps a timer for a due sleep.
                let passStart = now()
                state.withLock { $0.wakeDue(now: passStart) }
                let snapshot = registry.snapshot()
                for taskId in state.withLock({ $0.ordered($0.runnable) }) {
                    let now = now()
                    let candidate = state.withLock { state -> TaskRecord? in
                        guard let record = state.live[taskId], record.state.status != "completing", state.invocations[taskId] == nil,
                              // It returns once what it waits for ends, its record changes, or the work below it ends.
                              state.waitingOn(record, first: true).isEmpty,
                              // It returns at the first pass after its time comes, which the timer, `resume()`, or any
                              // change starts.
                              !record.notDue(now),
                              // It returns when `retry()` clears its restart count.
                              !record.parked(limit) else { state.runnable.remove(taskId); return nil }
                        return record
                    }
                    guard let original = candidate else { continue }
                    // Work below an owner with cancellation intent waits for its cascade mark instead of running a phase;
                    // schedule the cascade, which may not have run yet.
                    if !original.abortRequested && !original.background && belowCancelled(original.parent) {
                        state.withLock { $0.cascadePending = true }
                        scheduleReconcile()
                        continue
                    }
                    var record = original
                    let definition = snapshot.task(name: record.kind)
                    var resolution = fit(record, definition: definition)
                    if resolution.reason == nil, resolution.migrates, let definition {
                        do {
                            guard let migrate = definition.migrate else { throw SessionError.message("Task \(record.kind) version \(definition.version) has no migration from \(record.version)") }
                            let next = try migrate(record.input, record.state.checkpoint!, record.version)
                            record = record.replacing(input: next.input, version: definition.version, state: .running(checkpoint: next.checkpoint))
                        } catch {
                            state.withLock { $0.failedMigrations[record.id] = (definition.identity, error) }
                            // Blocked now without a commit: the graph must hear it.
                            notifyBlocked()
                            report(error, taskInfo(taskId: record.id, kind: record.kind, conversationId: record.conversationId))
                            resolution = ("migration_failed", error, false)
                        }
                    }
                    if let reason = resolution.reason {
                        // An abandoned task waits for its definition, so its abort handler can clean up.
                        if record.abortRequested && record.abortReason == nil {
                            try await terminate(tx, record: record, outcome: .orphaned(reason: reason))
                        }
                        continue
                    }
                    guard let definition, let checkpoint = record.state.checkpoint else { continue }
                    if original.state.status != "running" || resolution.migrates {
                        try tx.setTask(record.replacing(state: .running(checkpoint: checkpoint)))
                    }
                    let invocation = TaskInvocation(record, abort: record.abortRequested, context: context), id = UUID()
                    // Registered on the line, so marks and later reservations see it and close joins it; `end` makes it a
                    // candidate again.
                    state.withLock { $0.invocations[record.id] = invocation; $0.joining[id] = invocation; $0.runnable.remove(record.id) }
                    reservations.append(Reservation(invocation: invocation, definition: definition, snapshot: snapshot, joinID: id))
                }
            }, context: context)
        } catch {
            for reservation in reservations { end(reservation.invocation); finish(reservation) }
            throw error
        }
        // Marked, or already marked or gone: done with them. Reserve again, now seeing the marks.
        if !abandoned.isEmpty {
            state.withLock { state in
                for id in abandoned { state.abandoned.remove(id) }
                state.dirty = true
            }
        }
        return reservations
    }
    private func start(_ reservation: Reservation) {
        let work = Task {
            await run(reservation)
            end(reservation.invocation); finish(reservation); kick()
        }
        reservation.invocation.state.withLock { $0.work = work }
    }
    private func finish(_ reservation: Reservation) {
        reservation.invocation.done.finish(.success(()))
        _ = state.withLock { $0.joining.removeValue(forKey: reservation.joinID) }
    }
    func end(_ invocation: TaskInvocation) {
        let stops = invocation.state.withLock { state -> (watches: [@Sendable () -> Void], timers: [@Sendable () -> Void])? in
            guard !state.ended else { return nil }; state.ended = true
            let watches = Array(state.watches.values); state.watches = [:]
            let timers = Array(state.timers.values); state.timers = [:]
            return (watches, timers)
        }
        guard let stops else { return }
        state.withLock { state in
            guard state.invocations[invocation.taskId] === invocation else { return }
            state.invocations.removeValue(forKey: invocation.taskId)
            if state.live[invocation.taskId] != nil { state.runnable.insert(invocation.taskId) }
        }
        for stop in stops.watches { stop() }
        for disarm in stops.timers { disarm() }
        invocation.controller.abort(SessionError.message("Task \(invocation.taskId.rawValue) invocation has ended"))
    }
    enum Decision { case proceed, end, fault(any Error) }
    private func step(_ invocation: TaskInvocation, decide: (Transaction, TaskRecord) throws -> Decision) async -> TaskRecord? {
        var fault: (any Error)?
        do {
            let continued: TaskRecord? = try await session.commit({ tx in
                guard let current = current(invocation.taskId), current.state.status == "running", !closing else { end(invocation); return nil }
                switch try decide(tx, current) {
                case .proceed: return current
                case .end: end(invocation); return nil
                case .fault(let error):
                    end(invocation)
                    fault = error
                    try await terminate(tx, record: current, outcome: .faulted(error: .init(message: String(describing: error))))
                    return nil
                }
            }, context: context)
            // Reported once the fault is durable: a host may count it, for example toward a breaker.
            if let fault { report(fault, taskInfo(invocation, faulted: true)) }
            return continued
        } catch {
            // The step writes the scheduler's own decision, a fault or a terminal record; a throw there would otherwise
            // leave the task running, to be reserved and run again.
            end(invocation); failSession(error); return nil
        }
    }
    private func run(_ reservation: Reservation) async {
        let invocation = reservation.invocation, phase = RuntimePhase(reservation.definition, reservation.snapshot)
        let runtime = TaskRuntime(scheduler: self, invocation: invocation, phase: phase)
        if invocation.abort {
            guard let current = current(invocation.taskId), !closing else { return }
            var failure: (any Error)?
            do { try await reservation.definition.abort(current, runtime, invocation.context) } catch { failure = error }
            _ = await step(invocation) { _, _ in .fault(failure ?? SessionError.message("Abort handler of task \(invocation.taskId.rawValue) returned without a terminal outcome")) }
            return
        }
        var previous: JSONValue?, failure: (any Error)?
        while true {
            let found = await step(invocation) { tx, current in
                if current.abortRequested { return .end }
                // An owner's cancellation intent ends it too, before its cascade marks it; reservation then holds it back.
                if !current.background && belowCancelled(current.parent) {
                    state.withLock { $0.cascadePending = true }
                    scheduleReconcile()
                    return .end
                }
                guard let previous else { return .proceed }
                if let failure { return .fault(failure) }
                if jsonStructurallyEqual(current.state.checkpoint!, previous) {
                    let name = previous.objectValue?["phase"]?.stringValue ?? "undefined"
                    return .fault(SessionError.message("Task \(current.kind) phase \(name) returned without durable progress"))
                }
                let snapshot = registry.snapshot(), next = snapshot.task(name: current.kind)
                let old = phase.state.withLock { $0.definition }
                phase.state.withLock { $0.snapshot = snapshot }
                if next?.identity != old.identity {
                    if let next, next.version == current.version || (next.version > current.version && next.migrate != nil) {
                        try tx.setTask(current.replacing(state: .pending(checkpoint: current.state.checkpoint!))); return .end
                    }
                    let shouldReport = phase.state.withLock { state -> Bool in
                        if let next { if state.reported == next.identity && !state.reportedMissing { return false }; state.reported = next.identity; state.reportedMissing = false }
                        else { if state.reportedMissing { return false }; state.reported = nil; state.reportedMissing = true }
                        return true
                    }
                    if shouldReport {
                        report(TaskHandoverError(taskId: current.id, kind: current.kind, cause: next == nil ? .missingTask : .incompatibleTask),
                               taskInfo(taskId: current.id, kind: current.kind, conversationId: current.conversationId))
                    }
                }
                return .proceed
            }
            guard let found, !closing else { return }
            previous = found.state.checkpoint; failure = nil
            phase.state.withLock { $0.agent = nil }
            do { try await phase.state.withLock({ $0.definition }).run(found, runtime, invocation.context) }
            catch { failure = error }
        }
    }
}

internal extension TaskState {
    var checkpoint: JSONValue? {
        switch self {
        case .pending(let value, _), .running(let value, _), .waiting(let value, _, _, _), .sleeping(let value, _, _): value
        default: nil
        }
    }
    var outcome: TaskOutcome? { switch self { case .completing(let value, _), .terminal(let value, _): value; default: nil } }
}
internal extension TaskRecord {
    var parent: OwnershipUp { owner.map(OwnershipUp.task) ?? .conversation(conversationId) }
    /// A sleep whose `until` the clock has not reached; an abort mark ends a sleep.
    func notDue(_ now: Int64) -> Bool {
        guard case .sleeping(_, let until, _) = state else { return false }
        return !abortRequested && until > now
    }
    /// A task cut off `limit` times in a row; an abort mark still runs its abort handler.
    func parked(_ limit: Double) -> Bool {
        guard let restarts else { return false }
        return !abortRequested && Double(restarts) >= limit
    }
    var failedOutcome: Bool { state.outcome.map { $0.status != "completed" } ?? false }
    func replacing(input: JSONValue? = nil, version: Double? = nil, state: TaskState? = nil,
                   abortRequested: Bool? = nil, memos: JSONObject? = nil) -> TaskRecord {
        let next = state ?? self.state
        return TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version ?? self.version,
                          input: input ?? self.input, state: next, owner: owner, background: background,
                          abortRequested: abortRequested ?? self.abortRequested, abortReason: abortReason,
                          abandonOnRestart: abandonOnRestart, startedAt: startedAt, endedAt: endedAt, restarts: restarts,
                          memos: next.outcome == nil ? (memos ?? self.memos) : nil, extensionFields: extensionFields)
    }
    /// The record with an abort mark: `restart` for an abandonment; without a reason, a request, which replaces
    /// `restart`.
    func withAbortMark(_ reason: TaskAbortReason? = nil) -> TaskRecord {
        TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version, input: input, state: state,
                   owner: owner, background: background, abortRequested: true, abortReason: reason,
                   abandonOnRestart: abandonOnRestart, startedAt: startedAt, endedAt: endedAt, restarts: restarts,
                   memos: memos, extensionFields: extensionFields)
    }
    /// The record with `restarts` as its restart count; nil removes it.
    func withRestarts(_ restarts: Int?) -> TaskRecord {
        TaskRecord(id: id, conversationId: conversationId, kind: kind, version: version, input: input, state: state,
                   owner: owner, background: background, abortRequested: abortRequested, abortReason: abortReason,
                   abandonOnRestart: abandonOnRestart, startedAt: startedAt, endedAt: endedAt, restarts: restarts,
                   memos: memos, extensionFields: extensionFields)
    }
    /// The record without its restart count, as after a state the task committed.
    func progressed() -> TaskRecord { restarts == nil ? self : withRestarts(nil) }
}
internal func jsonStructurallyEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.object(let left), .object(let right)):
        guard left.count == right.count else { return false }
        return left.allSatisfy { key, value in right[key].map { jsonStructurallyEqual(value, $0) } ?? false }
    case (.array(let left), .array(let right)): return left.count == right.count && zip(left, right).allSatisfy { jsonStructurallyEqual($0, $1) }
    default: return lhs == rhs
    }
}
