// Ports upstream `packages/chord/src/telemetry-sqlite/index.ts` at d9025a5f5 (`@earendil-works/chord/telemetry-sqlite`).
// The store queries are in `SqliteTelemetryStore.swift`.

import Foundation
import Synchronization
import PiSwiftTelemetry

/// Retention and queue bounds of a SQLite telemetry recorder.
public struct SqliteTelemetryOptions: Sendable, Hashable {
    /// Retain seven days by default. Cleanup runs in the flush transaction. `.infinity` keeps every row.
    public var retentionMs: Double?
    /// Settled spans awaiting commit, including the in-flight batch. Defaults to 10,000.
    /// Also bounds pending metric interval/series pairs independently.
    public var maxQueuedSpans: Int?

    /// Creates options; nil keeps a default.
    public init(retentionMs: Double? = nil, maxQueuedSpans: Int? = nil) {
        self.retentionMs = retentionMs
        self.maxQueuedSpans = maxQueuedSpans
    }
}

/// A buffered SQLite recorder and the store that reads what it committed.
///
/// Its `metrics` and `propagation`, the `TelemetryContext` members, are never nil: the recorder's instruments and the
/// recorder itself.
public protocol SqliteTelemetry: TelemetryContext, TelemetryStore {
    /// Settled spans dropped because the queue was full.
    var droppedSpans: Int { get }
    /// Measurements of a new interval/series pair dropped because the pending pairs were at the bound.
    var droppedMeasurements: Int { get }
    /// Persist settled spans and completed ten-second metric intervals.
    func flush() async throws
    /// Stop recording and drain, including partial metric intervals. Does not close the database.
    func close() async throws
}

/// Opens or creates the SQLite file at `path` (in WAL mode, with its directory) and records into it. Recording never
/// performs SQL; a flush runs every second. Only settled spans are stored. Metrics aggregate count, sum, minimum, and
/// maximum per ten-second interval. A write failure permanently stops recording and is reported by `flush` and `close`.
///
/// The recorder owns this connection, where upstream's `createSqliteTelemetry(db)` takes one its caller owns. `close()`
/// leaves it open, so the store still reads committed rows; it closes when the recorder is released.
public func createSqliteTelemetry(path: String, options: SqliteTelemetryOptions = .init()) async throws -> any SqliteTelemetry {
    try await createSqliteTelemetry(AppleSqliteDatabase(path: path), options: options)
}

/// Records into `database`, upstream's `createSqliteTelemetry(db, options)`. The recorder serializes every call on
/// the database, so its caller must not use it concurrently without its own synchronization.
package func createSqliteTelemetry(
    _ database: sending any SqliteExecutor,
    options: SqliteTelemetryOptions = .init(),
    clock: TelemetryClock = .system
) async throws -> any SqliteTelemetry {
    let retention = options.retentionMs ?? 7 * 24 * 60 * 60 * 1000
    let capacity = options.maxQueuedSpans ?? 10_000
    try applySqliteMigrations(
        database,
        migrations: [
            SqliteMigration(version: 1, statements: [
                "CREATE TABLE telemetry_spans (id TEXT PRIMARY KEY, trace_id TEXT NOT NULL, parent_id TEXT, name TEXT, started_ms REAL,\n\t\t\tended_ms REAL NOT NULL, attributes TEXT, events TEXT, links TEXT, status TEXT)",
                "CREATE INDEX telemetry_spans_ended_ms ON telemetry_spans(ended_ms)",
                "CREATE INDEX telemetry_spans_trace_started ON telemetry_spans(trace_id, started_ms)",
                "CREATE INDEX telemetry_spans_started_ms ON telemetry_spans(started_ms)",
                "CREATE TABLE telemetry_metrics (interval_ms INTEGER, series_key TEXT, name TEXT, kind TEXT,\n\t\t\tunit TEXT, attributes TEXT, count INTEGER, sum REAL, min REAL, max REAL, PRIMARY KEY(interval_ms, series_key))",
            ]),
        ],
        table: "telemetry_schema"
    )
    return SqliteTelemetryRecorder(SqliteTelemetryCore(
        database: SqliteTelemetryDatabase(database, clock: clock), clock: clock, retention: retention, capacity: capacity))
}

private let carrierKey = "pi-sqlite-span"
private let traceKey = "pi-sqlite-trace"
private let intervalMs = 10_000.0

/// A span's globally unique ID and its trace.
private struct Identity: Sendable {
    let id: String
    let traceId: String
}

/// A context with a SQLite identity: a span or an extracted parent of any SQLite recorder. Upstream keeps identities in
/// a module-level WeakMap.
private protocol SqliteIdentityContext: TelemetryContext {
    var identity: Identity { get }
}

private func identity(of context: any TelemetryContext) -> Identity? {
    (context as? any SqliteIdentityContext)?.identity
}

/// A link as the spans table stores it.
private struct Link: Sendable {
    let traceId: String
    let spanId: String
    let attributes: [String: AttributeValue]

    var json: JSONValue {
        .object(JSONObject([
            ("trace_id", .string(traceId)), ("span_id", .string(spanId)), ("attributes", attributesJSON(attributes)),
        ]))
    }
}

/// One pending metric interval/series aggregate.
struct SqliteTelemetryMetric: Sendable {
    let interval: Double
    let key: String
    let name: String
    let kind: TelemetryMetricKind
    let unit: String?
    let attributes: String
    var count: Int
    var sum: Double
    var min: Double
    var max: Double
}

private func copyAttributes(_ attributes: SpanAttributes?) -> [String: AttributeValue] {
    attributes?.compactMapValues { $0 } ?? [:]
}

private func copyLink(_ link: SpanLink) -> Link? {
    guard let identity = identity(of: link.context) else { return nil }
    return Link(traceId: identity.traceId, spanId: identity.id, attributes: copyAttributes(link.attributes))
}

/// An attribute value as `JSON.stringify` writes it: a non-finite number becomes `null`.
func attributeJSON(_ value: AttributeValue) -> JSONValue {
    func number(_ value: Double) -> JSONValue { value.isFinite ? .number(value) : .null }
    switch value {
    case .string(let value): return .string(value)
    case .number(let value): return number(value)
    case .boolean(let value): return .bool(value)
    case .stringArray(let values): return .array(values.map(JSONValue.string))
    case .numberArray(let values): return .array(values.map(number))
    case .booleanArray(let values): return .array(values.map(JSONValue.bool))
    }
}

/// Attributes as a JSON object with sorted keys, as upstream's metric series key encodes them (`Object.keys().sort()`
/// then `Object.fromEntries`, so array-index keys still lead). Span columns use the same order, where upstream keeps
/// insertion order, which a Swift dictionary does not have.
func attributesJSON(_ attributes: [String: AttributeValue]) -> JSONValue {
    .object(JSONObject(attributes.keys.sorted(by: javaScriptPrecedes).map { ($0, attributeJSON(attributes[$0]!)) }))
}

/// `JSON.stringify` of strict JSON.
func jsonText(_ value: JSONValue) -> String {
    (try? value.jsonText()) ?? "null"
}

private func statusJSON(_ status: SpanStatus) -> JSONValue {
    switch status {
    case .ok: return .object(["status": "ok"])
    case .error(nil): return .object(["status": "error"])
    case .error(let details?):
        return .object(JSONObject([
            ("status", "error"),
            ("error", .object(JSONObject([("name", .string(details.name)), ("message", .string(details.message))]))),
        ]))
    }
}

/// Swift errors have no `name` or `message`, so the type name and description stand in for them.
private func automaticErrorStatus(_ error: any Error) -> SpanStatus {
    let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    return .error(name: String(describing: type(of: error)), message: message)
}

private struct RecorderState {
    var sequence = 0
    var spans: [[SqliteValue]] = []
    var measurements: [String: SqliteTelemetryMetric] = [:]
    var measurementOrder: [String] = []
    var inFlightMeasurements = 0
    var droppedSpans = 0
    var droppedMeasurements = 0
    var stopped = false
    var failed = false
    var failure: (any Error)?
    var writing: Task<Void, any Error>?
    var closing: Task<Void, any Error>?
    var cancelTimer: (@Sendable () -> Void)?
}

/// The recording state, the queue, and the database that the recorder, its instruments, and its spans share.
private final class SqliteTelemetryCore: Sendable {
    let database: SqliteTelemetryDatabase
    let clock: TelemetryClock
    let retention: Double
    let capacity: Int
    let scope = UUID().uuidString.lowercased()
    let state = Mutex(RecorderState())

    init(database: SqliteTelemetryDatabase, clock: TelemetryClock, retention: Double, capacity: Int) {
        self.database = database
        self.clock = clock
        self.retention = retention
        self.capacity = capacity
        let cancel = clock.every(1000) { [weak self] in
            guard let self, state.withLock({ $0.writing == nil }) else { return }
            Task { try? await self.flush() }
        }
        state.withLock { $0.cancelTimer = cancel }
    }

    deinit {
        state.withLock { $0.cancelTimer }?()
    }

    var stopped: Bool { state.withLock { $0.stopped } }

    /// A new span's identity, or nil once recording stopped.
    func begin(parent: Identity?) -> Identity? {
        state.withLock { state in
            guard !state.stopped else { return nil }
            state.sequence += 1
            let id = "\(scope):\(state.sequence)"
            return Identity(id: id, traceId: parent?.traceId ?? id)
        }
    }

    func queue(_ row: [SqliteValue]) {
        state.withLock { state in
            guard !state.stopped else { return }
            if state.spans.count >= capacity { state.droppedSpans += 1 } else { state.spans.append(row) }
        }
    }

    func measure(_ kind: TelemetryMetricKind, _ name: String, unit: String?, _ value: Double, _ attributes: SpanAttributes?) {
        guard !stopped else { return }
        let encoded = jsonText(attributesJSON(copyAttributes(attributes)))
        let key = jsonText(.array([.string(name), .string(kind.rawValue), unit.map(JSONValue.string) ?? .null, .string(encoded)]))
        let interval = (clock.now() / intervalMs).rounded(.down) * intervalMs
        let pendingKey = "\(javaScriptNumber(interval)):\(key)"
        state.withLock { state in
            guard !state.stopped else { return }
            let previous = state.measurements[pendingKey]
            if previous == nil && state.measurements.count + state.inFlightMeasurements >= capacity {
                state.droppedMeasurements += 1
                return
            }
            if previous == nil { state.measurementOrder.append(pendingKey) }
            state.measurements[pendingKey] = SqliteTelemetryMetric(
                interval: interval, key: key, name: name, kind: kind, unit: unit, attributes: encoded,
                count: (previous?.count ?? 0) + 1, sum: (previous?.sum ?? 0) + value,
                min: Swift.min(previous?.min ?? value, value), max: Swift.max(previous?.max ?? value, value))
        }
    }

    func flush() async throws {
        if let closing = state.withLock({ $0.closing }) {
            try await closing.value
        } else {
            try await drain(partial: false)
        }
    }

    func close() async throws {
        let (closing, cancel) = state.withLock { state -> (Task<Void, any Error>, (@Sendable () -> Void)?) in
            if let closing = state.closing { return (closing, nil) }
            state.stopped = true
            let cancel = state.cancelTimer
            state.cancelTimer = nil
            let closing = Task { try await self.drain(partial: true) }
            state.closing = closing
            return (closing, cancel)
        }
        cancel?()
        try await closing.value
    }

    private enum DrainStep {
        case wait(Task<Void, any Error>)
        case fail(any Error)
        case write(Task<Void, any Error>)
    }

    /// Waits for the write in flight, then writes the queued spans and the completed (or, with `partial`, all) metric
    /// intervals in one transaction with the retention cleanup. Spans stay queued, and so count against the bound,
    /// until the transaction commits.
    private func drain(partial: Bool) async throws {
        while true {
            let completed = (clock.now() / intervalMs).rounded(.down) * intervalMs
            let step = state.withLock { state -> DrainStep in
                if let writing = state.writing { return .wait(writing) }
                if state.failed { return .fail(state.failure!) }
                let spans = state.spans
                var metrics: [SqliteTelemetryMetric] = []
                var kept: [String] = []
                for key in state.measurementOrder {
                    let metric = state.measurements[key]!
                    if !partial && metric.interval >= completed {
                        kept.append(key)
                    } else {
                        metrics.append(metric)
                        state.measurements[key] = nil
                    }
                }
                state.measurementOrder = kept
                state.inFlightMeasurements = metrics.count
                let writing = Task { try await self.write(spans: spans, metrics: metrics) }
                state.writing = writing
                return .write(writing)
            }
            switch step {
            case .wait(let writing): try await writing.value
            case .fail(let failure): throw failure
            case .write(let writing): return try await writing.value
            }
        }
    }

    private func write(spans: [[SqliteValue]], metrics: [SqliteTelemetryMetric]) async throws {
        do {
            try await database.write(spans: spans, metrics: metrics, retention: retention)
            state.withLock { state in
                state.spans.removeFirst(spans.count)
                state.writing = nil
                state.inFlightMeasurements = 0
            }
        } catch {
            let cancel = state.withLock { state in
                state.failed = true
                state.stopped = true
                state.failure = error
                state.spans = []
                state.measurements = [:]
                state.measurementOrder = []
                state.writing = nil
                state.inFlightMeasurements = 0
                defer { state.cancelTimer = nil }
                return state.cancelTimer
            }
            cancel?()
            throw error
        }
    }
}

/// The owner of the connection: flushes and store reads run here, one at a time.
actor SqliteTelemetryDatabase {
    let database: any SqliteExecutor
    let clock: TelemetryClock

    init(_ database: sending any SqliteExecutor, clock: TelemetryClock) {
        self.database = database
        self.clock = clock
    }

    func write(spans: [[SqliteValue]], metrics: [SqliteTelemetryMetric], retention: Double) throws {
        try database.transaction { tx in
            for span in spans {
                try tx.run("INSERT INTO telemetry_spans VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", span)
            }
            for metric in metrics {
                try tx.run(
                    "INSERT INTO telemetry_metrics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\n\t\t\t\tON CONFLICT(interval_ms, series_key) DO UPDATE SET count = count + excluded.count,\n\t\t\t\tsum = sum + excluded.sum, min = min(min, excluded.min), max = max(max, excluded.max)",
                    [
                        .real(metric.interval), .text(metric.key), .text(metric.name), .text(metric.kind.rawValue),
                        metric.unit.map(SqliteValue.text) ?? .null, .text(metric.attributes),
                        .integer(Int64(metric.count)), .real(metric.sum), .real(metric.min), .real(metric.max),
                    ])
            }
            let cutoff = clock.now() - retention
            try tx.run("DELETE FROM telemetry_spans WHERE ended_ms < ?", [.real(cutoff)])
            try tx.run("DELETE FROM telemetry_metrics WHERE interval_ms < ?", [.real(cutoff)])
        }
    }

    func getTrace(_ traceId: String) throws -> StoredTrace? {
        try sqliteTelemetryTrace(database, traceId)
    }

    func findTraces(_ query: TraceQuery) throws -> StoredTracePage {
        try sqliteTelemetryTraces(database, query)
    }

    func findMetrics(_ query: MetricQuery) throws -> [StoredMetric] {
        try sqliteTelemetryMetrics(database, query)
    }
}

/// The recorder: the root context, the propagation, and the store.
private final class SqliteTelemetryRecorder: SqliteTelemetry, TelemetryPropagation {
    let core: SqliteTelemetryCore
    let instruments: SqliteTelemetryMetrics

    init(_ core: SqliteTelemetryCore) {
        self.core = core
        instruments = SqliteTelemetryMetrics(core)
    }

    var metrics: (any TelemetryMetrics)? { instruments }
    var propagation: (any TelemetryPropagation)? { self }
    var droppedSpans: Int { core.state.withLock { $0.droppedSpans } }
    var droppedMeasurements: Int { core.state.withLock { $0.droppedMeasurements } }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await start(parent: nil, options, body)
    }

    func inject(_ context: any TelemetryContext) -> TelemetryCarrier? {
        guard let identity = identity(of: context) else { return nil }
        return [carrierKey: identity.id, traceKey: identity.traceId]
    }

    func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext {
        guard let id = carrier?[carrierKey], let traceId = carrier?[traceKey] else { return self }
        return SqliteExtractedParent(owner: self, identity: Identity(id: id, traceId: traceId))
    }

    nonisolated(nonsending) func start<T, E: Error>(
        parent: Identity?,
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        let attributes = copyAttributes(options.attributes)
        let links = (options.links ?? []).compactMap(copyLink)
        guard let identity = core.begin(parent: parent) else {
            return try await body(SqliteInertSpan(owner: self))
        }
        let span = SqliteTelemetrySpan(
            owner: self, identity: identity, parentId: parent?.id, name: options.name, startedMs: core.clock.now(),
            clock: core.clock.monotonic(), attributes: attributes, links: links)
        do throws(E) {
            let value = try await body(span)
            span.settle(error: nil)
            return value
        } catch {
            span.settle(error: error)
            throw error
        }
    }

    /// Readers use committed rows only; flush first to include newly settled spans.
    func getTrace(_ traceId: String) async throws -> StoredTrace? { try await core.database.getTrace(traceId) }
    func findTraces(_ query: TraceQuery) async throws -> StoredTracePage { try await core.database.findTraces(query) }
    func findMetrics(_ query: MetricQuery) async throws -> [StoredMetric] { try await core.database.findMetrics(query) }

    func flush() async throws { try await core.flush() }
    func close() async throws { try await core.close() }
}

private struct SpanState {
    var attributes: [String: AttributeValue]
    var events: [JSONValue] = []
    var links: [Link]
    var status: SpanStatus = .ok
    var explicit = false
    var settled = false
}

private final class SqliteTelemetrySpan: TelemetrySpan, SqliteIdentityContext {
    let owner: SqliteTelemetryRecorder
    let identity: Identity
    let parentId: String?
    let name: String
    let startedMs: Double
    let clock: Double
    let state: Mutex<SpanState>

    init(owner: SqliteTelemetryRecorder, identity: Identity, parentId: String?, name: String, startedMs: Double,
         clock: Double, attributes: [String: AttributeValue], links: [Link]) {
        self.owner = owner
        self.identity = identity
        self.parentId = parentId
        self.name = name
        self.startedMs = startedMs
        self.clock = clock
        state = Mutex(SpanState(attributes: attributes, links: links))
    }

    var metrics: (any TelemetryMetrics)? { owner.instruments }
    var propagation: (any TelemetryPropagation)? { owner }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        if state.withLock({ $0.settled }) { return try await body(SqliteInertSpan(owner: owner)) }
        return try await owner.start(parent: identity, options, body)
    }

    /// Applies `action` while the span is open and the recorder records.
    private func record(_ action: (inout SpanState) -> Void) {
        guard !owner.core.stopped else { return }
        state.withLock { state in
            if !state.settled { action(&state) }
        }
    }

    func addLink(_ link: SpanLink) {
        guard let link = copyLink(link) else { return }
        record { $0.links.append(link) }
    }

    func addEvent(_ name: String, attributes: SpanAttributes?) {
        let event = JSONValue.object(JSONObject([
            ("name", .string(name)), ("time_ms", .number(owner.core.clock.monotonic() - clock)),
            ("attributes", attributesJSON(copyAttributes(attributes))),
        ]))
        record { $0.events.append(event) }
    }

    func setAttributes(_ attributes: SpanAttributes) {
        let attributes = copyAttributes(attributes)
        record { $0.attributes.merge(attributes) { _, later in later } }
    }

    func setStatus(_ status: SpanStatus) {
        record { state in
            state.status = status
            state.explicit = true
        }
    }

    func settle(error: (any Error)?) {
        // The error's own description code runs outside the lock.
        let automatic = error.flatMap { error in state.withLock { $0.explicit } ? nil : automaticErrorStatus(error) }
        let ended = startedMs + owner.core.clock.monotonic() - clock
        let settled = state.withLock { state -> SpanState in
            if let automatic, !state.explicit { state.status = automatic }
            state.settled = true
            return state
        }
        owner.core.queue([
            .text(identity.id), .text(identity.traceId), parentId.map(SqliteValue.text) ?? .null, .text(name),
            .real(startedMs), .real(ended), .text(jsonText(attributesJSON(settled.attributes))),
            .text(jsonText(.array(settled.events))), .text(jsonText(.array(settled.links.map(\.json)))),
            .text(jsonText(statusJSON(settled.status))),
        ])
    }
}

/// A parent extracted from a carrier, of this recorder's database or another one.
private final class SqliteExtractedParent: SqliteIdentityContext {
    let owner: SqliteTelemetryRecorder
    let identity: Identity

    init(owner: SqliteTelemetryRecorder, identity: Identity) {
        self.owner = owner
        self.identity = identity
    }

    var metrics: (any TelemetryMetrics)? { owner.instruments }
    var propagation: (any TelemetryPropagation)? { owner }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await owner.start(parent: identity, options, body)
    }
}

/// A span that records nothing, after close or under a settled parent, with the recorder's capabilities.
private final class SqliteInertSpan: TelemetrySpan {
    let owner: SqliteTelemetryRecorder

    init(owner: SqliteTelemetryRecorder) { self.owner = owner }

    var metrics: (any TelemetryMetrics)? { owner.instruments }
    var propagation: (any TelemetryPropagation)? { owner }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await body(SqliteInertSpan(owner: owner))
    }

    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

private final class SqliteTelemetryMetrics: TelemetryMetrics {
    let core: SqliteTelemetryCore

    init(_ core: SqliteTelemetryCore) { self.core = core }

    func counter(_ name: String, options: InstrumentOptions?) -> any TelemetryCounter {
        SqliteInstrument(core, .counter, name, unit: options?.unit)
    }

    func upDownCounter(_ name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter {
        SqliteInstrument(core, .upDownCounter, name, unit: options?.unit)
    }

    func histogram(_ name: String, options: HistogramOptions?) -> any TelemetryHistogram {
        SqliteInstrument(core, .histogram, name, unit: options?.unit)
    }
}

/// An instrument. Descriptions, boundaries, and exemplar contexts are not stored.
private final class SqliteInstrument: TelemetryCounter, TelemetryUpDownCounter, TelemetryHistogram {
    let core: SqliteTelemetryCore
    let kind: TelemetryMetricKind
    let name: String
    let unit: String?

    init(_ core: SqliteTelemetryCore, _ kind: TelemetryMetricKind, _ name: String, unit: String?) {
        self.core = core
        self.kind = kind
        self.name = name
        self.unit = unit
    }

    func add(_ value: Double, attributes: SpanAttributes?) {
        core.measure(kind, name, unit: unit, value, attributes)
    }

    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?) {
        core.measure(kind, name, unit: unit, value, attributes)
    }
}
