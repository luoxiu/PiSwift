// Swift-only test support for `SqliteTelemetryTests` and `SqliteTelemetryStoreTests`: the spy that upstream's tests make
// with `vi.spyOn(db, "transaction")`. The recorder calls the database from its own actor while the test reads it,
// so every call takes one lock; a transaction's hook runs before the lock, so a hook that blocks holds no lock.

import Foundation
import Synchronization
import PiSwiftChord

/// A blocking gate a transaction hook waits on, from the recorder's thread. Once opened it stays open.
final class TelemetryTestLatch: Sendable {
    private let condition = NSCondition()
    nonisolated(unsafe) private var opened = false

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while !opened { condition.wait() }
        condition.unlock()
    }
}

/// An in-memory `AppleSqliteDatabase` behind a lock, with counts of the calls the recorder makes and an optional hook
/// that runs before each transaction (and may throw instead of running it).
final class TelemetryTestDatabase: SqliteExecutor, @unchecked Sendable {
    private struct Counts {
        var calls = 0
        var transactions = 0
        var transactionQueries = 0
        var active = 0
        var maximum = 0
    }

    private let base: AppleSqliteDatabase
    private let lock = NSRecursiveLock()
    private let counts = CountsBox()
    private let hook = Mutex<(@Sendable () throws -> Void)?>(nil)

    init(path: String = ":memory:") throws {
        base = try AppleSqliteDatabase(path: path)
    }

    /// Runs before every later transaction, outside the lock; a thrown error replaces the transaction.
    func onTransaction(_ body: (@Sendable () throws -> Void)?) { hook.withLock { $0 = body } }

    /// Calls the recorder made: statements, queries, and transactions.
    var calls: Int { counts.withLock { $0.calls } }
    /// Transactions the recorder started, including ones its hook failed.
    var transactions: Int { counts.withLock { $0.transactions } }
    /// `all` calls inside transactions.
    var transactionQueries: Int { counts.withLock { $0.transactionQueries } }
    /// The most transactions that were in progress at once.
    var maximumConcurrentTransactions: Int { counts.withLock { $0.maximum } }

    func resetCounts() { counts.withLock { $0 = Counts() } }

    /// Reads for the test itself, which the counts leave out.
    func rows(_ sql: String, _ params: [SqliteValue] = []) throws -> [SqliteRow] {
        try lock.withLock { try base.all(sql, params) }
    }

    /// Statements for the test itself, which the counts leave out.
    func execute(_ sql: String, _ params: [SqliteValue] = []) throws {
        try lock.withLock { try base.run(sql, params) }
    }

    func exec(_ sql: String) throws {
        counts.withLock { $0.calls += 1 }
        try lock.withLock { try base.exec(sql) }
    }

    func run(_ sql: String, _ params: [SqliteValue]) throws {
        counts.withLock { $0.calls += 1 }
        try lock.withLock { try base.run(sql, params) }
    }

    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        counts.withLock { $0.calls += 1 }
        return try lock.withLock { try base.get(sql, params) }
    }

    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        counts.withLock { $0.calls += 1 }
        return try lock.withLock { try base.all(sql, params) }
    }

    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        counts.withLock { counts in
            counts.calls += 1
            counts.transactions += 1
            counts.active += 1
            counts.maximum = max(counts.maximum, counts.active)
        }
        defer { counts.withLock { $0.active -= 1 } }
        try hook.withLock { $0 }?()
        return try lock.withLock {
            try base.transaction { handle in
                try body(CountingHandle(handle) { [counts] in counts.withLock { $0.transactionQueries += 1 } })
            }
        }
    }

    func close() throws {
        try lock.withLock { try base.close() }
    }

    private final class CountsBox: Sendable {
        private let state = Mutex(Counts())
        func withLock<R: Sendable>(_ body: (inout sending Counts) -> sending R) -> sending R { state.withLock(body) }
    }

    private final class CountingHandle: SqliteExecutor {
        let handle: any SqliteExecutor
        let onAll: () -> Void
        init(_ handle: any SqliteExecutor, onAll: @escaping () -> Void) {
            self.handle = handle
            self.onAll = onAll
        }
        func exec(_ sql: String) throws { try handle.exec(sql) }
        func run(_ sql: String, _ params: [SqliteValue]) throws { try handle.run(sql, params) }
        func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? { try handle.get(sql, params) }
        func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
            onAll()
            return try handle.all(sql, params)
        }
        func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T { try handle.transaction(body) }
        func close() throws { try handle.close() }
    }
}
