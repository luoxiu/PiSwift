/// Validate a prefix before using it as part of a SQLite identifier: ASCII letters, digits, and `_`, not starting with
/// a digit, and not SQLite's reserved `sqlite_` in any case.
package func validateSqliteSchemaPrefix(_ prefix: String) throws {
    let bytes = Array(prefix.utf8)
    func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
    guard let first = bytes.first, letter(first), bytes.allSatisfy({ letter($0) || (48...57).contains($0) }) else {
        throw SqliteFacadeError.invalidPrefix(prefix)
    }
    if prefix.lowercased().hasPrefix("sqlite_") { throw SqliteFacadeError.reservedPrefix(prefix) }
}
