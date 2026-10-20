import Foundation
import PiSwiftChord
import Synchronization

private struct WeakHarness: Sendable { weak var value: Harness? }

private final class HarnessSessionHooks: SessionHooks {
    let scheduler = Mutex<TaskScheduler?>(nil)
    let app: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?
    let onReport: @Sendable (any Error, ReportInfo) -> Void
    init(app: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?, onReport: @escaping @Sendable (any Error, ReportInfo) -> Void) {
        self.app = app; self.onReport = onReport
    }
    /// The Session's failure, once, and listener errors go to `onReport`, the last place an error goes.
    func report(_ error: any Error, info: ReportInfo) { onReport(error, info) }
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {
        _ = try await tx.doc(LiveDoc, conversationId: record.id)
        _ = try await tx.doc(InboxDoc, conversationId: record.id)
        _ = try await tx.doc(UsageDoc, conversationId: record.id)
        _ = try await tx.doc(ProviderDoc, conversationId: record.id)
        try await createAgent(tx: tx, conversation: record)
        try await app?(tx, record)
    }
    func beforeClose() async {
        let tasks = scheduler.withLock { state in let tasks = state; state = nil; return tasks }
        await tasks?.join()
    }
}

/// Durable task service over one Session. Reads do not start task scheduling.
public final class Harness: Sendable {
    internal let session: Session
    internal let storage: any DurableStorage
    internal let options: HarnessOptions
    internal let tasks: TaskScheduler
    internal let submissions: Submissions
    internal let views: ConversationViews
    internal let graph: TaskGraphView
    private let closing = Mutex(false)
    private init(session: Session, storage: any DurableStorage, options: HarnessOptions,
                 tasks: TaskScheduler, submissions: Submissions) throws {
        self.session = session; self.storage = storage; self.options = options; self.tasks = tasks; self.submissions = submissions
        self.views = try ConversationViews(session: session, storage: storage)
        self.graph = try TaskGraphView(session: session, storage: storage, blocking: TaskGraphBlocking(
            blocked: { [tasks] in tasks.blockedReason($0) }, subscribeBlocked: { [tasks] in tasks.subscribeBlocked($0) }))
    }
    /// Opens the session and restores runnable task state with scheduling paused.
    public static func open(storage rawStorage: any DurableStorage, options: HarnessOptions,
                            context: ChordContext) async throws -> Harness {
        try await withTaskCancellationContext(context) { context in
            try context.abortSignal?.throwIfAborted()
            let snapshot = options.registry.snapshot()
            let missing = ["pi.generation", "pi.tool", "pi.compaction"].filter { snapshot.task(name: $0) == nil }
            if !missing.isEmpty { throw HarnessOpenError.missingBuiltins(missing) }
            let report: @Sendable (any Error, ReportInfo) -> Void = options.onReport ?? { _, _ in }
            let hooks = HarnessSessionHooks(app: options.conversationCreated, onReport: report)
            let now = options.now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
            // Read at each use, as all settings are, but only this field: it is read on every commit.
            let session = Session(storage: rawStorage, now: now, hooks: hooks,
                                  documentRetention: { options.settings?.documentRetentionMs }, setTimer: options.setTimer)
            // Every component reads and writes through the Session's failure guard: `rawStorage` serves only the Session.
            let storage = session.storage
            let settings: @Sendable () -> Settings = { options.settings?.resolve() ?? resolveSettings() }
            let reference = Mutex(WeakHarness())
            let scheduler = TaskScheduler(session: session, registry: options.registry, models: options.currentModels,
                now: now, onWake: options.onWake, timers: hostTimers(options.setTimer, report: { report($0, ReportInfo(source: .timer)) }),
                settings: settings,
                agent: { id, snapshot, callContext in
                    let state = try await session.snapshot(AgentDoc, conversationId: id, context: callContext)
                    return resolveAgent(state: state, snapshot: snapshot, settings: settings(),
                                        report: { report($0, ReportInfo(source: .extension, conversationId: id)) })
                }, env: { id, callContext in
                    guard let build = options.env else { return nil }
                    let cwd = try await session.snapshot(AgentDoc, conversationId: id, context: callContext)?.cwd
                    return try await build(EnvTarget(conversationId: id, cwd: cwd, read: documentReader(session: session, storage: storage)), callContext)
                }, conversation: { id, binding, callContext in
                    let found = try await session.readOnLine { try await storage.conversation(id, context: callContext) }
                    guard found != nil else { return nil }
                    guard let harness = reference.withLock({ $0.value }) else { throw closedError(session) }
                    return ConversationHandle(Conversation(id: id, harness: harness, binding: binding))
                }, report: report, context: context.withoutAbortSignal(),
                settleOutcome: { tx, record, outcome in try await settleSchedulerOutcome(tx: tx, record: record, outcome: outcome) },
                withdrawInputs: { tx, id in try await withdrawQueuedInputs(tx: tx, conversationId: id) })
            hooks.scheduler.withLock { $0 = scheduler }
            let submissions = try Submissions(session: session, storage: storage, now: now, settings: settings, resume: { scheduler.resume() })
            let harness = try Harness(session: session, storage: storage, options: options, tasks: scheduler, submissions: submissions)
            reference.withLock { $0.value = harness }
            do { try await scheduler.open(context: context) }
            catch {
                // The caller's context may be what failed open: close without it, and rethrow the open error. A failing
                // Storage close fails the Session, which reports it.
                try? await harness.close(context: context.withoutAbortSignal())
                throw error
            }
            return harness
        }
    }
    /// Throw `SessionFailed` after a failure, else an error once closing.
    internal func assertOpen() throws {
        try session.assertHealthy()
        if closing.withLock({ $0 }) || session.isClosing { throw closedError(session) }
    }
    /// Starts task scheduling after a harness is opened or paused, and makes sleeping tasks whose time has come runnable,
    /// which is how a host wakeup resumes them.
    public func resume() throws { try assertOpen(); tasks.resume() }
    /// When this Session next needs a running process, from the scheduler's memory: `active` while some task can run now
    /// or is running, `at` for the earliest sleep. Answers also while scheduling is paused. A host that wakes the process
    /// itself arms from it and calls `resume()` when woken; see `HarnessOptions.onWake`.
    public func wake() throws -> Wake { try assertOpen(); return tasks.wake() }
    /// Releases this object's resources and rejects later operations.
    public func close(context: ChordContext) async throws {
        closing.withLock { $0 = true }
        try await withTaskCancellationContext(context) { try await session.close(context: $0) }
    }
    /// Settles once the Harness has closed, by `close()` or after a storage error, Storage included: `.closed`, or
    /// `.failed(error)`. A failure closes the Harness by itself; `closed` settles once that close is done, even if the
    /// storage could not close cleanly. Closing waits for running task code to return.
    public var closed: SessionEnd { get async { await session.closed } }
    /// Commits the supplied changes atomically and publishes them after storage succeeds. Inside the callback read only
    /// through `tx`: `snapshot`, `documentState`, `watchDoc`, `getTask`, and the other Session and runtime reads may
    /// queue on the line the callback holds, and then never return.
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await session.commit(change, context: context)
        }
    }
    /// Adds a listener on the session mutation line after commit adoption; it must not call session operations. A throw is
    /// reported through `onReport`, and the other listeners still run.
    public func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) throws -> Void) throws -> SessionSubscription {
        try assertOpen(); return try session.subscribeCommits(listener)
    }
    /// Adds a listener called when close seals session admission, also when a failure closes the session; it must not
    /// call session operations. A throw is reported through `onReport`, and the other listeners still run.
    public func subscribeClose(_ listener: @escaping @Sendable () throws -> Void) throws -> SessionSubscription {
        try assertOpen(); return try session.subscribeClose(listener)
    }
    /// Returns the root conversation, creating and initializing it when absent.
    public func root(options: ConversationRootOptions = .init(), context: ChordContext) async throws -> Conversation {
        try await create(.root, agent: options.agent, initialize: options.initialize, context: context)
    }
    /// Creates a conversation with the supplied ownership and optional configuration.
    public func createConversation(options: ConversationCreateOptions, context: ChordContext) async throws -> Conversation {
        try await create(.independent(options.ownership), agent: options.agent, initialize: options.initialize, context: context)
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(id: ConversationID, context: ChordContext) async throws -> Conversation? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            let record = try await session.readOnLine { try await storage.conversation(id, context: context) }
            return record.map { Conversation(id: $0.id, harness: self) }
        }
    }
    internal enum CreateTarget { case root, independent(ConversationOwnership), fork(ConversationID, EntryID, ConversationOwnership) }
    internal func create(_ target: CreateTarget, agent: AgentChange?, initialize: ConversationInit?, context: ChordContext) async throws -> Conversation {
        try await withTaskCancellationContext(context) { context in
            try assertOpen()
            let id = try await session.commit({ tx in
                if case .root = target, try await tx.conversation(rootConversationID) != nil { return rootConversationID }
                let record: ConversationRecord
                switch target {
                case .root: record = try await tx.createRootConversation()
                case .independent(let ownership): record = try await tx.createConversation(ownership: ownership)
                case let .fork(parent, at, ownership): record = try await tx.forkConversation(parent, at: at, ownership: ownership)
                }
                if let agent { try await configure(tx: tx, conversationId: record.id, change: agent) }
                try await initialize?(tx, record.id)
                return record.id
            }, context: context)
            return Conversation(id: id, harness: self)
        }
    }
    /// Returns the current durable task record, or nil when it is absent.
    public func getTask(id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await session.readOnLine { try await storage.task(id, context: context) }
        }
    }
    /// Returns scheduling, task definition, and submission state for host inspection.
    public func inspect(context: ChordContext) async throws -> HarnessInspection {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            return try await session.readOnLine {
                let inspection = try await tasks.inspect(snapshot: options.registry.snapshot())
                var records: [SubmissionRecord] = []
                for status in [SubmissionStatus.queued, .placed] {
                    records += try await scanAll { try await storage.scanSubmissions(.init(status: status), limit: 256, cursor: $0, context: context) }
                }
                return HarnessInspection(scheduling: inspection.scheduling, tasks: inspection.tasks, submissions: records.sorted { $0.id < $1.id })
            }
        }
    }
    /// Marks a nonterminal task for its definition's abort handler.
    public func abortTask(id: TaskID, context: ChordContext) async throws -> TaskAbortResult {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); return try await tasks.abort(id: id, context: context)
        }
    }
    /// Run a task parked by `settings.restartLimit` again: clears its restart count and enables scheduling. Does nothing
    /// for a task that is not parked; throws for an unknown one.
    public func retryTask(id: TaskID, context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try await tasks.retry(id: id, context: context)
        }
    }
    /// Waits for a terminal task outcome and returns its durable receipt.
    public func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); tasks.resume(); return try await tasks.waitForTask(id: id, context: context)
        }
    }
    /// Waits until all ordinary scheduled work is idle across the harness.
    public func waitForIdle(context: ChordContext) async throws {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); tasks.resume(); try await tasks.waitForIdle(conversationId: nil, context: context)
        }
    }
    /// Sums current model and tool usage across all stored conversations.
    public func usage(context: ChordContext) async throws -> UsageState {
        try await withTaskCancellationContext(context) { context in
            try assertOpen(); try context.abortSignal?.throwIfAborted()
            let conversations = try await session.readOnLine {
                try await scanAll { try await storage.scanConversations(.init(), limit: 256, cursor: $0, context: context) }
            }
            let reader = documentReader(session: session, storage: storage)
            var total = UsageState()
            for conversation in conversations {
                if let raw = try await reader.snapshot("pi.usage", conversation.id, context) {
                    let value = try JSONValue.object(raw).decode(UsageState.self)
                    addUsageState(sum: &total, state: value)
                }
            }
            return total
        }
    }
    internal func resolveConversationAgent(id: ConversationID, context: ChordContext) async throws -> Agent {
        try assertOpen(); try context.abortSignal?.throwIfAborted()
        let value = try await session.snapshot(AgentDoc, conversationId: id, context: context)
        let report = options.onReport ?? { _, _ in }
        return resolveAgent(state: value, snapshot: options.registry.snapshot(), settings: options.settings?.resolve() ?? resolveSettings(),
                            report: { report($0, ReportInfo(source: .extension, conversationId: id)) })
    }
}
/// The harness cannot use the supplied registry to load its built-in tasks.
public enum HarnessOpenError: Error, Sendable, CustomStringConvertible {
    /// The registry does not contain the required built-in task definitions.
    case missingBuiltins([String])
    /// Text that describes this value or error to the caller.
    public var description: String {
        switch self { case .missingBuiltins(let names): "Registry lacks built-in tasks \(names.joined(separator: ", ")); create it with createRegistry()" }
    }
}

internal func documentReader(session: Session, storage: any DurableStorage) -> HarnessDocumentReader {
    HarnessDocumentReader(snapshot: { kind, id, context in
        try await session.readOnLine {
            let scope: DocumentScope = id.map { .conversation(conversationId: $0) } ?? .session()
            guard let record = try await storage.findDocument(DocumentAddress(kind: kind, scope: scope), at: .current, context: context) else { return nil }
            return try await storage.document(record.id, at: .current, context: context)?.value
        }
    }, snapshotAsOf: { kind, id, at, context in
        try await session.readOnLine {
            guard let entry = try await storage.entry(id, id: at, context: context) else {
                throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(id.rawValue)")
            }
            let address = DocumentAddress(kind: kind, scope: .conversation(conversationId: entry.entry.conversationId))
            guard let record = try await storage.findDocument(address, at: .sequence(entry.commitSeq), context: context) else { return nil }
            return try await storage.document(record.id, at: .sequence(entry.commitSeq), context: context)?.value
        }
    }, typedRead: { definition, address, context in
        try await session.currentSnapshot(definition, address: address, context: context)
    }, typedHistoricalRead: { definition, address, at, context in
        try await session.historicalSnapshot(definition, address: address, at: at, context: context)
    })
}
