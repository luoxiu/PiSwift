// Ports upstream `packages/telemetry/test/store-conformance.ts` at d9025a5f5: the read-store checks that the in-memory
// adapter's tests and Chord's SQLite adapter's tests share. Upstream registers them with vitest's `describe`; these
// are runner-independent cases, like the adapter conformance, that each test target registers. The factory takes the
// clock that upstream's `vi.spyOn(Date, "now")` replaces.

import Foundation
import Synchronization
import PiSwiftTelemetry
import PiSwiftTelemetryTesting

/// A fresh adapter, its store, and its flush, for one case.
package struct TelemetryStoreFixture: Sendable {
    package let context: any TelemetryContext
    package let metrics: any TelemetryMetrics
    package let propagation: any TelemetryPropagation
    package let store: any TelemetryStore
    package let flush: @Sendable () async throws -> Void
    package let dispose: @Sendable () async throws -> Void

    package init(
        context: any TelemetryContext,
        store: any TelemetryStore,
        flush: @escaping @Sendable () async throws -> Void = {},
        dispose: @escaping @Sendable () async throws -> Void = {}
    ) throws {
        guard let metrics = context.metrics, let propagation = context.propagation else {
            throw TelemetryConformanceFailure("Store fixtures require metrics and propagation on the context")
        }
        self.context = context
        self.metrics = metrics
        self.propagation = propagation
        self.store = store
        self.flush = flush
        self.dispose = dispose
    }
}

/// Creates a fixture whose adapter reads `clock`.
package typealias TelemetryStoreFixtureFactory = @Sendable (TelemetryClock) async throws -> TelemetryStoreFixture

/// A store conformance case.
package struct TelemetryStoreConformanceCase: Sendable, CustomStringConvertible {
    package let name: String
    package let run: @Sendable () async throws -> Void
    package var description: String { name }
}

private func check(_ value: Bool, _ message: @autoclosure () -> String, file: String = #filePath, line: UInt = #line) throws {
    guard value else { throw TelemetryConformanceFailure(message(), file: file, line: line) }
}

private func equal<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: UInt = #line) throws {
    try check(actual == expected, "Expected \(expected); got \(actual)", file: file, line: line)
}

private func required<T>(_ value: T?, _ message: String, file: String = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw TelemetryConformanceFailure(message, file: file, line: line) }
    return value
}

/// Runs `body` with a fresh fixture and disposes it afterwards, also after a failed check (upstream `await using`).
private func withFixture(
    _ factory: TelemetryStoreFixtureFactory,
    _ clock: TelemetryClock,
    _ body: (TelemetryStoreFixture) async throws -> Void
) async throws {
    let fixture = try await factory(clock)
    let outcome: Result<Void, any Error>
    do {
        try await body(fixture)
        outcome = .success(())
    } catch {
        outcome = .failure(error)
    }
    do {
        try await fixture.dispose()
    } catch {
        if case .success = outcome { throw error }
    }
    try outcome.get()
}

private final class Gate: Sendable {
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

private final class CarrierBox: Sendable {
    let value = Mutex<TelemetryCarrier?>(nil)
}

/// Shared read-store checks; no raw-measurement or backend-specific persistence assumptions.
package func telemetryStoreConformance(_ factory: @escaping TelemetryStoreFixtureFactory) -> [TelemetryStoreConformanceCase] {
    [
        TelemetryStoreConformanceCase(name: "returns only settled traces, complete span snapshots, and detached results") {
            let clock = ManualTelemetryClock(now: 20_000)
            try await withFixture(factory, clock.clock) { f in
                let started = Gate(), gate = Gate()
                let context = f.context
                let active = Task {
                    await context.startSpan(SpanOptions(name: "root", attributes: ["tags": .stringArray(["original"])])) { root in
                        root.addEvent("event", attributes: ["tags": .stringArray(["original"])])
                        started.open()
                        await gate.wait()
                        await root.startSpan(SpanOptions(name: "child")) { _ in }
                    }
                }
                // Upstream's root span starts before `startSpan` returns; here the test waits for it.
                await started.wait()
                try await f.flush()
                try equal(try await f.store.findTraces().traces, [])
                try equal(try await f.store.getTrace("missing"), nil)
                gate.open()
                await active.value
                try await f.flush()
                let trace = try required(try await f.store.findTraces().traces.first, "Expected a trace")
                var root = try required(trace.spans.first { $0.name == "root" }, "Expected the root span")
                let child = try required(trace.spans.first { $0.name == "child" }, "Expected the child span")
                try check(root.id.wholeMatch(of: try Regex("[0-9a-f-]{36}:[1-9][0-9]*")) != nil, "Unexpected span ID \(root.id)")
                try equal(root.traceId, root.id)
                try equal(root.parentId, nil)
                try equal(child.parentId, root.id)
                try equal(child.traceId, root.traceId)
                try equal(root.startedMs, 20_000)
                try check(root.endedMs >= root.startedMs, "Expected the end at or after the start")
                try check((root.events.first?.timeMs ?? -1) >= 0, "Expected a nonnegative event offset")
                root.attributes["tags"] = .stringArray(["changed"])
                root.events[0].attributes["tags"] = .stringArray(["changed"])
                let fresh = try await f.store.getTrace(trace.traceId)
                let freshRoot = fresh?.spans.first { $0.id == root.id }
                try equal(freshRoot?.attributes["tags"], .stringArray(["original"]))
                try equal(freshRoot?.events.first?.attributes["tags"], .stringArray(["original"]))
            }
        },

        TelemetryStoreConformanceCase(name: "filters by first-span name and start, any error, and all attributes on one span") {
            let clock = ManualTelemetryClock(now: 10_000)
            try await withFixture(factory, clock.clock) { f in
                await f.context.startSpan(SpanOptions(name: "old")) { root in
                    clock.now = 30_000
                    await root.startSpan(SpanOptions(name: "recent-child", attributes: ["left": 1])) { _ in }
                    await root.startSpan(SpanOptions(name: "split", attributes: ["right": 2])) { _ in }
                }
                clock.now = 20_000
                await f.context.startSpan(SpanOptions(name: "wanted")) { root in
                    clock.now = 20_001
                    await root.startSpan(SpanOptions(
                        name: "failure", attributes: ["left": 1, "right": 2, "valid": true, #"odd."key"#: "value"]
                    )) { child in child.setStatus(.error(nil)) }
                }
                clock.now = 40_000
                await f.context.startSpan(SpanOptions(name: "new", attributes: ["valid": 1])) { _ in }
                try await f.flush()
                let names = { (query: TraceQuery) in
                    try await f.store.findTraces(query).traces.map { $0.spans.first?.name }
                }
                try equal(try await names(TraceQuery(
                    name: "wanted", attributes: ["left": 1, "right": 2], errors: true, startMin: 20_000, startMax: 20_000
                )), ["wanted"])
                try equal(try await names(TraceQuery(name: "failure")), [])
                try equal(try await names(TraceQuery(attributes: ["left": 1, "right": 2])), ["wanted"])
                try equal(try await names(TraceQuery(attributes: ["valid": true, #"odd."key"#: "value"])), ["wanted"])
                try equal(try await names(TraceQuery(attributes: ["valid": 1])), ["new"])
                try equal(try await names(TraceQuery(errors: true)), ["wanted"])
                try equal(try await names(TraceQuery(startMin: 20_000)), ["new", "wanted"])
                try equal(try await names(TraceQuery(startMax: 10_000)), ["old"])
            }
        },

        TelemetryStoreConformanceCase(name: "pages complete traces without duplicates when trace starts tie") {
            let clock = ManualTelemetryClock(now: 20_000)
            try await withFixture(factory, clock.clock) { f in
                for index in 0..<25 {
                    clock.now = 20_000
                    await f.context.startSpan(SpanOptions(name: "root", attributes: ["index": .number(Double(index))])) { root in
                        clock.now = 20_001
                        await root.startSpan(SpanOptions(name: "child")) { _ in }
                    }
                }
                try await f.flush()
                let first = try await f.store.findTraces()
                try equal(first.traces.count, 20)
                try check(first.cursor != nil, "Expected a cursor")
                let rest = try await f.store.findTraces(TraceQuery(cursor: first.cursor))
                try equal(rest.traces.count, 5)
                try equal(rest.cursor, nil)
                let all = try await f.store.findTraces(TraceQuery(limit: 100)).traces
                try equal(first.traces + rest.traces, all)
                try check(all.allSatisfy { $0.spans.count == 2 }, "Expected two spans in every trace")
                var ids: [String] = []
                var cursor: String?
                repeat {
                    let page = try await f.store.findTraces(TraceQuery(name: "root", limit: 3, cursor: cursor))
                    ids += page.traces.map(\.traceId)
                    cursor = page.cursor
                } while cursor != nil
                try equal(ids, all.map(\.traceId))
            }
        },

        // Swift: upstream also extracts carriers with a number in place of each key, which `TelemetryCarrier` cannot hold,
        // so there is one fallback per key, not two.
        TelemetryStoreConformanceCase(name: "inherits remote trace IDs and preserves remote parents and cross-trace links") {
            let clock = ManualTelemetryClock(now: 20_000)
            try await withFixture(factory, clock.clock) { sender in
                try await withFixture(factory, clock.clock) { receiver in
                    let box = CarrierBox()
                    await sender.context.startSpan(SpanOptions(name: "sender")) { span in
                        box.value.withLock { $0 = sender.propagation.inject(span) }
                    }
                    let carrier = try required(box.value.withLock { $0 }, "Expected a carrier")
                    try await sender.flush()
                    let sent = try required(try await sender.store.findTraces().traces.first, "Expected the sent trace")
                    let wire = try JSONDecoder().decode(TelemetryCarrier.self, from: JSONEncoder().encode(carrier))
                    let remote = receiver.propagation.extract(wire)
                    await remote.startSpan(SpanOptions(name: "receiver")) { _ in }
                    await receiver.context.startSpan(SpanOptions(
                        name: "linked", links: [SpanLink(context: remote, attributes: ["reason": "background"])]
                    )) { _ in }
                    try await receiver.flush()
                    let continued = try await receiver.store.getTrace(sent.traceId)
                    try equal(continued?.spans.count, 1)
                    try equal(continued?.spans.first?.traceId, sent.traceId)
                    try equal(continued?.spans.first?.parentId, sent.spans[0].id)
                    try equal(continued?.spans.first?.name, "receiver")
                    try check(continued?.spans.first?.id != sent.spans[0].id, "Expected a new span ID")
                    let linked = try required(
                        try await receiver.store.findTraces(TraceQuery(name: "linked")).traces.first, "Expected the linked trace")
                    try check(linked.traceId != sent.traceId, "Expected a separate trace")
                    try equal(linked.spans.first?.links, [
                        StoredSpan.Link(traceId: sent.traceId, spanId: sent.spans[0].id, attributes: ["reason": "background"]),
                    ])
                    for key in carrier.keys {
                        var incomplete = carrier
                        incomplete[key] = nil
                        await receiver.propagation.extract(incomplete).startSpan(SpanOptions(name: "fallback")) { _ in }
                    }
                    try await receiver.flush()
                    let fallbacks = try await receiver.store.findTraces(TraceQuery(name: "fallback")).traces
                    try equal(fallbacks.count, carrier.count)
                    try check(fallbacks.allSatisfy { $0.spans.first?.parentId == nil && $0.traceId == $0.spans.first?.id },
                              "Expected every fallback to be a root")
                }
            }
        },

        TelemetryStoreConformanceCase(name: "accepts external string identities without imposing an ID format") {
            try await withFixture(factory, .system) { f in
                let box = CarrierBox()
                await f.context.startSpan(SpanOptions(name: "source")) { span in
                    box.value.withLock { $0 = f.propagation.inject(span) }
                }
                let carrier = try required(box.value.withLock { $0 }, "Expected a carrier")
                let external = Dictionary(uniqueKeysWithValues: carrier.keys.map { ($0, "external-\($0)") })
                let parent = f.propagation.extract(external)
                try equal(f.propagation.inject(parent), external)
                await parent.startSpan(SpanOptions(name: "continued")) { _ in }
                try await f.flush()
                let trace = try required(
                    try await f.store.findTraces(TraceQuery(name: "continued")).traces.first, "Expected the continued trace")
                try check(trace.traceId.hasPrefix("external-"), "Unexpected trace ID \(trace.traceId)")
                try check(trace.spans.first?.parentId?.hasPrefix("external-") == true, "Unexpected parent ID")
            }
        },

        TelemetryStoreConformanceCase(
            name: "queries metric names, inclusive interval bounds, typed attribute equality, and detached values"
        ) {
            let clock = ManualTelemetryClock(now: 20_001)
            try await withFixture(factory, clock.clock) { f in
                let counter = f.metrics.counter("hits", options: InstrumentOptions(unit: "By"))
                counter.add(2, attributes: ["method": "read", "valid": true])
                counter.add(3, attributes: ["valid": true, "method": "read"])
                counter.add(11, attributes: ["method": "write", "valid": 1])
                f.metrics.counter("other").add(100, attributes: ["method": "read", "valid": true])
                clock.now = 30_001
                counter.add(7, attributes: ["method": "read", "valid": true])
                clock.now = 40_001
                try await f.flush()
                let query = MetricQuery(name: "hits", startMin: 20_000, startMax: 20_000, attributes: ["method": "read", "valid": true])
                var rows = try await f.store.findMetrics(query)
                try equal(rows.reduce(0) { $0 + $1.count }, 2)
                try equal(rows.reduce(0) { $0 + $1.sum }, 5)
                try equal(rows.map(\.min).min(), 2)
                try equal(rows.map(\.max).max(), 3)
                try check(rows.allSatisfy { $0.kind == .counter && $0.unit == "By" && $0.intervalMs == 20_000 },
                          "Expected counter rows in By at 20000")
                rows[0].attributes["method"] = "changed"
                try equal(try await f.store.findMetrics(query).first?.attributes["method"], "read")
                try equal(try await f.store.findMetrics(MetricQuery(name: "missing")), [])
                try equal(try await f.store.findMetrics(MetricQuery(name: "hits", attributes: ["valid": 1])).reduce(0) { $0 + $1.sum }, 11)
                try equal(try await f.store.findMetrics(MetricQuery(name: "hits", startMin: 30_000)).reduce(0) { $0 + $1.sum }, 7)
            }
        },
    ]
}
