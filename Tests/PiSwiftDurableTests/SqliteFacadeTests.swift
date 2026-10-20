import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

/// A settlement failure injected by these tests.
private struct SettlementRejection: Error, Equatable { let message: String }

extension SqliteStorage {
    func sqlitePrepareCounts() -> [String: Int] { (db as? AppleSqliteDatabase)?.prepareCounts ?? [:] }
}

/// Rejects settlement after the callback, within the delegate's real SQL transaction.
private final class RejectingSettlementExecutor: SqliteExecutor {
    let delegate: AppleSqliteDatabase
    var reject = false
    init() throws { delegate = try AppleSqliteDatabase(path: ":memory:") }
    func exec(_ sql: String) throws { try delegate.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try delegate.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? { try delegate.get(sql, params) }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { try delegate.all(sql, params) }
    func close() throws { try delegate.close() }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try delegate.transaction { handle in
            let value = try body(handle)
            if reject { reject = false; throw SettlementRejection(message: "controlled settlement rejection") }
            return value
        }
    }
}

extension SqliteStorage {
    fileprivate func rejectNextSettlement() { (db as? RejectingSettlementExecutor)?.reject = true }
}

@Suite("PiSwiftDurableTests.SqliteFacade")
struct SqliteFacadeTests {
    @Test func preparesStatementsOnceAcrossStorageTransactions() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background)
        let entries = try (2...101).map { id in StorageWrite.entry(value: EntryRecord(id: try EntryID(Int64(id)), conversationId: rootConversationID, kind: "cached")) }
        _ = try await storage.commit(entries, context: .background)
        _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(102), conversationId: rootConversationID, kind: "cached-again"))], context: .background)
        #expect(try await storage.entry(EntryID(2), context: .background)?.entry.kind == "cached")
        #expect(try await storage.entry(EntryID(102), context: .background)?.entry.kind == "cached-again")
        await #expect(throws: DurableStorageError.idAlreadyOwned(id: 1, recordType: "conversation")) { _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background) }
        #expect(try await storage.entry(EntryID(2), context: .background)?.entry.kind == "cached")
        #expect(await storage.sqlitePrepareCounts().values.allSatisfy { $0 == 1 })
        try await storage.close(context: .background)
    }

    // The storage half of upstream's "runs operations in call order"; the driver half is in PiSwiftChordTests.
    @Test func serializesStorageCommitsInActor() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        let sequences = try await withThrowingTaskGroup(of: Seq.self) { group in
            for _ in 0..<32 { group.addTask { try await storage.commit([], context: .background) } }
            var values: [Seq] = []
            for try await seq in group { values.append(seq) }
            return values
        }
        #expect(sequences.map(\.rawValue).sorted() == Array(1...32).map(Int64.init))
        try await storage.close(context: .background)
    }

    @Test func adoptsIDsOnlyAfterSuccessfulSettlement() async throws {
        let storage = try await SqliteStorage.open(executor: RejectingSettlementExecutor())
        await storage.rejectNextSettlement()
        await #expect(throws: SettlementRejection.self) {
            _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(200), conversationId: rootConversationID, kind: "rejected"))], context: .background)
        }
        let first: EntryID = try await storage.mintId()
        #expect(first.rawValue == 2)
        #expect(try await storage.entry(EntryID(200), context: .background) == nil)
        _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(100), conversationId: rootConversationID, kind: "accepted"))], context: .background)
        let adopted: EntryID = try await storage.mintId()
        #expect(adopted.rawValue == 101)
        try await storage.close(context: .background)
    }

    @Test func admittedMultiQueryReadsFinishBeforeClose() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), .entry(value: EntryRecord(id: EntryID(2), conversationId: rootConversationID, kind: "probe"))], context: .background)
        // Each admitted actor call finishes its synchronous queries before returning.
        #expect(try await storage.scanEntries(.init(conversationId: rootConversationID), limit: 10, cursor: nil, context: .background).items.map(\.id.rawValue) == [2])
        #expect(try await storage.entry(rootConversationID, id: EntryID(2), context: .background)?.entry.kind == "probe")
        #expect(try await storage.findLatestHeadMarker(rootConversationID, atOrBeforeEntryId: nil, context: .background) == nil)
        try await storage.close(context: .background)
        try await storage.close(context: .background)
        await #expect(throws: DurableStorageError.closed(backend: "SqliteStorage")) {
            _ = try await storage.scanEntries(.init(conversationId: rootConversationID), limit: 10, cursor: nil, context: .background)
        }
    }

    @Test func readsDocumentFromOneStateDuringBaseReplacement() async throws {
        for yields in 0..<16 {
            let storage = try await SqliteStorage.open(path: ":memory:")
            let create: JSONValue = ["type": "document.create", "record": ["id": 5, "kind": "replaced", "scope": ["kind": "session"]], "content": ["kind": "base", "version": 1, "value": ["value": 1]]]
            let replace: JSONValue = ["type": "document.change", "id": 5, "content": ["kind": "base", "version": 1, "value": ["value": 2]]]
            _ = try await storage.commit([create.decode(StorageWrite.self)], context: .background)
            let read = Task { try await storage.document(DocumentID(5), at: .current, context: .background) }
            for _ in 0..<yields { await Task.yield() }
            let commit = Task { try await storage.commit([replace.decode(StorageWrite.self)], context: .background) }
            let stored = try await read.value
            _ = try await commit.value
            #expect(stored?.value == ["value": 1] || stored?.value == ["value": 2])
            try await storage.close(context: .background)
        }
    }
}
