import Testing
import PiSwiftChord

private func noTables(_ database: AppleSqliteDatabase) throws -> Bool {
    try database.all("SELECT name FROM sqlite_schema").isEmpty
}

// chord/test/sqlite/migrations.test.ts (c268154ca): the generic runner that moved here from PiSwiftDurable.
@Suite("PiSwiftChordTests.SqliteMigrations")
struct SqliteMigrationRunnerTests {
    // :6.
    @Test func tracksIndependentHistoriesAndSkipsMigrationsAlreadyApplied() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        let first = [SqliteMigration(version: 1, statements: ["CREATE TABLE notes (body TEXT)", "INSERT INTO notes VALUES ('kept')"])]
        try applySqliteMigrations(database, migrations: first, table: "notes_schema")
        try applySqliteMigrations(database, migrations: first, table: "notes_schema")
        try applySqliteMigrations(database, migrations: [], table: "other_schema")
        try applySqliteMigrations(database, migrations: first + [SqliteMigration(version: 2, statements: ["ALTER TABLE notes ADD COLUMN title TEXT"])],
                                  table: "notes_schema")
        #expect(try database.all("SELECT body, title FROM notes") == [["body": .text("kept"), "title": .null]])
        #expect(try database.get("SELECT version FROM notes_schema") == ["version": .integer(2)])
        #expect(try database.get("SELECT version FROM other_schema") == ["version": .integer(0)])
        do { try applySqliteMigrations(database, migrations: first, table: "notes_schema"); Issue.record("Newer schema accepted") }
        catch { #expect(String(describing: error) == "SQLite schema version 2 is newer than supported version 1") }
    }

    // :31.
    @Test func rejectsInvalidMigrationVersionsBeforeTouchingTheDatabase() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        for versions in [[0], [2], [1, 3], [1, 1]] {
            do {
                try applySqliteMigrations(database, migrations: versions.map { SqliteMigration(version: $0, statements: []) }, table: "app_schema")
                Issue.record("Versions \(versions) accepted")
            } catch { #expect(String(describing: error).contains("contiguous versions starting at 1")) }
        }
        #expect(try noTables(database))
    }

    // :49.
    @Test func validatesPrefixesAndMigrationTableIdentifiersBeforeExecutingSQL() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        for prefix in ["", "1bad", "bad-prefix", "bad; DROP TABLE notes", "sqlite_app", "SQLITE_app"] {
            #expect(throws: SqliteFacadeError.self, "\(prefix)") { try validateSqliteSchemaPrefix(prefix) }
            #expect(throws: SqliteFacadeError.self, "\(prefix)") { try applySqliteMigrations(database, migrations: [], table: prefix) }
        }
        for prefix in ["pi_", "_private", "app2"] { #expect(throws: Never.self) { try validateSqliteSchemaPrefix(prefix) } }
        #expect(try noTables(database))
    }

    // :64.
    @Test func rollsBootstrapAndEveryPendingMigrationBackTogether() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        let first = SqliteMigration(version: 1, statements: ["CREATE TABLE migration_first (value TEXT) STRICT", "INSERT INTO migration_first (value) VALUES ('retained')"])
        let second = SqliteMigration(version: 2, statements: ["CREATE TABLE migration_second (value TEXT) STRICT"])
        #expect(throws: (any Error).self) {
            try applySqliteMigrations(database, migrations: [first, SqliteMigration(version: 2, statements: second.statements + ["THIS IS NOT SQL"])],
                                      table: "app_schema")
        }
        #expect(try database.get("SELECT count(*) AS count FROM sqlite_schema WHERE name IN ('app_schema', 'migration_first', 'migration_second')") == ["count": .integer(0)])
        try applySqliteMigrations(database, migrations: [first, second], table: "app_schema")
        #expect(try database.get("SELECT version FROM app_schema WHERE singleton = 1") == ["version": .integer(2)])
        #expect(try database.get("SELECT value FROM migration_first") == ["value": .text("retained")])
    }
}
