// Ports upstream `packages/chord/test/sqlite/replication-node.test.ts` at 48c8f3228 on the internal
// `ReplicatedAppleSqliteDatabase`. Upstream's "can only be created by opening a file" checks the module's exports at run
// time; the Swift initializer is private, which the compiler checks, so that case is not ported.

import Foundation
import Testing
@testable import PiSwiftChord

private let walHeaderBytes = 32
private let walFrameHeaderBytes = 24

/// Committed frames in a WAL file, counted from its header without validating checksums.
private func walCommitFrames(_ path: String) throws -> Int {
    let wal = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    guard wal.count >= walHeaderBytes else { return 0 }
    func uint32(_ offset: Int) -> Int { wal[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
    let pageSize = uint32(8)
    var commits = 0
    var offset = walHeaderBytes
    while offset + walFrameHeaderBytes + pageSize <= wal.count {
        if uint32(offset + 4) != 0 { commits += 1 }
        offset += walFrameHeaderBytes + pageSize
    }
    return commits
}

private final class RecordingHooks: ReplicationHooks {
    var operations = 0
    let beforeCloseBody: (any SqliteExecutor) throws -> Void

    init(beforeClose: @escaping (any SqliteExecutor) throws -> Void = { _ in }) {
        beforeCloseBody = beforeClose
    }

    func afterOperation() { operations += 1 }
    func beforeClose(_ executor: any SqliteExecutor) throws { try beforeCloseBody(executor) }
}

private struct SpoolFailure: Error, Equatable {}

/// Whether close left no WAL pages: upstream checks that SQLite deleted the file. Apple's SQLite keeps WAL files
/// (persistent WAL), and the driver's close checkpoints with `TRUNCATE`, so the file is left empty.
private func walIsEmpty(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return true }
    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) == 0
}

@Suite("PiSwiftChordTests.replicated SQLite connection")
struct SqliteReplicationTests {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chord-replication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("replica.sqlite").path
    }

    private func removeDirectory() { try? FileManager.default.removeItem(at: directory) }

    @Test func refusesDatabasesWithoutAWALFile() throws {
        defer { removeDirectory() }
        for target in ["", ":memory:", "file::memory:"] {
            #expect(throws: SqliteFacadeError.replicationPath(target)) {
                _ = try openReplicatedAppleSqliteDatabase(path: target, hooks: RecordingHooks())
            }
        }
        #expect(SqliteFacadeError.replicationPath("file::memory:").description
            == #"Replication needs a database file path, got "file::memory:""#)
    }

    @Test func opensInWALModeAndNeverCheckpointsOnItsOwn() throws {
        defer { removeDirectory() }
        let database = try openReplicatedAppleSqliteDatabase(path: path, hooks: RecordingHooks())
        #expect(database.path == URL(fileURLWithPath: path).standardizedFileURL.path)
        #expect(try database.get("PRAGMA journal_mode") == ["journal_mode": .text("wal")])
        #expect(try database.get("PRAGMA wal_autocheckpoint") == ["wal_autocheckpoint": .integer(0)])
        try database.exec("CREATE TABLE pages (value BLOB)")
        // SQLite's default would checkpoint once the WAL passes 1,000 pages; write well past that.
        for _ in 0..<12 {
            try database.transaction { transaction in
                for _ in 0..<100 { try transaction.run("INSERT INTO pages (value) VALUES (randomblob(4000))") }
            }
        }
        #expect(try walCommitFrames("\(path)-wal") == 13)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: "\(path)-wal")[.size] as? Int)
        #expect(size > 1_200 * 4_096)
        try database.close()
    }

    @Test func reportsEveryOperationIncludingFailedOnesAndStatementsOutsideTransactions() throws {
        defer { removeDirectory() }
        let hooks = RecordingHooks()
        let database = try openReplicatedAppleSqliteDatabase(path: path, hooks: hooks)
        try database.exec("CREATE TABLE notes (value TEXT NOT NULL)")
        try database.run("INSERT INTO notes (value) VALUES (?)", [.text("autocommit")])
        _ = try database.get("SELECT value FROM notes")
        _ = try database.all("SELECT value FROM notes")
        try database.transaction { transaction in
            try transaction.run("INSERT INTO notes (value) VALUES (?)", [.text("transaction")])
        }
        #expect(throws: SqliteError.self) { try database.run("INSERT INTO notes (value) VALUES (NULL)") }
        #expect(hooks.operations == 6)
        try database.exclusive { executor in try executor.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        #expect(hooks.operations == 6)
        try database.close()
    }

    // Swift: the driver is synchronous, so the inserts upstream leaves queued when it calls `close` have returned
    // before it; the close hook still runs after them and before the WAL goes.
    @Test func runsTheCloseHookAfterEarlierOperationsWhileTheWALHoldsEveryCommit() throws {
        defer { removeDirectory() }
        var framesAtClose = -1
        var rowsAtClose: SqliteRow?
        let path = path
        let database = try openReplicatedAppleSqliteDatabase(path: path, hooks: RecordingHooks { executor in
            framesAtClose = try walCommitFrames("\(path)-wal")
            rowsAtClose = try executor.get("SELECT count(*) AS count FROM notes")
        })
        try database.exec("CREATE TABLE notes (value TEXT)")
        for value in 1...3 { try database.run("INSERT INTO notes (value) VALUES (?)", [.text(String(value))]) }
        try database.close()
        try database.close()

        #expect(framesAtClose == 4)
        #expect(rowsAtClose == ["count": .integer(3)])
        // SQLite checkpoints and removes the WAL when the last connection closes; Apple's SQLite empties it.
        #expect(walIsEmpty("\(path)-wal"))
        #expect(throws: SqliteFacadeError.replicatedClosed) { try database.run("INSERT INTO notes (value) VALUES (?)", [.text("late")]) }
        #expect(throws: SqliteFacadeError.replicatedClosed) { try database.exclusive { _ in } }
        #expect(SqliteFacadeError.replicatedClosed.description == "Replicated SQLite database is closed")
    }

    @Test func closesTheConnectionEvenWhenTheCloseHookFails() throws {
        defer { removeDirectory() }
        let database = try openReplicatedAppleSqliteDatabase(path: path, hooks: RecordingHooks { _ in throw SpoolFailure() })
        try database.exec("CREATE TABLE notes (value TEXT)")
        #expect(throws: SpoolFailure()) { try database.close() }
        // Swift: a later `close` reports the same outcome, as upstream returns the same promise.
        #expect(throws: SpoolFailure()) { try database.close() }
        #expect(walIsEmpty("\(path)-wal"))

        let reopened = try openReplicatedAppleSqliteDatabase(path: path, hooks: RecordingHooks())
        #expect(try reopened.all("SELECT value FROM notes") == [])
        try reopened.close()
    }
}
