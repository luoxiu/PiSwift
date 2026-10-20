import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func prefixNames(_ path: String) throws -> [String] {
    let db = try AppleSqliteDatabase(path: path)
    defer { try? db.close() }
    return try db.all("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%'")
        .map { try $0.sqliteText("name") }
}

private func prefixHostTables(_ path: String, _ names: [String]) throws {
    let db = try AppleSqliteDatabase(path: path)
    defer { try? db.close() }
    for name in names { try db.exec("CREATE TABLE \(name) (text TEXT)") }
}

private func prefixRoot(_ storage: SqliteStorage, entry: (EntryID, String)? = nil) async throws {
    var writes: [StorageWrite] = [.conversation(value: ConversationRecord(id: rootConversationID))]
    if let (id, kind) = entry { writes.append(.entry(value: EntryRecord(id: id, conversationId: rootConversationID, kind: kind))) }
    _ = try await storage.commit(writes, context: .background)
}

private func prefixFailure(_ prefix: String) async -> String? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-sqlite-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("storage.sqlite").path,
                                                   options: .init(prefix: prefix))
        try await storage.close(context: .background)
        return nil
    } catch { return String(describing: error) }
}

private let sqlitePrefixedCases = storageConformanceCases { check in
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("storage.sqlite").path,
                                               options: .init(prefix: "pi_"))
    do { try await check(storage) }
    catch { try? await storage.close(context: .background); throw error }
    try await storage.close(context: .background)
}

// upstream sqlite-storage.test.ts and sqlite-cloudflare.test.ts (f7e3cb543), on SqliteStorage.open(path:options:).
@Suite("PiSwiftDurableTests.SqlitePrefix")
struct SqlitePrefixTests {
    @Test("storage conformance under a prefix", arguments: sqlitePrefixedCases)
    func prefixedConformance(_ storageCase: StorageConformanceCase) async throws { try await storageCase.run() }

    @Test("namespaces tables and indexes with a prefix across reopen")
    func prefixAcrossReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        try prefixHostTables(path, ["tasks"])
        let storage = try await SqliteStorage.open(path: path, options: .init(prefix: "pi_"))
        try await prefixRoot(storage)
        try await storage.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path, options: .init(prefix: "pi_"))
        #expect(try await reopened.conversation(rootConversationID, context: .background) == ConversationRecord(id: rootConversationID))
        let next: EntryID = try await reopened.mintId()
        #expect(next.rawValue == 2)
        try await reopened.close(context: .background)
        let names = try prefixNames(path)
        #expect(names.filter { !$0.hasPrefix("pi_") } == ["tasks"])
        #expect(names.contains("pi_tasks"))
    }

    @Test("rejects an invalid prefix before creating the database")
    func invalidPrefixCreatesNothing() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested")
        do {
            _ = try await SqliteStorage.open(path: nested.appendingPathComponent("storage.sqlite").path, options: .init(prefix: "bad-prefix"))
            Issue.record("An invalid prefix opened storage")
        } catch { #expect(String(describing: error) == "Invalid SQLite schema prefix \"bad-prefix\"") }
        #expect(!FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("rejects invalid and reserved prefixes")
    func invalidAndReservedPrefixes() async {
        for prefix in ["", "bad-prefix", "1pi_", "pi é_"] { #expect(await prefixFailure(prefix)?.contains("Invalid") == true, "\(prefix)") }
        for prefix in ["sqlite_pi_", "SQLite_pi_"] { #expect(await prefixFailure(prefix)?.hasSuffix("is reserved") == true, "\(prefix)") }
        for prefix in ["pi_", "_", "Pi2_"] { #expect(await prefixFailure(prefix) == nil, "\(prefix)") }
    }

    @Test("keeps schema names unprefixed by default")
    func unprefixedByDefault() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        try await SqliteStorage.open(path: path).close(context: .background)
        #expect(try sqliteSchemaVersion(path, table: "durable_schema") == 2)
        #expect(!(try prefixNames(path)).contains("pi_durable_schema"))
    }

    @Test("prefixes pi's tables and indexes without changing host tables")
    func hostTablesUnchanged() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        try prefixHostTables(path, ["host_notes", "tasks"])
        try await SqliteStorage.open(path: path, options: .init(prefix: "pi_")).close(context: .background)
        let names = try prefixNames(path)
        #expect(names.contains("host_notes") && names.contains("tasks") && !names.contains("pi_host_notes"))
        let piNames = names.filter { !["host_notes", "tasks"].contains($0) }
        #expect(piNames.count > 10)
        #expect(piNames.allSatisfy { $0.hasPrefix("pi_") })
        #expect(piNames.contains("pi_tasks") && piNames.contains("pi_durable_schema"))
    }

    @Test("isolates two prefixes in one database file, opened and written concurrently")
    func concurrentPrefixes() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        // Two connections that open a new file at once race to switch it to WAL, and one can fail with
        // "database is locked" (AppleSqliteDatabase, with or without prefixes), so the file exists first.
        try AppleSqliteDatabase(path: path).close()
        async let opening = SqliteStorage.open(path: path, options: .init(prefix: "first_"))
        async let openingSecond = SqliteStorage.open(path: path, options: .init(prefix: "second_"))
        let (first, second) = try await (opening, openingSecond)
        let entry = try EntryID(2)
        async let firstCommit: Void = prefixRoot(first, entry: (entry, "first"))
        async let secondCommit: Void = prefixRoot(second, entry: (entry, "second"))
        _ = try await (firstCommit, secondCommit)
        #expect(try await first.entry(entry, context: .background)?.entry.kind == "first")
        #expect(try await second.entry(entry, context: .background)?.entry.kind == "second")
        try await first.close(context: .background); try await second.close(context: .background)
    }

    // Swift-only: a prefixed table or index has the default one's columns, so a TypeScript storage opened with the
    // same prefix reads it as an unprefixed one.
    @Test("renders the default schema's columns under a prefix")
    func prefixedStructureMatchesDefault() throws {
        let plain = try AppleSqliteDatabase(path: ":memory:"), prefixed = try AppleSqliteDatabase(path: ":memory:")
        defer { try? plain.close(); try? prefixed.close() }
        try applySqliteMigrations(plain)
        try applySqliteMigrations(prefixed, schema: SqliteSchema(prefix: "pi_"))
        let objects = try plain.all("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
        #expect(objects.count == 25)
        for object in objects {
            let type = try object.sqliteText("type"), name = try object.sqliteText("name")
            let pragma = type == "table" ? "table_info" : "index_xinfo"
            let columns = try plain.all("SELECT * FROM pragma_\(pragma)('\(name)')")
            #expect(!columns.isEmpty)
            #expect(try prefixed.all("SELECT * FROM pragma_\(pragma)('pi_\(name)')") == columns, "\(name)")
        }
        #expect(try prefixed.all("SELECT name FROM sqlite_master WHERE name NOT LIKE 'pi_%' AND name NOT LIKE 'sqlite_%'").isEmpty)
    }
}

private func sqliteSchemaVersion(_ path: String, table: String) throws -> Int64? {
    let db = try AppleSqliteDatabase(path: path)
    defer { try? db.close() }
    return try db.get("SELECT version FROM \(table)")?["version"]?.integerValue
}
