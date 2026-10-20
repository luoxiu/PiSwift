// Ports upstream `packages/chord/test/telemetry-sqlite-store.test.ts` at d9025a5f5. The Durable Object conformance run
// has no counterpart: there is no Durable Object driver.

import Foundation
import Testing
import PiSwiftChord
import PiSwiftTelemetry
import TelemetryTestSupport

private let sqliteStoreConformance = telemetryStoreConformance { clock in
    let db = try TelemetryTestDatabase()
    let context = try await createSqliteTelemetry(db, clock: clock)
    return try TelemetryStoreFixture(
        context: context, store: context, flush: { try await context.flush() },
        dispose: {
            do {
                try await context.close()
            } catch {
                try? db.close()
                throw error
            }
            try db.close()
        })
}

@Suite("PiSwiftChordTests.SQLite telemetry store conformance")
struct SqliteTelemetryStoreConformanceTests {
    @Test(arguments: sqliteStoreConformance)
    func conformance(_ testCase: TelemetryStoreConformanceCase) async throws {
        try await testCase.run()
    }
}

@Suite("PiSwiftChordTests.SQLite telemetry reads")
struct SqliteTelemetryStoreTests {
    @Test func usesTwoSpanQueriesForAPageNotOneQueryPerTrace() async throws {
        try await withSqliteTelemetry { f in
            for _ in 0..<25 { await f.telemetry.startSpan(SpanOptions(name: "root")) { _ in } }
            try await f.telemetry.flush()
            f.db.resetCounts()
            #expect(try await f.telemetry.findTraces(TraceQuery(limit: 20)).traces.count == 20)
            #expect(f.db.transactionQueries == 2)
            f.db.resetCounts()
            #expect(try await f.telemetry.findTraces(TraceQuery(limit: 1)).traces.count == 1)
            #expect(f.db.transactionQueries == 2)
        }
    }

    @Test func readsCommittedRowsWithoutImplicitlyFlushingIncludingAfterClose() async throws {
        try await withSqliteTelemetry { f in
            await f.telemetry.startSpan(SpanOptions(name: "pending")) { _ in }
            #expect(try await f.telemetry.findTraces().traces.isEmpty)
            f.metrics.counter("partial").add(2)
            #expect(try await f.telemetry.findMetrics(MetricQuery(name: "partial")).isEmpty)
            try await f.telemetry.close()
            let trace = try #require(try await f.telemetry.findTraces().traces.first)
            #expect(try await f.telemetry.getTrace(trace.traceId)?.spans.first?.name == "pending")
            let metrics = try await f.telemetry.findMetrics(MetricQuery(name: "partial"))
            #expect(metrics.map { [Double($0.count), $0.sum] } == [[1, 2]])
        }
    }

    @Test func keepsSurvivingDescendantsDiscoverableAfterAStoredParentIsRemoved() async throws {
        try await withSqliteTelemetry { f in
            await f.telemetry.startSpan(SpanOptions(name: "root")) { root in
                await root.startSpan(SpanOptions(name: "child")) { _ in }
            }
            try await f.telemetry.flush()
            let original = try #require(try await f.telemetry.findTraces().traces.first)
            let parent = try #require(original.spans.first { $0.name == "root" })
            try f.db.execute("DELETE FROM telemetry_spans WHERE id = ?", [.text(parent.id)])
            let trace = try #require(try await f.telemetry.findTraces().traces.first)
            #expect(trace.traceId == original.traceId)
            #expect(trace.spans.count == 1)
            #expect(trace.spans.first?.name == "child")
            #expect(trace.spans.first?.parentId == parent.id)
            #expect(try await f.telemetry.getTrace(original.traceId)?.spans.count == 1)
        }
    }

    // Swift addition: rows another implementation wrote read back as upstream's `JSON.parse` would give them, with a
    // link that has no attributes, a `null` attribute (a non-finite number), and integer-typed time columns.
    @Test func readsRowsOtherWritersStored() async throws {
        try await withSqliteTelemetry { f in
            try f.db.execute(
                "INSERT INTO telemetry_spans VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text("s:1"), .text("t"), .null, .text("root"), .integer(1000), .integer(1010),
                 .text(#"{"n":null,"tags":["a"],"empty":[]}"#), .text(#"[{"name":"e","time_ms":1.5,"attributes":{}}]"#),
                 .text(#"[{"trace_id":"u","span_id":"u:1"}]"#), .text(#"{"status":"error"}"#)])
            #expect(try await f.telemetry.getTrace("t") == StoredTrace(traceId: "t", spans: [StoredSpan(
                id: "s:1", traceId: "t", name: "root", startedMs: 1000, endedMs: 1010,
                attributes: ["tags": .stringArray(["a"]), "empty": .stringArray([])],
                events: [StoredSpan.Event(name: "e", timeMs: 1.5)],
                links: [StoredSpan.Link(traceId: "u", spanId: "u:1")],
                status: .error(nil))]))
            try f.db.execute("UPDATE telemetry_spans SET status = 'not json'")
            await #expect(throws: (any Error).self) { try await f.telemetry.getTrace("t") }
        }
    }

    // Swift addition: upstream's cases query a number against a boolean, not a boolean against a number; this checks
    // that `true` does not match `1` (and `false` not `0`) in span and metric attributes.
    @Test func matchesBooleansOnlyWithBooleans() async throws {
        try await withSqliteTelemetry { f in
            await f.telemetry.startSpan(SpanOptions(name: "number", attributes: ["flag": 1, "off": 0])) { _ in }
            await f.telemetry.startSpan(SpanOptions(name: "boolean", attributes: ["flag": true, "off": false])) { _ in }
            f.metrics.counter("flags").add(1, attributes: ["flag": 1])
            f.metrics.counter("flags").add(2, attributes: ["flag": true])
            try await f.telemetry.close()
            #expect(try await f.telemetry.findTraces(TraceQuery(attributes: ["flag": true])).traces.map { $0.spans[0].name } == ["boolean"])
            #expect(try await f.telemetry.findTraces(TraceQuery(attributes: ["off": false])).traces.map { $0.spans[0].name } == ["boolean"])
            #expect(try await f.telemetry.findMetrics(MetricQuery(name: "flags", attributes: ["flag": true])).map(\.sum) == [2])
        }
    }
}
