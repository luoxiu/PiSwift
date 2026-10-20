/// One immutable step in a SQLite schema history.
package struct SqliteMigration: Sendable {
    package let version: Int
    package let statements: [String]
    package init(version: Int, statements: [String]) { self.version = version; self.statements = statements }
}

/// Apply all pending migrations in one transaction, tracking their version in the named metadata table. The table name
/// and the versions, contiguous from 1, are checked before any SQL runs.
package func applySqliteMigrations(_ database: any SqliteExecutor, migrations: [SqliteMigration], table: String) throws {
    try validateSqliteSchemaPrefix(table)
    for (index, migration) in migrations.enumerated() {
        guard migration.version == index + 1 else { throw SqliteFacadeError.invalidMigrations }
    }
    try database.transaction { transaction in
        try transaction.exec(
#"""
CREATE TABLE IF NOT EXISTS \#(table) (
			singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
			version INTEGER NOT NULL CHECK (version >= 0)
		) STRICT
"""#
        )
        try transaction.run("INSERT OR IGNORE INTO \(table) (singleton, version) VALUES (1, 0)")
        guard let row = try transaction.get("SELECT version FROM \(table) WHERE singleton = 1"),
              let version = row["version"]?.integerValue else { throw SqliteFacadeError.missingSchema }
        let currentVersion = migrations.last?.version ?? 0
        guard version <= currentVersion else {
            throw SqliteFacadeError.newerSchema(found: Int(version), supported: currentVersion)
        }
        for migration in migrations where migration.version > version {
            for statement in migration.statements { try transaction.exec(statement) }
            try transaction.run("UPDATE \(table) SET version = ? WHERE singleton = 1", [.integer(Int64(migration.version))])
        }
    }
}
