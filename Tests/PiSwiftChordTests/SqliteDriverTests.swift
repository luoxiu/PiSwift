import Foundation
import Testing
import PiSwiftChord

/// A failure a transaction callback throws in these tests.
private struct CallbackRejection: Error, Equatable { let message: String }

private actor TransactionProbe {
    let database: AppleSqliteDatabase
    init() throws {
        database = try AppleSqliteDatabase(path: ":memory:")
        try database.exec("CREATE TABLE transaction_queue (value INTEGER)")
    }
    func insert(_ value: Int64) throws {
        try database.transaction { handle in
            try handle.run("INSERT INTO transaction_queue (value) VALUES (?)", [.integer(value)])
            #expect(try handle.get("SELECT count(*) AS count FROM transaction_queue")?["count"]?.integerValue == value)
        }
    }
    func values() throws -> [Int64] {
        try database.all("SELECT value FROM transaction_queue ORDER BY value").compactMap { $0["value"]?.integerValue }
    }
    func close() throws { try database.close() }
}

// chord/test/sqlite/node.test.ts (48c8f3228; line numbers are that version's) on AppleSqliteDatabase, which moved here from PiSwiftDurable with the
// tests Durable had for it.
@Suite("PiSwiftChordTests.SqliteDriver")
struct SqliteDriverTests {
    // :6.
    @Test func configuresConnectionDefaultsAndAcceptsExplicitSettings() throws {
        for explicit in [false, true] {
            let database = explicit
                ? try AppleSqliteDatabase(path: ":memory:", walAutoCheckpointPages: 0, busyTimeoutMilliseconds: 123)
                : try AppleSqliteDatabase(path: ":memory:")
            defer { try? database.close() }
            #expect(try database.get("PRAGMA busy_timeout") == ["timeout": .integer(explicit ? 123 : 5_000)])
            #expect(try database.get("PRAGMA wal_autocheckpoint") == ["wal_autocheckpoint": .integer(explicit ? 0 : 1_000)])
            #expect(try database.get("PRAGMA synchronous") == ["synchronous": .integer(1)])
        }
    }

    // :21.
    @Test func commitsThroughHandleAndClosesIdempotently() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        try database.transaction { transaction in
            try transaction.exec("CREATE TABLE probe (value INTEGER)")
            try transaction.run("INSERT INTO probe (value) VALUES (?)", [.integer(1)])
        }
        #expect(try database.get("SELECT value FROM probe") == ["value": .integer(1)])
        try database.close()
        try database.close()
    }

    // :32 and :67. The driver is synchronous; its owner's actor serializes the transactions.
    @Test func serializesTransactionsInActor() async throws {
        let probe = try TransactionProbe()
        // Actor calls have no suspension inside their SQL transaction.
        let first = Task { try await probe.insert(1) }
        try await first.value
        let second = Task { try await probe.insert(2) }
        try await second.value
        #expect(try await probe.values() == [1, 2])
        try await probe.close()
    }

    // :87 and :124. A synchronous driver has nothing to queue behind: a call on the database inside a transaction
    // throws instead of waiting for it or joining it, and the transaction's own work commits.
    @Test func rejectsDatabaseCallsInsideATransaction() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE barrier_probe (value INTEGER)")
        try database.transaction { handle in
            try handle.run("INSERT INTO barrier_probe (value) VALUES (?)", [.integer(1)])
            #expect(throws: SqliteFacadeError.transactionHandleRequired) {
                try database.run("INSERT INTO barrier_probe (value) VALUES (?)", [.integer(2)])
            }
            #expect(throws: SqliteFacadeError.transactionHandleRequired) { _ = try database.all("SELECT value FROM barrier_probe") }
            #expect(throws: SqliteFacadeError.transactionHandleRequired) { _ = try database.transaction { _ in 0 } }
            #expect(throws: SqliteFacadeError.transactionHandleRequired) { try database.close() }
        }
        #expect(try database.all("SELECT value FROM barrier_probe") == [["value": .integer(1)]])
    }

    // :141.
    @Test func rejectsStaleTransactionHandle() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE stale_probe (value INTEGER)")
        var handle: (any SqliteExecutor)?
        try database.transaction { transaction in
            handle = transaction
            try transaction.run("INSERT INTO stale_probe (value) VALUES (?)", [.integer(1)])
        }
        let stale = try #require(handle)
        #expect(throws: SqliteFacadeError.inactiveHandle("transaction")) { try stale.exec("INSERT INTO stale_probe (value) VALUES (2)") }
        #expect(throws: SqliteFacadeError.inactiveHandle("transaction")) { try stale.run("INSERT INTO stale_probe (value) VALUES (?)", [.integer(3)]) }
        #expect(throws: SqliteFacadeError.inactiveHandle("transaction")) { _ = try stale.get("SELECT value FROM stale_probe") }
        #expect(throws: SqliteFacadeError.inactiveHandle("transaction")) { _ = try stale.all("SELECT value FROM stale_probe") }
        #expect(try database.all("SELECT value FROM stale_probe") == [["value": .integer(1)]])
    }

    // :156. The driver is synchronous, so the earlier call has returned and the later one runs after the operation
    // returns; upstream's gate that holds the later call back has no counterpart.
    @Test func runsAnExclusiveOperationAloneOutsideATransactionAfterEarlierCalls() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE exclusive_probe (value INTEGER)")
        try database.run("INSERT INTO exclusive_probe (value) VALUES (?)", [.integer(1)])
        var handle: (any SqliteExecutor)?
        let seen = try database.exclusive { executor in
            handle = executor
            let seen = try executor.all("SELECT value FROM exclusive_probe")
            // Not inside a transaction: the handle may begin and commit one itself.
            try executor.exec("BEGIN; INSERT INTO exclusive_probe (value) VALUES (2); COMMIT")
            // Swift: as in a transaction, a call on the database itself must use the handle.
            #expect(throws: SqliteFacadeError.transactionHandleRequired) { _ = try database.all("SELECT 1") }
            return seen
        }
        #expect(seen == [["value": .integer(1)]])
        #expect(try database.all("SELECT value FROM exclusive_probe ORDER BY value") == [["value": .integer(1)], ["value": .integer(2)]])
        #expect(throws: SqliteFacadeError.inactiveHandle("exclusive")) { try #require(handle).exec("SELECT 1") }
        #expect(SqliteFacadeError.inactiveHandle("exclusive").description == "SQLite exclusive handle is no longer active")
        #expect(throws: CallbackRejection(message: "failed")) {
            try database.exclusive { _ in throw CallbackRejection(message: "failed") }
        }
        #expect(try database.get("SELECT count(*) AS count FROM exclusive_probe") == ["count": .integer(2)])
    }

    // :190.
    @Test func rollsBackATransactionAnExclusiveOperationLeftOpenAndThrows() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE left_open (value INTEGER)")
        let leftOpen = "SQLite exclusive operation left a transaction open; it was rolled back"

        do {
            _ = try database.exclusive { executor in
                try executor.exec("BEGIN; INSERT INTO left_open (value) VALUES (1)")
                return "returned without committing"
            }
            Issue.record("An open transaction was accepted")
        } catch let error as SqliteExclusiveTransactionError {
            #expect(error.description == leftOpen)
            #expect(error.cause == nil)
        }

        let failure = CallbackRejection(message: "failed mid-transaction")
        do {
            try database.exclusive { executor in
                try executor.exec("BEGIN IMMEDIATE; INSERT INTO left_open (value) VALUES (2)")
                throw failure
            }
            Issue.record("An open transaction was accepted")
        } catch let error as SqliteExclusiveTransactionError {
            #expect(error.description == leftOpen)
            #expect(error.cause as? CallbackRejection == failure)
        }

        // Later calls run outside any leftover transaction: autocommit writes commit and transactions can begin.
        try database.run("INSERT INTO left_open (value) VALUES (?)", [.integer(3)])
        try database.transaction { transaction in
            try transaction.run("INSERT INTO left_open (value) VALUES (?)", [.integer(4)])
        }
        #expect(try database.all("SELECT value FROM left_open ORDER BY value") == [["value": .integer(3)], ["value": .integer(4)]])
    }

    // :219.
    @Test func failedRollbackDoesNotPreserveCallbackError() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE rollback_probe (value INTEGER)")
        do {
            try database.transaction { transaction in
                try transaction.exec("INSERT INTO rollback_probe (value) VALUES (1)")
                try transaction.exec("COMMIT")
                throw CallbackRejection(message: "rejected after an escaped commit")
            }
            Issue.record("Rollback failure accepted")
        } catch {
            let rollback = try #require(error as? SqliteRollbackError)
            #expect(rollback.transactionError as? CallbackRejection == CallbackRejection(message: "rejected after an escaped commit"))
            #expect(rollback.rollbackError is SqliteError)
            #expect(!(error is CallbackRejection))
        }
        #expect(try database.get("SELECT value FROM rollback_probe") == ["value": .integer(1)])
    }

    // Swift: every value kind round-trips, and a closed database rejects every operation.
    @Test func bindsAllSQLiteValueKindsAndRejectsAllOperationsAfterClose() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        try database.exec("CREATE TABLE bindings (n, i, r, t, b)")
        let values: [SqliteValue] = [.null, .integer(4), .real(2.5), .text("a\0b"), .blob(Data([0, 1, 255]))]
        try database.run("INSERT INTO bindings VALUES (?, ?, ?, ?, ?)", values)
        #expect(try database.get("SELECT n, i, r, t, b FROM bindings") == ["n": values[0], "i": values[1], "r": values[2], "t": values[3], "b": values[4]])
        try database.close()
        #expect(throws: SqliteFacadeError.closed) { try database.exec("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { try database.run("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.get("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.all("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.transaction { _ in 1 } }
    }
}
