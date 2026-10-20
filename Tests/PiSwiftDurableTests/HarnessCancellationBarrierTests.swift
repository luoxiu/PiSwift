import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Runs until aborted; its abort handler ends it `aborted`.
private func dormant(_ name: String = "test.dormant") -> HarnessTestTask {
    harnessOneStep(name, run: { _, runtime, _ in
        try await harnessToolAwaitAbort(runtime.context)
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}

/// Holds every commit that abort-marks `target`, while set, until released.
private final class HoldMarks: DurableStorage, Sendable {
    let base = MemoryStorage()
    let target = Mutex<TaskID?>(nil)
    let held = HarnessChatSignal(), release = HarnessChatSignal()
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        let target = self.target.withLock { $0 }
        if writes.contains(where: { if case .task(let record, _) = $0 { return record.id == target && record.abortRequested }; return false }) {
            held.signal()
            await release.wait()
        }
        return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { try await base.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? { try await base.conversation(id, context: context) }
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

/// Creates a conversation and tasks on a plain Session over `storage`, which stays open for the Harness opened later.
private func seed(_ storage: any DurableStorage, _ body: (Transaction, ConversationID) async throws -> [TaskID]) async throws -> [TaskID] {
    let session = try await Session.open(storage: storage, context: .background)
    let conversation = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()).id }, context: .background)
    return try await session.commit({ tx in try await body(tx, conversation) }, context: .background)
}

/// Port of upstream `test/harness-cancellation-barrier.test.ts`.
@Suite struct HarnessCancellationBarrierTests {
    @Test func doesNotStartItsNextPhaseWhileTheCascadeThatMarksItHasNotCommitted() async throws {
        let storage = HoldMarks(), entered = HarnessChatSignal(), advance = HarnessChatSignal(), ranNext = Mutex(false)
        let parentTask = dormant()
        let child = HarnessTestTask(name: "test.child", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                entered.signal()
                await advance.wait()
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
            case .joined:
                ranNext.withLock { $0 = true }
                try await harnessToolAwaitAbort(runtime.context)
            }
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(parentTask), AnyTaskDefinition(child)])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let parent = try await harnessStart(root, parentTask)
        let childID = try await root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: parent)))
        }, context: .background)
        storage.target.withLock { $0 = childID }
        try harness.resume()
        await entered.wait()
        let aborting = Task { try await harness.abortTask(id: parent, context: .background) }
        await storage.held.wait()
        // The parent's request is durable, the cascade's mark of the child is not: its phase must not advance.
        advance.signal()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!ranNext.withLock { $0 })
        storage.release.signal()
        #expect(try await harness.waitForTask(id: childID, context: .background).outcome.status == "aborted")
        _ = try await aborting.value
        #expect(!ranNext.withLock { $0 })
        try await harness.close(context: .background)
    }

    @Test func letsAFailFastRequestInTheSamePassOverrideARestartMark() async throws {
        let storage = MemoryStorage(), task = dormant()
        let ids = try await seed(storage) { tx, conversation in
            let parent = try await tx.createTask(task, input: 0, options: .init(ownership: .conversation(), conversationId: conversation))
            let failed = try await tx.createTask(task, input: 0, options: .init(ownership: .task(taskId: parent)))
            let child = try await tx.createTask(task, input: 0, options: .init(ownership: .task(taskId: parent)))
            return [parent, failed, child]
        }
        // A restart-abandoned owner that waits failFast on a failed child and a live one.
        let owner = try #require(try await storage.task(ids[0], context: .background))
        let failedRecord = try #require(try await storage.task(ids[1], context: .background))
        let waiting = TaskState.waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()), on: [ids[1], ids[2]], policy: .failFast)
        _ = try await storage.commit([
            .task(value: owner.replacing(state: waiting).withAbortMark(.restart)),
            .task(value: failedRecord.replacing(state: .terminal(outcome: .failed(error: .init(message: "failed"))))),
        ], context: .background)
        // The child's definition is missing: a restart mark would keep it waiting, a request orphans it.
        let opened = try await openTasks(storage: storage, tasks: [])
        try opened.harness.resume()
        let harness = opened.harness
        try await eventually { try await harness.getTask(id: ids[2], context: .background)?.state.status == "terminal" }
        #expect(try await harness.getTask(id: ids[2], context: .background)?.state.outcome == .orphaned(reason: "missing_task"))
        try await harness.close(context: .background)
    }

    @Test func upgradesRestartMarksDownTheTreeWhenAnAbortIsRequestedAboveThem() async throws {
        let storage = MemoryStorage(), task = dormant(), missing = dormant("test.missing")
        let ids = try await seed(storage) { tx, conversation in
            let top = try await tx.createTask(task, input: 0, options: .init(ownership: .conversation(), conversationId: conversation))
            let middle = try await tx.createTask(task, input: 0, options: .init(ownership: .task(taskId: top), abandonOnRestart: true))
            let leaf = try await tx.createTask(missing, input: 0, options: .init(ownership: .task(taskId: middle)))
            return [top, middle, leaf]
        }
        // Only the dormant task is registered: the leaf waits for its definition under the restart cascade.
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(task)])
        let harness = opened.harness
        try harness.resume()
        try await eventually { try await harness.getTask(id: ids[2], context: .background)?.abortReason == .restart }
        try await eventually {
            let inspected = try await harness.inspect(context: .background).tasks.first { $0.record.id == ids[2] }
            if case .blocked? = inspected?.state { return true }
            return false
        }
        #expect(try await harness.getTask(id: ids[2], context: .background)?.state.status != "terminal")
        // A request on the top task reaches the leaf two levels down, which is then orphaned.
        _ = try await harness.abortTask(id: ids[0], context: .background)
        for (id, status) in [(ids[2], "orphaned"), (ids[1], "aborted"), (ids[0], "aborted")] {
            #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == status)
        }
        try await harness.close(context: .background)
    }

    @Test func marksAFlaggedTaskThatHoldsItsOutcomeAbortingItsOwnedWorkAndKeepsTheOutcome() async throws {
        let storage = MemoryStorage(), task = dormant()
        let ids = try await seed(storage) { tx, conversation in
            let holder = try await tx.createTask(task, input: 0, options: .init(ownership: .conversation(), conversationId: conversation, abandonOnRestart: true))
            let child = try await tx.createTask(task, input: 0, options: .init(ownership: .task(taskId: holder)))
            return [holder, child]
        }
        let record = try #require(try await storage.task(ids[0], context: .background))
        _ = try await storage.commit([.task(value: record.replacing(state: .completing(outcome: .completed(result: .null))))], context: .background)
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(task)])
        try opened.harness.resume()
        #expect(try await opened.harness.waitForTask(id: ids[1], context: .background).outcome.status == "aborted")
        let settled = try await opened.harness.waitForTask(id: ids[0], context: .background)
        #expect(settled.record.abortReason == .restart && settled.outcome == .completed(result: .null))
        try await opened.harness.close(context: .background)
    }
}
