// Ports upstream `packages/chord/test/telemetry-sqlite.test.ts` at d9025a5f5. Upstream's `vi.spyOn(db, "transaction")`
// is `TelemetryTestDatabase`, its `vi.spyOn(Date, "now")` and fake timers are a `ManualTelemetryClock`.

import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftTelemetry
import PiSwiftTelemetryTesting
import TelemetryTestSupport

/// A recorder over a spy database, as upstream's `fixture()`. The clock fires the flush timer only when a test
/// advances it.
struct SqliteTelemetryFixture: Sendable {
    let db: TelemetryTestDatabase
    let telemetry: any SqliteTelemetry
    let clock: ManualTelemetryClock

    var metrics: any TelemetryMetrics { telemetry.metrics! }
    var propagation: any TelemetryPropagation { telemetry.propagation! }

    static func make(_ options: SqliteTelemetryOptions = .init(), clock: ManualTelemetryClock? = nil) async throws -> Self {
        let clock = clock ?? ManualTelemetryClock(now: TelemetryClock.system.now())
        let db = try TelemetryTestDatabase()
        let telemetry = try await createSqliteTelemetry(db, options: options, clock: clock.clock)
        db.resetCounts()
        return SqliteTelemetryFixture(db: db, telemetry: telemetry, clock: clock)
    }

    /// Upstream's `[Symbol.asyncDispose]`: close the recorder, then the database.
    func dispose() async throws {
        do {
            try await telemetry.close()
        } catch {
            try? db.close()
            throw error
        }
        try db.close()
    }

    /// The spans table as normalized snapshots, as upstream's `getSpans()` builds them.
    func getSpans() async throws -> [RecordedTelemetrySpan] {
        try await telemetry.flush()
        return try db.rows("SELECT rowid, * FROM telemetry_spans").map { row in
            let id = row["id"]?.textValue ?? ""
            let traceId = row["trace_id"]?.textValue ?? ""
            let parent = row["parent_id"]?.textValue
            let parts = id.split(separator: ":"), parentParts = parent?.split(separator: ":")
            return RecordedTelemetrySpan(
                id: Int(parts[1])!,
                parentId: parentParts?.first == parts.first ? parentParts.flatMap { Int($0[1]) } : nil,
                context: ["pi-sqlite-span": id, "pi-sqlite-trace": traceId],
                parentContext: parent.map { ["pi-sqlite-span": $0, "pi-sqlite-trace": traceId] },
                links: try json(row, "links").arrayValue!.map { link in
                    RecordedTelemetryLink(
                        context: ["pi-sqlite-span": link["span_id"]?.stringValue ?? "",
                                  "pi-sqlite-trace": link["trace_id"]?.stringValue ?? ""],
                        attributes: telemetryAttributes(link["attributes"]))
                },
                name: row["name"]?.textValue ?? "",
                attributes: telemetryAttributes(try json(row, "attributes")),
                events: try json(row, "events").arrayValue!.map { event in
                    RecordedTelemetryEvent(name: event["name"]?.stringValue ?? "", attributes: telemetryAttributes(event["attributes"]))
                },
                status: telemetryStatus(try json(row, "status")),
                settled: true,
                endSequence: row["rowid"]?.integerValue.map(Int.init))
        }.sorted { $0.id < $1.id }
    }
}

/// Runs `body` with a fresh fixture and disposes it afterwards, as upstream's `await using`.
func withSqliteTelemetry(
    _ options: SqliteTelemetryOptions = .init(),
    clock: ManualTelemetryClock? = nil,
    _ body: (SqliteTelemetryFixture) async throws -> Void
) async throws {
    let fixture = try await SqliteTelemetryFixture.make(options, clock: clock)
    do {
        try await body(fixture)
    } catch {
        try? await fixture.dispose()
        throw error
    }
    try await fixture.dispose()
}

func json(_ row: SqliteRow, _ column: String) throws -> JSONValue {
    try JSONValue(jsonText: row[column]?.textValue ?? "null")
}

extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

func telemetryAttributes(_ value: JSONValue?) -> [String: AttributeValue] {
    var attributes: [String: AttributeValue] = [:]
    for (key, value) in value?.objectValue ?? [:] {
        switch value {
        case .string(let text): attributes[key] = .string(text)
        case .number(let number): attributes[key] = .number(number)
        case .bool(let flag): attributes[key] = .boolean(flag)
        case .array(let values):
            let strings = values.compactMap(\.stringValue), numbers = values.compactMap(\.numberValue)
            let flags = values.compactMap(\.boolValue)
            if strings.count == values.count { attributes[key] = .stringArray(strings) }
            else if numbers.count == values.count { attributes[key] = .numberArray(numbers) }
            else if flags.count == values.count { attributes[key] = .booleanArray(flags) }
        default: break
        }
    }
    return attributes
}

func telemetryStatus(_ value: JSONValue) -> SpanStatus {
    guard value["status"]?.stringValue == "error" else { return .ok }
    guard let error = value["error"] else { return .error(nil) }
    return .error(name: error["name"]?.stringValue ?? "", message: error["message"]?.stringValue ?? "")
}

/// Upstream's `Promise.withResolvers<void>()` for the test's own awaits.
final class TelemetryTestGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
}

final class TelemetrySpanBox: Sendable {
    private let state = Mutex<(any TelemetrySpan)?>(nil)
    var span: (any TelemetrySpan)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A thrown value compared by identity, upstream's `rejects.toBe(error)`.
final class TelemetryTestFailure: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Polls `condition` for up to five seconds: the flush timer's tick starts its flush in a task.
func eventually(_ condition: () throws -> Bool) async throws -> Bool {
    for _ in 0..<500 {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try condition()
}

private func names(_ rows: [SqliteRow]) -> [String] { rows.compactMap { $0["name"]?.textValue } }

private let sqliteConformance = createTelemetryAdapterConformance {
    let fixture = try await SqliteTelemetryFixture.make()
    return TelemetryAdapterFixture(
        context: fixture.telemetry, propagation: fixture.propagation,
        getSpans: { try await fixture.getSpans() }, dispose: { try await fixture.dispose() })
}.filter { $0.group != "metrics" }

@Suite("PiSwiftChordTests.SQLite telemetry span and propagation conformance")
struct SqliteTelemetryConformanceTests {
    @Test(arguments: sqliteConformance)
    func conformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
        try await testCase.run()
    }
}

@Suite("PiSwiftChordTests.SQLite telemetry buffering and aggregation")
struct SqliteTelemetryTests {
    // Swift: the spy counts every call on the database, not only transactions.
    @Test func doesNotExecuteSQLWhileRecordingAndStoresOnlySettledSpans() async throws {
        try await withSqliteTelemetry { f in
            let started = TelemetryTestGate(), gate = TelemetryTestGate(), active = TelemetrySpanBox()
            let telemetry = f.telemetry, metrics = f.metrics
            let pending = Task {
                await telemetry.startSpan(SpanOptions(name: "active")) { span in
                    active.span = span
                    span.addEvent("begin")
                    metrics.counter("calls").add(1)
                    started.open()
                    await gate.wait()
                }
            }
            await started.wait()
            #expect(f.db.calls == 0)
            try await f.telemetry.flush()
            #expect(try f.db.rows("SELECT * FROM telemetry_spans").isEmpty)
            gate.open()
            await pending.value
            #expect(f.db.transactions == 1)
            #expect(f.db.calls == 1)
            try #require(active.span).addEvent("late")
            try await f.telemetry.flush()
            let row = try #require(try f.db.rows("SELECT * FROM telemetry_spans").first)
            let started_ms = try #require(row["started_ms"].flatMap(sqliteNumber))
            #expect(try #require(row["ended_ms"].flatMap(sqliteNumber)) >= started_ms)
            let events = try json(row, "events").arrayValue ?? []
            #expect(events.count == 1)
            #expect(events.first?["name"] == "begin")
            #expect(events.first?["time_ms"]?.numberValue != nil)
            #expect(events.first?["attributes"] == .object([:]))
        }
    }

    @Test func aggregatesCanonicalSeriesByIntervalAndWritesPartialIntervalsOnlyOnClose() async throws {
        try await withSqliteTelemetry(clock: ManualTelemetryClock(now: 20_001)) { f in
            let metric = f.metrics.histogram("duration", options: HistogramOptions(unit: "ms", boundaries: [1, 10]))
            var attrs: SpanAttributes = ["b": .stringArray(["original"]), "a": true]
            metric.record(2, attributes: attrs)
            attrs["b"] = .stringArray(["original", "changed"])
            metric.record(8, attributes: ["a": true, "b": .stringArray(["original"])])
            f.metrics.upDownCounter("active").add(-1)
            try await f.telemetry.flush()
            #expect(try f.db.rows("SELECT * FROM telemetry_metrics").isEmpty)
            f.clock.now = 30_001
            metric.record(4, attributes: ["b": .stringArray(["original"]), "a": true])
            try await f.telemetry.flush()
            let rows = try f.db.rows("SELECT * FROM telemetry_metrics ORDER BY name")
            #expect(rows.count == 2)
            #expect(rows.first?["name"] == .text("active"))
            #expect(rows.first?["kind"] == .text("upDownCounter"))
            #expect(rows.first?["unit"] == .null)
            #expect(rows.first?["count"] == .integer(1))
            #expect(rows.first.map { [$0["sum"], $0["min"], $0["max"]] } == [.real(-1), .real(-1), .real(-1)])
            #expect(rows.last?["interval_ms"] == .integer(20_000))
            #expect(rows.last?["name"] == .text("duration"))
            #expect(rows.last?["kind"] == .text("histogram"))
            #expect(rows.last?["unit"] == .text("ms"))
            #expect(rows.last?["attributes"] == .text(#"{"a":true,"b":["original"]}"#))
            #expect(rows.last?["count"] == .integer(2))
            #expect(rows.last.map { [$0["sum"], $0["min"], $0["max"]] } == [.real(10), .real(2), .real(8)])
            try await f.telemetry.close()
            #expect(try f.db.rows("SELECT count, sum FROM telemetry_metrics WHERE interval_ms = 30000")
                == [["count": .integer(1), "sum": .real(4)]])
        }
    }

    @Test func separatesKindNameUnitAndCallerAttributesWithoutRetainingDescriptionsOrBoundaries() async throws {
        try await withSqliteTelemetry { f in
            f.metrics.counter("same").add(1)
            f.metrics.counter("same", options: InstrumentOptions(unit: "By")).add(2)
            f.metrics.upDownCounter("same").add(3)
            f.metrics.counter("other").add(4)
            f.metrics.counter("same").add(5, attributes: ["method": "read"])
            f.metrics.histogram("same", options: HistogramOptions(description: "first", boundaries: [1])).record(6)
            f.metrics.histogram("same", options: HistogramOptions(description: "second", boundaries: [2])).record(7)
            try await f.telemetry.close()
            let rows = try f.db.rows("SELECT * FROM telemetry_metrics")
            #expect(rows.count == 6)
            let histogram = try #require(rows.first { $0["kind"] == .text("histogram") })
            #expect([histogram["count"], histogram["sum"], histogram["min"], histogram["max"]]
                == [.integer(2), .real(13), .real(6), .real(7)])
        }
    }

    @Test func strictlyBoundsQueuedSpansIncludingTheInFlightBatchAndBoundsPendingMetricSeries() async throws {
        try await withSqliteTelemetry(SqliteTelemetryOptions(maxQueuedSpans: 1)) { f in
            await f.telemetry.startSpan(SpanOptions(name: "first")) { _ in }
            f.metrics.counter("first").add(1)
            f.metrics.counter("first").add(2)
            f.metrics.counter("overflow").add(3)
            let entered = TelemetryTestGate(), release = TelemetryTestLatch()
            f.db.onTransaction {
                entered.open()
                release.wait()
            }
            let telemetry = f.telemetry
            let flushing = Task { try await telemetry.flush() }
            await entered.wait()
            await f.telemetry.startSpan(SpanOptions(name: "overflow")) { _ in }
            #expect(f.telemetry.droppedSpans == 1)
            #expect(f.telemetry.droppedMeasurements == 1)
            release.open()
            try await flushing.value
            await f.telemetry.startSpan(SpanOptions(name: "after")) { _ in }
            try await f.telemetry.close()
            #expect(names(try f.db.rows("SELECT name FROM telemetry_spans ORDER BY rowid")) == ["first", "after"])
            #expect(try f.db.rows("SELECT name, count, sum FROM telemetry_metrics")
                == [["name": .text("first"), "count": .integer(2), "sum": .real(3)]])
        }
    }

    @Test func countsInFlightMetricIntervalsAgainstCapacityUntilCommit() async throws {
        try await withSqliteTelemetry(SqliteTelemetryOptions(maxQueuedSpans: 1), clock: ManualTelemetryClock(now: 20_001)) { f in
            f.metrics.counter("calls").add(1)
            f.clock.now = 30_001
            let entered = TelemetryTestGate(), release = TelemetryTestLatch()
            f.db.onTransaction {
                entered.open()
                release.wait()
            }
            let telemetry = f.telemetry
            let flushing = Task { try await telemetry.flush() }
            await entered.wait()
            f.metrics.counter("calls").add(2)
            #expect(f.telemetry.droppedMeasurements == 1)
            release.open()
            try await flushing.value
            f.metrics.counter("calls").add(3)
            try await f.telemetry.close()
            #expect(try f.db.rows("SELECT interval_ms, sum FROM telemetry_metrics ORDER BY interval_ms") == [
                ["interval_ms": .integer(20_000), "sum": .real(1)],
                ["interval_ms": .integer(30_000), "sum": .real(3)],
            ])
        }
    }

    // Swift: the timer's tick starts its flush in a task, so the test polls for the rows that flush writes.
    @Test func flushesOncePerSecondAndRetainsOnlyRowsInsideTheRetentionWindow() async throws {
        try await withSqliteTelemetry(SqliteTelemetryOptions(retentionMs: 20_000), clock: ManualTelemetryClock(now: 20_001)) { f in
            await f.telemetry.startSpan(SpanOptions(name: "old")) { _ in }
            f.metrics.counter("old").add(1)
            f.clock.advance(by: 1000)
            #expect(try await eventually { names(try f.db.rows("SELECT name FROM telemetry_spans")) == ["old"] })
            f.clock.now = 50_001
            await f.telemetry.startSpan(SpanOptions(name: "recent")) { _ in }
            f.metrics.counter("recent").add(1)
            f.clock.advance(by: 1000)
            #expect(try await eventually { names(try f.db.rows("SELECT name FROM telemetry_spans")) == ["recent"] })
            #expect(try f.db.rows("SELECT name FROM telemetry_metrics").isEmpty)
            try await f.telemetry.close()
            #expect(names(try f.db.rows("SELECT name FROM telemetry_metrics")) == ["recent"])
        }
    }

    // Swift: `close()` returns no promise to compare, so the test calls it twice and awaits both.
    @Test func serializesConcurrentFlushAndCloseWithoutLosingMeasurementsRecordedDuringWrites() async throws {
        try await withSqliteTelemetry(clock: ManualTelemetryClock(now: 20_001)) { f in
            f.metrics.counter("calls").add(1)
            f.clock.now = 30_001
            let entered = TelemetryTestGate(), release = TelemetryTestLatch()
            f.db.onTransaction {
                entered.open()
                release.wait()
            }
            let telemetry = f.telemetry
            let first = Task { try await telemetry.flush() }
            await entered.wait()
            f.metrics.counter("calls").add(2)
            let second = Task { try await telemetry.flush() }
            let close = Task { try await telemetry.close() }
            let closeAgain = Task { try await telemetry.close() }
            release.open()
            for task in [first, second, close, closeAgain] { try await task.value }
            #expect(f.db.maximumConcurrentTransactions == 1)
            #expect(try f.db.rows("SELECT interval_ms, sum FROM telemetry_metrics ORDER BY interval_ms") == [
                ["interval_ms": .integer(20_000), "sum": .real(1)],
                ["interval_ms": .integer(30_000), "sum": .real(2)],
            ])
        }
    }

    @Test func closeDoesNotWaitForActiveBusinessCallbacksIgnoresLateCompletionsAndLeavesTheDatabaseOpen() async throws {
        try await withSqliteTelemetry { f in
            let started = TelemetryTestGate(), release = TelemetryTestGate(), active = TelemetrySpanBox()
            let telemetry = f.telemetry
            let pending = Task {
                await telemetry.startSpan(SpanOptions(name: "active")) { span in
                    active.span = span
                    started.open()
                    await release.wait()
                }
            }
            await started.wait()
            await f.telemetry.startSpan(SpanOptions(name: "settled")) { _ in }
            try await f.telemetry.close()
            #expect(names(try f.db.rows("SELECT name FROM telemetry_spans")) == ["settled"])
            let span = try #require(active.span)
            span.addEvent("late")
            await span.startSpan(SpanOptions(name: "late-child")) { _ in }
            f.metrics.counter("late").add(1)
            release.open()
            await pending.value
            try await f.telemetry.flush()
            #expect(names(try f.db.rows("SELECT name FROM telemetry_spans")) == ["settled"])
            #expect(try f.db.rows("SELECT * FROM telemetry_metrics").isEmpty)
        }
    }

    @Test func stopsPermanentlyAfterAWriteFailureAndReportsTheIdenticalErrorWithoutRetry() async throws {
        let db = try TelemetryTestDatabase()
        defer { try? db.close() }
        let telemetry = try await createSqliteTelemetry(db, clock: ManualTelemetryClock(now: 20_000).clock)
        await telemetry.startSpan(SpanOptions(name: "queued")) { _ in }
        let error = TelemetryTestFailure("write failure")
        db.resetCounts()
        db.onTransaction { throw error }
        #expect(await thrown { try await telemetry.flush() } === error)
        #expect(await telemetry.startSpan(SpanOptions(name: "ignored")) { _ in 1 } == 1)
        telemetry.metrics?.counter("ignored").add(1)
        #expect(await thrown { try await telemetry.flush() } === error)
        #expect(await thrown { try await telemetry.close() } === error)
        #expect(await thrown { try await telemetry.close() } === error)
        #expect(db.transactions == 1)
        #expect(try db.rows("SELECT * FROM telemetry_spans").isEmpty)
    }

    // Swift: upstream rejects with `undefined`, which a Swift error cannot be; the test also checks that the timer is
    // cancelled, which the transaction count alone does not show (a later tick would find the failure first).
    @Test func remembersABackgroundWriteFailureAndStopsItsTimer() async throws {
        let db = try TelemetryTestDatabase()
        defer { try? db.close() }
        let clock = ManualTelemetryClock(now: 20_000)
        let telemetry = try await createSqliteTelemetry(db, clock: clock.clock)
        let error = TelemetryTestFailure("background")
        db.resetCounts()
        db.onTransaction { throw error }
        #expect(clock.activeIntervals == 1)
        clock.advance(by: 1000)
        #expect(try await eventually { clock.activeIntervals == 0 })
        #expect(await thrown { try await telemetry.flush() } === error)
        #expect(await thrown { try await telemetry.close() } === error)
        clock.advance(by: 5000)
        #expect(db.transactions == 1)
    }

    @Test func rollsBackSpansAndMetricAggregatesTogetherOnSqlFailure() async throws {
        let db = try TelemetryTestDatabase()
        defer { try? db.close() }
        let telemetry = try await createSqliteTelemetry(db, clock: ManualTelemetryClock(now: 20_000).clock)
        await telemetry.startSpan(SpanOptions(name: "rollback")) { _ in }
        telemetry.metrics?.counter("rollback").add(1)
        try db.execute("DROP TABLE telemetry_metrics")
        await #expect(throws: SqliteError.self) { try await telemetry.close() }
        #expect(try db.rows("SELECT * FROM telemetry_spans").isEmpty)
    }

    @Test func reusesMigrationsPreservesIdentitiesAcrossReopenAndMergesAggregatesFromMultipleAdapters() async throws {
        let db = try TelemetryTestDatabase()
        defer { try? db.close() }
        let clock = ManualTelemetryClock(now: 20_000)
        let first = try await createSqliteTelemetry(db, clock: clock.clock)
        var carrier: TelemetryCarrier?
        await first.startSpan(SpanOptions(name: "parent")) { span in carrier = first.propagation?.inject(span) }
        first.metrics?.counter("shared").add(2)
        try await first.close()
        let second = try await createSqliteTelemetry(db, clock: clock.clock)
        let propagation = try #require(second.propagation)
        await propagation.extract(carrier).startSpan(SpanOptions(name: "child")) { _ in }
        second.metrics?.counter("shared").add(4)
        try await second.close()
        let rows = try db.rows("SELECT * FROM telemetry_spans ORDER BY rowid")
        #expect(rows[1]["parent_id"] == rows[0]["id"])
        #expect(rows[1]["trace_id"] == rows[0]["trace_id"])
        #expect(rows[0]["trace_id"] == rows[0]["id"])
        #expect(rows[1]["id"] != rows[0]["id"])
        #expect(try db.rows("SELECT count, sum, min, max FROM telemetry_metrics")
            == [["count": .integer(2), "sum": .real(6), "min": .real(2), "max": .real(4)]])
    }

    // Swift addition: the public entry opens its own file, and the store still reads it after `close()`.
    @Test func opensItsOwnFileAndReadsCommittedRowsAfterClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested/telemetry.sqlite").path
        let telemetry = try await createSqliteTelemetry(path: path)
        await telemetry.startSpan(SpanOptions(name: "app.request")) { span in
            span.addEvent("request.accepted")
        }
        try await telemetry.close()
        let trace = try #require(try await telemetry.findTraces(TraceQuery(name: "app.request")).traces.first)
        #expect(trace.spans.map(\.name) == ["app.request"])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // Swift addition: the JSON columns are hand-written, so their text is what upstream's `JSON.stringify` writes:
    // the metric series key with sorted attribute keys (array indexes first, as JavaScript objects order them), the
    // status shapes, and events and links in upstream's member order.
    @Test func writesUpstreamsJSONColumnText() async throws {
        try await withSqliteTelemetry(clock: ManualTelemetryClock(now: 20_001, monotonic: 5)) { f in
            f.metrics.counter("bytes", options: InstrumentOptions(unit: "By"))
                .add(1, attributes: ["z": "a\"b", "10": 1.5, "9": .numberArray([1, .nan]), "a": false])
            let target = TelemetrySpanBox()
            await f.telemetry.startSpan(SpanOptions(name: "target")) { span in target.span = span }
            let targetSpan = try #require(target.span)
            await f.telemetry.startSpan(SpanOptions(
                name: "source", attributes: ["b": 1, "a": "x"], links: [SpanLink(context: targetSpan, attributes: ["reason": "r"])]
            )) { span in
                span.addEvent("e", attributes: ["n": 1])
                span.setStatus(.error(name: "Expected", message: "m"))
            }
            await #expect(throws: TelemetryTestFailure.self) {
                try await f.telemetry.startSpan(SpanOptions(name: "thrown")) { _ in throw TelemetryTestFailure("boom") }
            }
            try await f.telemetry.close()
            let metric = try #require(try f.db.rows("SELECT series_key, attributes FROM telemetry_metrics").first)
            let attributes = #"{"9":[1,null],"10":1.5,"a":false,"z":"a\"b"}"#
            #expect(metric["attributes"] == .text(attributes))
            #expect(metric["series_key"] == .text(#"["bytes","counter","By","# + javaScriptQuotedForTest(attributes) + "]"))
            let spans = try f.db.rows("SELECT * FROM telemetry_spans ORDER BY rowid")
            let target_id = try #require(spans[0]["id"]?.textValue)
            #expect(spans[0]["status"] == .text(#"{"status":"ok"}"#))
            #expect(spans[1]["attributes"] == .text(#"{"a":"x","b":1}"#))
            #expect(spans[1]["events"] == .text(#"[{"name":"e","time_ms":0,"attributes":{"n":1}}]"#))
            #expect(spans[1]["links"] == .text(#"[{"trace_id":"\#(target_id)","span_id":"\#(target_id)","attributes":{"reason":"r"}}]"#))
            #expect(spans[1]["status"] == .text(#"{"status":"error","error":{"name":"Expected","message":"m"}}"#))
            #expect(spans[2]["status"] == .text(#"{"status":"error","error":{"name":"TelemetryTestFailure","message":"PiSwiftChordTests.TelemetryTestFailure"}}"#))
        }
    }
}

/// The value `operation` throws, for an identity check, or nil.
func thrown(_ operation: () async throws -> Void) async -> TelemetryTestFailure? {
    do {
        try await operation()
        return nil
    } catch {
        return error as? TelemetryTestFailure
    }
}

func sqliteNumber(_ value: SqliteValue) -> Double? {
    switch value {
    case .integer(let value): Double(value)
    case .real(let value): value
    default: nil
    }
}

private func javaScriptQuotedForTest(_ text: String) -> String {
    (try? JSONValue.string(text).jsonText()) ?? ""
}
