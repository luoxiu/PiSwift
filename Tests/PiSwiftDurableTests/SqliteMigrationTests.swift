import Foundation

import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.SqliteMigrations")
struct SqliteMigrationTests {
    @Test func createsCurrentSchemaAndRepeats() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        try applySqliteMigrations(db)
        try applySqliteMigrations(db)
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(currentSqliteSchemaVersion))])
        #expect(try db.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1") == ["next_id": .text("2"), "next_seq": .integer(1)])
    }

    // upstream sqlite-migrations.test.ts:47
    @Test func migratesAVersion1DatabaseToStoreSleepingTasksKeepingItsTasksAndIndexes() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let database = try AppleSqliteDatabase(path: path)
        try applySqliteMigrations(database, migrations: Array(sqliteMigrations.prefix(1)))
        let waiting: JSONValue = ["id": 5, "conversationId": 1, "kind": "test.task", "version": 1, "input": .null, "background": false,
                                  "abortRequested": false, "state": ["status": "waiting", "checkpoint": ["phase": "run"], "on": [], "policy": "allSettled"]]
        let record = try waiting.jsonText()
        try database.run("INSERT INTO tasks (id, conversation_id, kind, status, abort_requested, background, record) VALUES (5, 1, 'test.task', 'waiting', 0, 0, ?)",
                         [.text(record)])
        #expect(throws: (any Error).self) {
            try database.run("INSERT INTO tasks (id, conversation_id, kind, status, abort_requested, background, record) VALUES (6, 1, 'test.task', 'sleeping', 0, 0, '{}')")
        }
        try database.close()

        let storage = try await SqliteStorage.open(path: path)
        try await storage.close(context: .background)
        let migrated = try AppleSqliteDatabase(path: path)
        defer { try? migrated.close() }
        #expect(try migrated.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(2)])
        #expect(try migrated.get("SELECT status, record FROM tasks WHERE id = 5") == ["status": .text("waiting"), "record": .text(record)])
        try migrated.run("INSERT INTO tasks (id, conversation_id, kind, status, abort_requested, background, record) VALUES (6, 1, 'test.task', 'sleeping', 0, 0, '{}')")
        let indexes = try migrated.all("SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'tasks' ORDER BY name")
        #expect(indexes.compactMap { $0["name"]?.textValue } == [
            "tasks_by_abort_requested", "tasks_by_background", "tasks_by_conversation", "tasks_by_kind", "tasks_by_status",
        ])
        #expect(try migrated.get("SELECT count(*) AS count FROM sqlite_schema WHERE name = 'tasks_v2'") == ["count": .integer(0)])
    }

    @Test func rejectsNewerDatabase() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        try applySqliteMigrations(db)
        try db.run("UPDATE durable_schema SET version = ? WHERE singleton = 1", [.integer(Int64(currentSqliteSchemaVersion + 1))])
        do { try applySqliteMigrations(db); Issue.record("Newer schema accepted") }
        catch { #expect(String(describing: error).contains("is newer than supported version")) }
    }

    @Test func preservesDataForMigrationRetry() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        let write: JSONValue = ["type": "entry", "value": ["id": 2, "conversationId": 1, "kind": "retained", "data": ["retained": true]]]
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), try write.decode(StorageWrite.self)], context: .background)
        try await storage.close(context: .background)
        let db = try AppleSqliteDatabase(path: path)
        defer { try? db.close() }
        let version = currentSqliteSchemaVersion + 1
        #expect(throws: (any Error).self) { try applySqliteMigrations(db, migrations: sqliteMigrations + [SqliteMigration(version: version, statements: ["CREATE TABLE migration_probe (value TEXT) STRICT", "THIS IS NOT SQL"])]) }
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(currentSqliteSchemaVersion))])
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE type = 'table' AND name = 'migration_probe'") == ["count": .integer(0)])
        try applySqliteMigrations(db, migrations: sqliteMigrations + [SqliteMigration(version: version, statements: ["CREATE TABLE migration_probe (value TEXT) STRICT"])])
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(version))])
        let row = try #require(try db.get("SELECT record, commit_seq FROM entries WHERE id = 2"))
        if case .text(let record) = row["record"] { #expect(try JSONValue(jsonText: record) == write["value"]) }
        else { Issue.record("Missing retained record") }
        #expect(row["commit_seq"] == .integer(1))
        #expect(try db.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1") == ["next_id": .text("3"), "next_seq": .integer(2)])
    }
}
