import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Scheduler memory is bounded by live work: an ended task or a conversation edge is kept only while live work is
// below it, and a chain dropped that way is loaded again from storage when work appears below it.

private struct RetentionInput: Codable, Sendable {
    var name = ""
    /// Whether the abort handler of a held task first waits for the gate `abort.<name>`.
    var slowAbort = false
    /// The conversation a spawner or a rejected commit creates its task in.
    var into: ConversationID?
    /// The tasks a waiter waits on.
    var on: [TaskID] = []
}
private typealias RetentionTask = TaskDefinition<RetentionInput, HarnessTaskCheckpoint, Int, NoTaskHooks>

/// One test's tasks, the named gates they hold on, how often each named task started its phase, and the rejected
/// commits caught.
private struct RetentionTasks {
    let gates: HarnessHoldGates
    let runs: SessionTestLog<String>
    let rejections: SessionTestLog<String>
    /// Holds until its gate opens, then completes; its abort handler ends it `aborted`.
    let hold: RetentionTask
    /// Holds until its gate opens, then creates a held task `inside.<name>` in conversation `input.into` and ends.
    let spawner: RetentionTask
    /// Holds until `rejected` opens, then tries one terminal commit that creates a task in conversation `into` and a
    /// child of its own, which the Transaction rejects as the task is ending. Catches the rejection and holds.
    let rejected: RetentionTask
    /// Waits on the tasks in its input, then completes.
    let waiter: RetentionTask
    var all: [AnyTaskDefinition] { [hold, spawner, rejected, waiter].map(AnyTaskDefinition.init) }

    init() {
        let gates = HarnessHoldGates(), runs = SessionTestLog<String>(), rejections = SessionTestLog<String>()
        let abort: RetentionTask.Handler = { task, runtime, context in
            if task.input.slowAbort { _ = await gates.wait("abort.\(task.input.name)") }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        }
        let hold = RetentionTask(name: "test.retention.hold", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            runs.append(task.input.name)
            guard let outcome = await gates.wait(task.input.name, signal: runtime.signal) else { return }
            try await runtime.commit({ _, _ in .terminal(outcome: outcome) }, context: context)
        }, abort: abort)
        spawner = RetentionTask(name: "test.retention.spawner", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            guard await gates.wait(task.input.name, signal: runtime.signal) != nil else { return }
            try await runtime.commit({ tx, _ in
                _ = try await tx.createTask(hold, input: .init(name: "inside.\(task.input.name)"),
                                            options: .init(ownership: .conversation(), conversationId: task.input.into))
                return .terminal(outcome: .completed(result: .null))
            }, context: context)
        }, abort: abort)
        rejected = RetentionTask(name: "test.retention.rejected", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            guard await gates.wait("rejected", signal: runtime.signal) != nil else { return }
            do {
                try await runtime.commit({ tx, _ in
                    _ = try await tx.createTask(hold, input: .init(name: "staged"),
                                                options: .init(ownership: .conversation(), conversationId: task.input.into))
                    _ = try await tx.createTask(hold, input: .init(name: "child"), options: .init(ownership: .task(taskId: task.id)))
                    return .terminal(outcome: .completed(result: .null))
                }, context: context)
            } catch {
                rejections.append(String(describing: error))
            }
            // Holds until aborted: this gate never opens.
            _ = await gates.wait("rejected.held", signal: runtime.signal)
        }, abort: abort)
        waiter = RetentionTask(name: "test.retention.waiter", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ _, _ in
                    .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: task.input.on, policy: .allSettled)
                }, context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }, abort: abort)
        self.gates = gates; self.runs = runs; self.rejections = rejections; self.hold = hold
    }
}

/// Sizes of the scheduler's ownership indexes, as upstream's `SCHEDULER_INDEX_SIZES` getter reports them.
private struct IndexSizes: Equatable {
    var live = 0, settled = 0, edges = 0, below = 0, roots = 0, unloaded = 0, dropQueue = 0
}
private func sizes(_ harness: Harness) -> IndexSizes {
    harness.tasks.state.withLock { state in
        IndexSizes(live: state.live.count, settled: state.settled.count, edges: state.edges.count,
                   below: state.below.values.reduce(0) { $0 + $1.count }, roots: state.roots.count,
                   unloaded: state.unloaded.count, dropQueue: state.dropQueue.count)
    }
}

/// Counts the task reads and the scans of queued submissions a storage serves; `onConversationRead` runs before each
/// conversation read.
private final class CountingStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    private let counts = Mutex<(tasks: Int, queuedScans: Int)>((0, 0))
    private let conversationRead = Mutex<(@Sendable (ConversationID) async -> Void)?>(nil)
    init(_ base: any DurableStorage) { self.base = base }
    var taskReads: Int { counts.withLock { $0.tasks } }
    var queuedScans: Int { counts.withLock { $0.queuedScans } }
    func onConversationRead(_ read: @escaping @Sendable (ConversationID) async -> Void) { conversationRead.withLock { $0 = read } }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq { try await base.commit(writes, context: context) }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { try await base.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        await conversationRead.withLock { $0 }?(id)
        return try await base.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? { try await base.entry(id, context: context) }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        counts.withLock { $0.tasks += 1 }
        return try await base.task(id, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? { try await base.submission(id, context: context) }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        if query.status == .queued { counts.withLock { $0.queuedScans += 1 } }
        return try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await base.findDocument(address, at: at, context: context)
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await base.document(id, at: at, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws { try await base.close(context: context) }
}

/// An opened Harness over `tasks`, with its root conversation, scheduling running.
private struct Retention {
    let harness: Harness
    let root: Conversation
    let tasks: RetentionTasks
    var gates: HarnessHoldGates { tasks.gates }
}
private func open(_ storage: any DurableStorage, _ tasks: RetentionTasks = RetentionTasks()) async throws -> Retention {
    let harness = try await openTasks(storage: storage, tasks: tasks.all).harness
    let root = try await harness.root(context: .background)
    try harness.resume()
    return Retention(harness: harness, root: root, tasks: tasks)
}
/// Runs `body` with the path of a fresh SQLite file, removing its directory afterwards.
private func withSqlitePath(_ body: (String) async throws -> Void) async throws {
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("session.sqlite").path)
}
private extension Transaction {
    func hold(_ tasks: RetentionTasks, _ name: String, owner: TaskID? = nil, in conversation: ConversationID? = nil,
              background: Bool = false, slowAbort: Bool = false) async throws -> TaskID {
        try await createTask(tasks.hold, input: .init(name: name, slowAbort: slowAbort),
                             options: .init(ownership: owner.map { .task(taskId: $0) } ?? .conversation(), conversationId: conversation, background: background))
    }
    func conversation(ownedBy owner: TaskID) async throws -> ConversationID { try await createConversation(ownership: .task(taskId: owner)).id }
}
private func status(_ harness: Harness, _ id: TaskID) async throws -> String? { try await harness.getTask(id: id, context: .background)?.state.status }
private func outcome(_ harness: Harness, _ id: TaskID) async throws -> String { try await harness.waitForTask(id: id, context: .background).outcome.status }

/// Under live `parent`: tool task T owning conversation C, a task in C; all of them end. Returns C.
@discardableResult
private func subagentCycle(_ opened: Retention, parent: TaskID, _ n: Int) async throws -> ConversationID {
    let tasks = opened.tasks
    let ids = try await opened.root.commit({ tx in
        let tool = try await tx.hold(tasks, "tool\(n)", owner: parent)
        let child = try await tx.conversation(ownedBy: tool)
        return (tool: tool, inner: try await tx.hold(tasks, "inner\(n)", in: child), child: child)
    }, context: .background)
    opened.gates.open("inner\(n)")
    opened.gates.open("tool\(n)")
    _ = try await opened.harness.waitForTask(id: ids.inner, context: .background)
    _ = try await opened.harness.waitForTask(id: ids.tool, context: .background)
    return ids.child
}

/// Port of upstream `test/harness-scheduler-retention.test.ts` (`ea448f454`). The index sizes are read from the
/// scheduler's `State` instead of upstream's `SCHEDULER_INDEX_SIZES` getter.
@Suite struct HarnessSchedulerRetentionTests {
    @Test func forgetsEndedSubagentChainsOnceTheirWorkEnds() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let parent = try await opened.root.commit({ tx in try await tx.hold(opened.tasks, "parent") }, context: .background)
            try await subagentCycle(opened, parent: parent, 0)
            let baseline = sizes(opened.harness)
            for n in 1...200 { try await subagentCycle(opened, parent: parent, n) }
            #expect(sizes(opened.harness) == baseline)
            opened.gates.open("parent")
            _ = try await opened.harness.waitForTask(id: parent, context: .background)
            try await opened.harness.close(context: .background)
        }
    }

    @Test func holdsALiveOwnerForWorkLaterCreatedInAForgottenConversationLoadingItsChainAgain() async throws {
        try await withSqlitePath { path in
            let storage = CountingStorage(try await SqliteStorage.open(path: path))
            let opened = try await open(storage)
            let harness = opened.harness, tasks = opened.tasks
            // Live P -> ended B -> ended A -> conversation C, empty: forgotten.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.hold(tasks, "p")
                let b = try await tx.hold(tasks, "b", owner: p)
                let a = try await tx.hold(tasks, "a", owner: b)
                return (p: p, b: b, a: a, c: try await tx.conversation(ownedBy: a))
            }, context: .background)
            opened.gates.open("a")
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let before = sizes(harness)
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            // Upstream counts task and conversation reads from before the handle, which reads C itself. Here only the
            // task reads until the chain is loaded: the creating commit reads none, the chain load reads A and B again.
            let loaded = storage.taskReads
            let d = try await c.commit({ tx in try await tx.hold(tasks, "d") }, context: .background)
            try await eventually { harnessReconciled(harness) && harness.tasks.state.withLock { !$0.unloaded.contains(d) } }
            #expect(storage.taskReads > loaded)
            opened.gates.open("p")
            try await eventually { try await status(harness, tree.p) == "completing" }
            opened.gates.open("d")
            #expect(try await outcome(harness, d) == "completed")
            #expect(try await outcome(harness, tree.p) == "completed")
            #expect(sizes(harness).settled <= before.settled)
            try await harness.close(context: .background)
        }
    }

    @Test func holdsAnOwnerForWorkItsOwnTerminalCommitCreatesBelowAForgottenChain() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            // Live P (a spawner) -> ended B -> ended A -> conversation C, empty: forgotten. P's terminal commit creates D in C.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.createTask(tasks.spawner, input: .init(name: "p"), options: .init(ownership: .conversation()))
                let b = try await tx.hold(tasks, "b", owner: p)
                let a = try await tx.hold(tasks, "a", owner: b)
                return (p: p, b: b, c: try await tx.conversation(ownedBy: a))
            }, context: .background)
            // Point the spawner at C, now that its ID is known.
            try await opened.root.commit({ tx in
                let record = try #require(await tx.task(tree.p))
                try tx.setTask(record.replacing(input: JSONValue(encoding: RetentionInput(name: "p", into: tree.c))))
            }, context: .background)
            opened.gates.open("a")
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            opened.gates.open("p")
            try await eventually { try await status(harness, tree.p) != "running" }
            #expect(try await status(harness, tree.p) == "completing")
            opened.gates.open("inside.p")
            #expect(try await outcome(harness, tree.p) == "completed")
            try await harness.close(context: .background)
        }
    }

    @Test func withdrawsAnInputQueuedInAForgottenConversationBelowAnAbortMarkedOwner() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            // Live P -> ended B -> conversation C with no task; C gets a queued input while P is cancelling.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.hold(tasks, "p")
                let b = try await tx.hold(tasks, "b", owner: p)
                let c = try await tx.conversation(ownedBy: b)
                // A live child keeps P holding its abort until the input is withdrawn and the child ends.
                return (p: p, b: b, c: c, keep: try await tx.hold(tasks, "keep", owner: p))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            // Busy, so the input queues instead of starting a run.
            try await c.commit({ tx in
                try await tx.doc(LiveDoc, conversationId: tree.c).set("run", JSONValue(encoding: LiveRun(taskId: tree.keep, inputs: [])))
            }, context: .background)
            let queued = try await c.submit(.input(content: .text("later")), context: .background)
            _ = try await harness.abortTask(id: tree.p, context: .background)
            try await eventually { try await queued.status(context: .background).status == "unanswered" }
            #expect(try await queued.wait(context: .background).reason == "aborted")
            _ = try await harness.waitForTask(id: tree.p, context: .background)
            try await harness.close(context: .background)
        }
    }

    @Test func abortsWorkCreatedInAForgottenConversationBelowAnAbortMarkedOwnerBeforeItRuns() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            // `keep` ends only once its abort gate opens: threads could otherwise end it, and P with it, before `late`.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.hold(tasks, "p")
                let b = try await tx.hold(tasks, "b", owner: p)
                let c = try await tx.conversation(ownedBy: b)
                return (p: p, b: b, c: c, keep: try await tx.hold(tasks, "keep", owner: p, slowAbort: true))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            // P cancels; its live child keeps it holding.
            try await harness.commit({ tx in
                let record = try #require(await tx.task(tree.p))
                try tx.setTask(record.replacing(abortRequested: true))
            }, context: .background)
            try await eventually { try await harness.getTask(id: tree.keep, context: .background)?.abortRequested == true }
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            let late = try await c.commit({ tx in try await tx.hold(tasks, "late") }, context: .background)
            #expect(try await outcome(harness, late) == "aborted")
            #expect(!opened.tasks.runs.values.contains("late"))
            opened.gates.open("abort.keep")
            try await harness.close(context: .background)
        }
    }

    @Test func keepsAScopeBusyWhileTheChainOfNewWorkBelowAForgottenConversationLoads() async throws {
        try await withSqlitePath { path in
            let storage = CountingStorage(try await SqliteStorage.open(path: path))
            let opened = try await open(storage)
            let harness = opened.harness, tasks = opened.tasks
            let tree = try await opened.root.commit({ tx in
                let b = try await tx.hold(tasks, "b")
                return (b: b, c: try await tx.conversation(ownedBy: b))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            // Hold the chain load's read of C: the second read from here, after the creating commit's own.
            let reached = HarnessChatSignal(), held = HarnessChatSignal(), readsOfC = Mutex(0)
            storage.onConversationRead { id in
                guard id == tree.c, readsOfC.withLock({ $0 += 1; return $0 }) == 2 else { return }
                reached.signal()
                await held.wait()
            }
            let d = try await c.commit({ tx in try await tx.hold(tasks, "d") }, context: .background)
            // Polled, not awaited: without a chain load the held read never comes, and the deadline fails the test.
            try await eventually { reached.isSignalled }
            // D's chain is not loaded yet, so it counts as inside every scope; the wait queues behind the load.
            #expect(!harness.tasks.idle(nil) && !harness.tasks.idle(opened.root.id))
            let idle = settled { try await harness.waitForIdle(context: .background) }
            await Task.yield()
            #expect(!idle.isSettled)
            held.signal()
            opened.gates.open("d")
            _ = try await harness.waitForTask(id: d, context: .background)
            try await harness.waitForIdle(context: .background)
            try await eventually { idle.isSettled }
            try await harness.close(context: .background)
        }
    }

    @Test func keepsAChainWhenOneCommitEndsItsLastTaskAndCreatesNewWorkBelowIt() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            // Live P -> ended B -> conversation C with background task `old`, which keeps the chain known without holding B.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.hold(tasks, "p")
                let b = try await tx.hold(tasks, "b", owner: p)
                let c = try await tx.conversation(ownedBy: b)
                return (p: p, b: b, c: c, old: try await tx.hold(tasks, "old", in: c, background: true))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            // One commit: the old task ends, which leaves nothing live below B, and a replacement starts in C.
            let replacement = try await harness.commit({ tx in
                let old = try #require(await tx.task(tree.old))
                let id = try await tx.hold(tasks, "new", in: tree.c)
                try tx.setTask(old.replacing(state: .terminal(outcome: .completed(result: .null))))
                return id
            }, context: .background)
            // The chain stayed known through the publication, so P holds for the replacement.
            opened.gates.open("p")
            try await eventually { try await status(harness, tree.p) == "completing" }
            opened.gates.open("new")
            _ = try await harness.waitForTask(id: replacement, context: .background)
            #expect(try await outcome(harness, tree.p) == "completed")
            try await harness.close(context: .background)
        }
    }

    @Test func dropsWhatARejectedCommitsChainLoadReadWithoutALaterPublication() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            // Live P owns ended B, which owns conversation C: forgotten. P's terminal commit stages work in C, which loads
            // C's chain, and a child of P, which the Transaction rejects, as P is ending.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.createTask(tasks.rejected, input: .init(), options: .init(ownership: .conversation()))
                let b = try await tx.hold(tasks, "b", owner: p)
                return (p: p, b: b, c: try await tx.conversation(ownedBy: b))
            }, context: .background)
            try await opened.root.commit({ tx in
                let record = try #require(await tx.task(tree.p))
                try tx.setTask(record.replacing(input: JSONValue(encoding: RetentionInput(into: tree.c))))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let baseline = sizes(harness)
            opened.gates.open("rejected")
            try await eventually { tasks.rejections.count > 0 }
            // The rejected commit published nothing; the sweep job still cleans up what its chain load read.
            try await eventually { sizes(harness).dropQueue == 0 }
            #expect(sizes(harness) == baseline)
            try await harness.close(context: .background)
        }
    }

    @Test func dropsWhatAReadLoadedAfterReopenWithoutALaterPublication() async throws {
        try await withSqlitePath { path in
            var opened = try await open(SqliteStorage.open(path: path))
            let tasks = opened.tasks
            // A live task D in conversation C, owned by ended B: after reopen D's chain is not loaded.
            let tree = try await opened.root.commit({ tx in
                let b = try await tx.hold(tasks, "b")
                let c = try await tx.conversation(ownedBy: b)
                return (b: b, d: try await tx.hold(tasks, "d", in: c))
            }, context: .background)
            opened.gates.open("b")
            try await eventually { [harness = opened.harness] in try await status(harness, tree.b) == "completing" }
            try await opened.harness.close(context: .background)
            opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness
            _ = try await harness.inspect(context: .background)
            // D is still live, so its chain stays; once D ends, everything below the root goes, published or not.
            #expect(sizes(harness).unloaded == 0)
            opened.gates.open("d")
            _ = try await harness.waitForTask(id: tree.d, context: .background)
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            try await eventually { sizes(harness).dropQueue == 0 }
            let ended = sizes(harness)
            #expect(ended.settled == 0 && ended.below == 0 && ended.unloaded == 0)
            try await harness.close(context: .background)
        }
    }

    @Test func withdrawsAnInputQueuedTwoEndedLevelsBelowAnOwnerWhoseIntentAppearsLater() async throws {
        try await withSqlitePath { path in
            let storage = CountingStorage(try await SqliteStorage.open(path: path))
            let opened = try await open(storage)
            let harness = opened.harness, tasks = opened.tasks
            // Live P -> ended B -> ended A -> conversation C with no task, and a live child keeping P holding.
            let tree = try await opened.root.commit({ tx in
                let p = try await tx.hold(tasks, "p")
                let b = try await tx.hold(tasks, "b", owner: p)
                let a = try await tx.hold(tasks, "a", owner: b)
                let c = try await tx.conversation(ownedBy: a)
                return (p: p, b: b, c: c, keep: try await tx.hold(tasks, "keep", owner: p))
            }, context: .background)
            opened.gates.open("a")
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            try await c.commit({ tx in
                try await tx.doc(LiveDoc, conversationId: tree.c).set("run", JSONValue(encoding: LiveRun(taskId: tree.keep, inputs: [])))
            }, context: .background)
            try await eventually { harnessReconciled(harness) }
            let scans = storage.queuedScans
            // Queued while nothing cancels: no withdrawal scan, though C's chain is not known.
            let queued = try await c.submit(.input(content: .text("later")), context: .background)
            try await eventually { sizes(harness).dropQueue == 0 }
            try await Task.sleep(for: .milliseconds(20))
            #expect(storage.queuedScans == scans)
            // P fails while its child runs: it holds the failed outcome, which is cancellation intent.
            try await harness.commit({ tx in
                let record = try #require(await tx.task(tree.p))
                try tx.setTask(record.replacing(state: .completing(outcome: .failed(error: TaskOutcomeError(message: "x")))))
            }, context: .background)
            try await eventually { try await queued.status(context: .background).status == "unanswered" }
            #expect(try await queued.wait(context: .background).reason == "aborted")
            try await harness.close(context: .background)
        }
    }

    @Test func forgetsADeepChainOfEndedTasksWithoutRecursion() async throws {
        // Upstream runs 20,000 tasks; here 2,000, as in `tracksOwnershipChainsDeeperThanTheCallStack`: the commit that
        // finalizes the whole chain checks each terminal task against the transaction's created tasks, linear each, so
        // 20,000 take minutes outside the scheduler. The State-level case there holds the sweep to 20,000.
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            let depth = 2_000
            let baseline = sizes(harness)
            let tree = try await opened.root.commit({ tx in
                var links: [TaskID] = []
                var owner = try await tx.hold(tasks, "link0")
                links.append(owner)
                for n in 1..<depth {
                    owner = try await tx.hold(tasks, "link\(n)", owner: owner)
                    links.append(owner)
                }
                return (links: links, leaf: try await tx.hold(tasks, "leaf", owner: owner))
            }, context: .background)
            for n in 0..<depth { opened.gates.open("link\(n)") }
            opened.gates.open("leaf")
            _ = try await harness.waitForTask(id: tree.leaf, context: .background)
            _ = try await harness.waitForTask(id: tree.links[0], context: .background)
            try await harness.waitForIdle(context: .background)
            #expect(sizes(harness) == baseline)
            try await harness.close(context: .background)
        }
    }

    @Test func keepsNoMoreAfterAllWorkEndedThanAFreshReopen() async throws {
        try await withSqlitePath { path in
            var opened = try await open(SqliteStorage.open(path: path))
            let parent = try await opened.root.commit({ [tasks = opened.tasks] tx in try await tx.hold(tasks, "parent") }, context: .background)
            for n in 0..<20 { try await subagentCycle(opened, parent: parent, n) }
            opened.gates.open("parent")
            _ = try await opened.harness.waitForTask(id: parent, context: .background)
            try await opened.harness.waitForIdle(context: .background)
            let ended = sizes(opened.harness)
            try await opened.harness.close(context: .background)
            opened = try await open(SqliteStorage.open(path: path))
            try await opened.harness.waitForIdle(context: .background)
            #expect(ended == sizes(opened.harness))
            try await opened.harness.close(context: .background)
        }
    }

    @Test func doesNotScanQueuedSubmissionsForAnInputWhenNothingCancels() async throws {
        try await withSqlitePath { path in
            let storage = CountingStorage(try await SqliteStorage.open(path: path))
            let opened = try await open(storage)
            let harness = opened.harness, root = opened.root
            let busy = try await root.commit({ [tasks = opened.tasks] tx in try await tx.hold(tasks, "busy") }, context: .background)
            try await root.commit({ tx in
                try await tx.doc(LiveDoc, conversationId: root.id).set("run", JSONValue(encoding: LiveRun(taskId: busy, inputs: [])))
            }, context: .background)
            try await eventually { harnessReconciled(harness) }
            let before = storage.queuedScans
            _ = try await root.submit(.input(content: .text("queued")), context: .background)
            // Let any reconcile it would cause run.
            try await Task.sleep(for: .milliseconds(20))
            #expect(storage.queuedScans == before)
            opened.gates.open("busy")
            try await harness.close(context: .background)
        }
    }

    @Test func stillRejectsWaitingOnAForgottenEndedOwner() async throws {
        try await withSqlitePath { path in
            let opened = try await open(SqliteStorage.open(path: path))
            let harness = opened.harness, tasks = opened.tasks
            let tree = try await opened.root.commit({ tx in
                let b = try await tx.hold(tasks, "b")
                return (b: b, c: try await tx.conversation(ownedBy: b))
            }, context: .background)
            opened.gates.open("b")
            _ = try await harness.waitForTask(id: tree.b, context: .background)
            let c = try #require(try await harness.conversation(id: tree.c, context: .background))
            let waiter = try await c.commit({ tx in
                try await tx.createTask(tasks.waiter, input: .init(on: [tree.b]), options: .init(ownership: .conversation()))
            }, context: .background)
            let settled = try await harness.waitForTask(id: waiter, context: .background)
            guard case .faulted(let error, _) = settled.outcome else { Issue.record("Waiter must fault, got \(settled.outcome)"); return }
            #expect(error.message.contains("cannot wait on itself or its owner"))
            try await harness.close(context: .background)
        }
    }
}
