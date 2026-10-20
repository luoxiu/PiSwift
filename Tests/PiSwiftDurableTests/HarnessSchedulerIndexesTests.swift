import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Reports every commit's writes before they reach storage and, while a conversation is held, holds its record's reads.
private final class ObservedStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    private let commits = Mutex<(@Sendable ([StorageWrite]) -> Void)?>(nil)
    private let held = Mutex<(id: ConversationID, reading: HarnessChatSignal, release: HarnessChatSignal)?>(nil)
    init(_ base: any DurableStorage) { self.base = base }
    func onCommit(_ observe: @escaping @Sendable ([StorageWrite]) -> Void) { commits.withLock { $0 = observe } }
    func hold(_ id: ConversationID, reading: HarnessChatSignal, until release: HarnessChatSignal) {
        held.withLock { $0 = (id, reading, release) }
    }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        commits.withLock { $0 }?(writes)
        return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { try await base.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        if let held = held.withLock({ $0 }), held.id == id {
            held.reading.signal()
            await held.release.wait()
        }
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
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? { try await base.task(id, context: context) }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? { try await base.submission(id, context: context) }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
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

/// Port of upstream `test/harness-scheduler-indexes.test.ts`: the scheduler's in-memory indexes, in cases where a wrong
/// index changes behaviour, each against what the committed records imply (spec §5.4, §5.5).
@Suite struct HarnessSchedulerIndexesTests {
    @Test func takesACascadesReasonFromTheNearestCancellingOwner() async throws {
        // top (abort requested) -> middle (restart-marked) -> leaf: the leaf gets middle's `restart` first, as the nearest
        // cancelling owner, and the request only once middle carries it.
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let hold = harnessHold(HarnessHoldGates())
        let session = try await Session.open(storage: SqliteStorage.open(path: path), context: .background)
        let ids = try await session.commit({ tx in
            let conversation = try await tx.createConversation(ownership: .ownerless()).id
            let top = try await tx.createTask(hold, input: .init(name: "top"), options: .init(ownership: .conversation(), conversationId: conversation))
            let middle = try await tx.createTask(hold, input: .init(name: "middle"), options: .init(ownership: .task(taskId: top)))
            let leaf = try await tx.createTask(hold, input: .init(name: "leaf"), options: .init(ownership: .task(taskId: middle)))
            return (top: top, middle: middle, leaf: leaf)
        }, context: .background)
        try await session.commit({ tx in
            let top = try #require(await tx.task(ids.top)), middle = try #require(await tx.task(ids.middle))
            try tx.setTask(top.withAbortMark())
            try tx.setTask(middle.withAbortMark(.restart))
        }, context: .background)
        try await session.close(context: .background)
        // Record every mark of the leaf, in commit order.
        let storage = ObservedStorage(try await SqliteStorage.open(path: path))
        let reasons = SessionTestLog<TaskAbortReason?>()
        storage.onCommit { writes in
            for case .task(let record, _) in writes where record.id == ids.leaf && record.abortRequested { reasons.append(record.abortReason) }
        }
        let harness = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(hold)]).harness
        try harness.resume()
        for id in [ids.leaf, ids.middle, ids.top] { _ = try await harness.waitForTask(id: id, context: .background) }
        #expect(reasons.values.first == .some(.restart))
        try await harness.close(context: .background)
    }

    @Test func finalizesAChainOfHeldOwnersInTheCommitThatFreesTheLastOne() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ObservedStorage(try await SqliteStorage.open(path: directory.appendingPathComponent("session.sqlite").path))
        // The commit, by count, that wrote each terminal record.
        let endedIn = Mutex<(commits: Int, ids: [TaskID: Int])>((0, [:]))
        storage.onCommit { writes in
            endedIn.withLock { state in
                state.commits += 1
                for case .task(let record, _) in writes where record.state.status == "terminal" { state.ids[record.id] = state.commits }
            }
        }
        let gates = HarnessHoldGates(), hold = harnessHold(gates)
        let harness = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(hold)]).harness
        let root = try await harness.root(context: .background)
        try harness.resume()
        let ids = try await root.commit({ tx in
            let top = try await tx.createTask(hold, input: .init(name: "top"), options: .init(ownership: .conversation()))
            let middle = try await tx.createTask(hold, input: .init(name: "middle"), options: .init(ownership: .task(taskId: top)))
            let leaf = try await tx.createTask(hold, input: .init(name: "leaf"), options: .init(ownership: .task(taskId: middle)))
            return (top: top, middle: middle, leaf: leaf)
        }, context: .background)
        gates.open("top")
        gates.open("middle")
        try await eventually { try await harness.getTask(id: ids.top, context: .background)?.state.status == "completing" }
        try await eventually { try await harness.getTask(id: ids.middle, context: .background)?.state.status == "completing" }
        gates.open("leaf")
        #expect(try await harness.waitForTask(id: ids.top, context: .background).outcome.status == "completed")
        // Both owners end in one finalize commit, after the leaf's.
        let ended = endedIn.withLock { $0.ids }
        let middle = try #require(ended[ids.middle]), leaf = try #require(ended[ids.leaf])
        #expect(ended[ids.top] == middle)
        #expect(middle > leaf)
        try await harness.close(context: .background)
    }

    @Test func keepsAScopeBusyAfterReopenForWorkBelowAnEndedTaskWhoseChainIsNotLoadedYet() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let gates = HarnessHoldGates(), hold = harnessHold(gates)
        let first = try await openTasks(storage: SqliteStorage.open(path: path), tasks: [AnyTaskDefinition(hold)]).harness
        let firstRoot = try await first.root(context: .background)
        try first.resume()
        // root conversation -> owner (ends) -> conversation C -> inner (created after owner ended), as a subagent call's.
        let tree = try await firstRoot.commit({ tx in
            let owner = try await tx.createTask(hold, input: .init(name: "owner"), options: .init(ownership: .conversation()))
            let child = try await tx.createConversation(ownership: .task(taskId: owner)).id
            return (owner: owner, child: child)
        }, context: .background)
        gates.open("owner")
        _ = try await first.waitForTask(id: tree.owner, context: .background)
        let conversation = try #require(try await first.conversation(id: tree.child, context: .background))
        let inner = try await conversation.commit({ tx in
            try await tx.createTask(hold, input: .init(name: "inner"), options: .init(ownership: .conversation()))
        }, context: .background)
        try await first.close(context: .background)
        // Hold the read of C's record, so the chain above `inner` stays unloaded while idle is decided.
        let storage = ObservedStorage(try await SqliteStorage.open(path: path))
        let reading = HarnessChatSignal(), release = HarnessChatSignal()
        storage.hold(tree.child, reading: reading, until: release)
        let harness = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(hold)]).harness
        await reading.wait()
        // A task whose chain is not loaded counts as inside every scope. (The held read blocks the Session line, so the
        // waits below queue behind it, and the root handle comes after.)
        #expect(!harness.tasks.idle(nil))
        let idle = settled { try await harness.waitForIdle(context: .background) }
        release.signal()
        let root = try await harness.root(context: .background)
        try harness.resume()
        // Loaded, the chain keeps `inner` in the root conversation's scope.
        #expect(!harness.tasks.idle(root.id) && !idle.isSettled)
        gates.open("inner")
        _ = try await harness.waitForTask(id: inner, context: .background)
        try await root.waitForIdle(context: .background)
        try await eventually { idle.isSettled }
        try await harness.close(context: .background)
    }
}

/// What `ownedTasks()` returned to each run of a probe, by its name, and the runtime of its last run.
private final class OwnedTasksLog: Sendable {
    let owned = Mutex<[String: [TaskID]]>([:])
    let runtimes = Mutex<[String: TaskRuntime]>([:])
}
/// Records its owned tasks once its `look.<name>` gate opens, then holds until its own gate opens.
private func ownedTasksProbe(_ gates: HarnessHoldGates, _ log: OwnedTasksLog) -> HarnessHoldTask {
    HarnessHoldTask(name: "test.index.probe", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
        log.runtimes.withLock { $0[task.input.name] = runtime }
        guard await gates.wait("look.\(task.input.name)", signal: runtime.signal) != nil else { return }
        let owned = try await runtime.ownedTasks(context: context).map(\.id)
        log.owned.withLock { $0[task.input.name] = owned }
        guard let outcome = await gates.wait(task.input.name, signal: runtime.signal) else { return }
        try await runtime.commit({ _, _ in .terminal(outcome: outcome) }, context: context)
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}

/// Port of the `TaskRuntime.ownedTasks` cases of upstream `test/harness-scheduler-indexes.test.ts`.
@Suite struct TaskRuntimeOwnedTasksTests {
    @Test func listsTheLiveTasksATaskOwnsDirectlyInIDOrderAlsoAfterAReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        var gates = HarnessHoldGates(), log = OwnedTasksLog()
        var hold = harnessHold(gates), probe = ownedTasksProbe(gates, log)
        var opened = try await openTasks(storage: SqliteStorage.open(path: path), tasks: [AnyTaskDefinition(hold), AnyTaskDefinition(probe)])
        let root = try await opened.harness.root(context: .background)
        try opened.harness.resume()
        // The probe owns: two held tasks, one that ends, a grandchild below the first, and a conversation with a task.
        let ids = try await root.commit({ [hold, probe] tx in
            let owner = try await tx.createTask(probe, input: .init(name: "probe"), options: .init(ownership: .conversation()))
            let first = try await tx.createTask(hold, input: .init(name: "first"), options: .init(ownership: .task(taskId: owner)))
            let ends = try await tx.createTask(hold, input: .init(name: "ends"), options: .init(ownership: .task(taskId: owner)))
            let second = try await tx.createTask(hold, input: .init(name: "second"), options: .init(ownership: .task(taskId: owner)))
            _ = try await tx.createTask(hold, input: .init(name: "grandchild"), options: .init(ownership: .task(taskId: first)))
            let child = try await tx.createConversation(ownership: .task(taskId: owner)).id
            _ = try await tx.createTask(hold, input: .init(name: "inside"), options: .init(ownership: .conversation(), conversationId: child))
            return (probe: owner, first: first, ends: ends, second: second)
        }, context: .background)
        gates.open("ends")
        _ = try await opened.harness.waitForTask(id: ids.ends, context: .background)
        // The first ends too, but holds its outcome as `completing` while its grandchild runs: still live, so listed.
        gates.open("first")
        try await eventually { [harness = opened.harness] in
            try await harness.getTask(id: ids.first, context: .background)?.state.status == "completing"
        }
        gates.open("look.probe")
        try await eventually { [log] in log.owned.withLock { $0["probe"] } != nil }
        #expect(log.owned.withLock { $0["probe"] } == [ids.first, ids.second])
        try await opened.harness.close(context: .background)

        // After a reopen the rerun sees the same tasks, which an earlier invocation created.
        gates = HarnessHoldGates(); log = OwnedTasksLog()
        hold = harnessHold(gates); probe = ownedTasksProbe(gates, log)
        opened = try await openTasks(storage: SqliteStorage.open(path: path), tasks: [AnyTaskDefinition(hold), AnyTaskDefinition(probe)])
        try opened.harness.resume()
        gates.open("look.probe")
        try await eventually { [log] in log.owned.withLock { $0["probe"] } != nil }
        #expect(log.owned.withLock { $0["probe"] } == [ids.first, ids.second])
        try await opened.harness.close(context: .background)
    }

    @Test func rejectsOnceItsInvocationHasEnded() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gates = HarnessHoldGates(), log = OwnedTasksLog(), probe = ownedTasksProbe(gates, log)
        let opened = try await openTasks(storage: SqliteStorage.open(path: directory.appendingPathComponent("session.sqlite").path),
                                         tasks: [AnyTaskDefinition(harnessHold(gates)), AnyTaskDefinition(probe)])
        let root = try await opened.harness.root(context: .background)
        try opened.harness.resume()
        let id = try await root.commit({ tx in
            try await tx.createTask(probe, input: .init(name: "probe"), options: .init(ownership: .conversation()))
        }, context: .background)
        try await eventually { log.runtimes.withLock { $0["probe"] } != nil }
        let runtime = try #require(log.runtimes.withLock { $0["probe"] })
        // Aborting joins the run invocation, which has ended by then.
        _ = try await opened.harness.abortTask(id: id, context: .background)
        await #expect { _ = try await runtime.ownedTasks(context: .background) } throws: { error in
            String(describing: error).contains("invocation has ended")
        }
        try await opened.harness.close(context: .background)
    }
}
