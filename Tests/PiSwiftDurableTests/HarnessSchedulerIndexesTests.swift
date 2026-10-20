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
