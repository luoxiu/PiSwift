// Runs the SQLite telemetry code block of `Sources/PiSwiftTelemetry/README.md`, upstream's Chord README section
// "SQLite telemetry" at d9025a5f5.

import Foundation
import Testing
import PiSwiftChord
import PiSwiftTelemetry

private struct Account: Sendable { let id: String }
private func readAccount(_ id: String) async throws -> Account? { Account(id: id) }

@Suite("PiSwiftChordTests.SQLite telemetry README")
struct SqliteTelemetryReadmeTests {
    @Test func sqliteTelemetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("telemetry.sqlite").path
        var printed: [String] = []
        func print(_ text: String) { printed.append(text) }
        // README: sqlite-telemetry
        let telemetry = try await createSqliteTelemetry(path: databasePath)
        try await telemetry.startSpan(SpanOptions(name: "app.request")) { span in
            span.addEvent("request.accepted")
            try await span.startSpan(SpanOptions(name: "app.read")) { _ in try await readAccount("123") }
        }
        try await telemetry.flush()
        let traces = try await telemetry.findTraces(TraceQuery(name: "app.request", limit: 10)).traces
        for trace in traces { print(renderTrace(trace.spans)) }
        try await telemetry.close()
        // README: end
        #expect(printed.count == 1)
        let lines = printed.first?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.count == 3)
        #expect(lines.first?.hasPrefix("app.request (") == true)
        #expect(lines.dropFirst().first?.hasPrefix("  · request.accepted (+") == true)
        #expect(lines.last?.hasPrefix("  app.read (") == true)
    }
}
