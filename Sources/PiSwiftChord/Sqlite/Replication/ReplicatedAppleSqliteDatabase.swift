// Ports upstream `packages/chord/src/sqlite/replication/node.ts` at 48c8f3228. Upstream does not export it from the
// package yet, so it is internal here.

import Foundation

/// What the replication engine observes on a replicated connection. See `ReplicatedAppleSqliteDatabase`.
protocol ReplicationHooks: AnyObject {
    /// Called synchronously after any operation through the connection returns or throws, because it may have
    /// committed. Must not throw and must not call the database.
    func afterOperation()
    /// Runs during `close`, alone on the connection, after every earlier operation and before SQLite checkpoints and
    /// deletes the WAL. Everything the engine has not taken out of the WAL by the time this returns is lost to it.
    func beforeClose(_ executor: any SqliteExecutor) throws
}

/// Connection settings for a replicated database file. Automatic WAL checkpoints are always off.
struct ReplicatedAppleSqliteDatabaseOptions {
    /// Time SQLite waits for a competing file lock; see `AppleSqliteDatabase`'s `busyTimeoutMilliseconds`.
    var busyTimeoutMilliseconds: Int32?
}

/// Both the close hook and the close failed, as upstream's `AggregateError`.
struct ReplicationCloseError: Error, CustomStringConvertible {
    let errors: [any Error]
    var description: String { "Replication close hook and close failed" }
}

/// A SQLite connection whose write-ahead log (WAL) the replication engine reads from outside SQLite.
///
/// The engine ships the pages SQLite appends to `{path}-wal`. That only works if no page leaves the WAL before the
/// engine has read it, and a page leaves the WAL whenever anything checkpoints: SQLite's automatic checkpoint after a
/// commit, a checkpoint by another connection, and the checkpoint SQLite runs when the last connection closes. This
/// wrapper exists so that the engine, and only the engine, decides when that happens on this connection:
///
/// - It opens the file itself, with automatic checkpoints disabled, so that the engine is attached before anyone else
///   can write. Durable runs schema migrations on open, and those commits must be replicated like any other.
/// - It owns the underlying connection and never hands it out, so every operation goes through the wrapper. After
///   each one it calls `afterOperation`, which is how the engine learns that the WAL may have grown. That includes
///   statements outside a transaction, which commit on their own.
/// - It exposes `exclusive` so the engine can checkpoint without interleaving with a commit.
/// - `close` first runs `beforeClose` alone on the connection, after everything called earlier, and only then lets
///   the connection close. Operations called after `close` throw, so nothing can commit between the two steps.
///
/// Apple's SQLite keeps WAL files (persistent WAL), so after `close` the file is still there, empty: the driver's close
/// checkpoints with `TRUNCATE`. Upstream's Node SQLite deletes it.
///
/// The wrapper does not read the WAL, schedule flushes or checkpoint; that is the engine's work, through the hooks.
/// It also cannot stop another process from opening the file, which may checkpoint behind the engine's back. The
/// engine detects that from the WAL salts and recovers by taking a new base.
///
/// Its initializer is private, so the only way to get an instance is `openReplicatedAppleSqliteDatabase`. An
/// initializer that accepted any `AppleSqliteDatabase` would let a caller pass one with automatic checkpoints on, or
/// keep writing through the connection directly, and either would drop WAL pages before the engine read them.
final class ReplicatedAppleSqliteDatabase: SqliteExecutor {
    /// Absolute path of the database file. The WAL is `\(path)-wal`.
    let path: String
    private let database: AppleSqliteDatabase
    private let hooks: any ReplicationHooks
    private var closing: Result<Void, any Error>?
    private var closeStarted = false

    fileprivate init(path: String, database: AppleSqliteDatabase, hooks: any ReplicationHooks) {
        self.path = path
        self.database = database
        self.hooks = hooks
    }

    func exec(_ sql: String) throws {
        try observe { try database.exec(sql) }
    }

    func run(_ sql: String, _ params: [SqliteValue]) throws {
        try observe { try database.run(sql, params) }
    }

    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        try observe { try database.get(sql, params) }
    }

    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        try observe { try database.all(sql, params) }
    }

    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try observe { try database.transaction(body) }
    }

    /// Runs `operation` alone on the connection; see `AppleSqliteDatabase.exclusive`.
    func exclusive<T>(_ operation: (any SqliteExecutor) throws -> T) throws -> T {
        guard !closeStarted else { throw SqliteFacadeError.replicatedClosed }
        return try database.exclusive(operation)
    }

    /// Runs the close hook, then closes the connection, once; later calls return or throw the same outcome.
    func close() throws {
        if let closing { return try closing.get() }
        // The close hook calling `close` again would wait for itself upstream.
        guard !closeStarted else { throw SqliteFacadeError.replicatedClosed }
        closeStarted = true
        let outcome = Result { try closeOnce() }
        closing = outcome
        try outcome.get()
    }

    private func closeOnce() throws {
        var hookError: (any Error)?
        do {
            try database.exclusive { executor in try hooks.beforeClose(executor) }
        } catch {
            hookError = error
        }
        do {
            try database.close()
        } catch {
            if let hookError { throw ReplicationCloseError(errors: [hookError, error]) }
            throw error
        }
        if let hookError { throw hookError }
    }

    private func observe<T>(_ operation: () throws -> T) throws -> T {
        guard !closeStarted else { throw SqliteFacadeError.replicatedClosed }
        defer { hooks.afterOperation() }
        return try operation()
    }
}

/// Opens a database file for replication. The file needs a WAL, so in-memory and temporary databases are refused.
func openReplicatedAppleSqliteDatabase(
    path: String,
    hooks: any ReplicationHooks,
    options: ReplicatedAppleSqliteDatabaseOptions = .init()
) throws -> ReplicatedAppleSqliteDatabase {
    if path.isEmpty || path == ":memory:" || path.hasPrefix("file:") {
        throw SqliteFacadeError.replicationPath(path)
    }
    let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
    let database = try AppleSqliteDatabase(
        path: absolute, walAutoCheckpointPages: 0, busyTimeoutMilliseconds: options.busyTimeoutMilliseconds ?? 5_000)
    return ReplicatedAppleSqliteDatabase(path: absolute, database: database, hooks: hooks)
}
