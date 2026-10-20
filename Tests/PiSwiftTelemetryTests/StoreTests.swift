// Ports upstream `packages/telemetry/test/store.test.ts` at d9025a5f5. The shared store conformance is in
// `Tests/TelemetryTestSupport/StoreConformance.swift`; upstream's `vi.spyOn(Date, "now")` and
// `vi.spyOn(performance, "now")` become a `ManualTelemetryClock`.

import Testing
import PiSwiftTelemetry
import TelemetryTestSupport

private let inMemoryStoreConformance = telemetryStoreConformance { clock in
    let context = InMemoryTelemetryContext(clock: clock)
    return try TelemetryStoreFixture(context: context, store: context)
}

@Suite("PiSwiftTelemetryTests.in-memory telemetry store conformance")
struct InMemoryStoreConformanceTests {
    @Test(arguments: inMemoryStoreConformance)
    func conformance(_ testCase: TelemetryStoreConformanceCase) async throws {
        try await testCase.run()
    }
}

@Suite("PiSwiftTelemetryTests.in-memory store snapshots")
struct InMemoryStoreSnapshotTests {
    @Test func recordsWallClockBoundariesAndRelativeEventTimesWithoutChangingNormalizedEventSnapshots() async throws {
        let clock = ManualTelemetryClock(now: 1000, monotonic: 100)
        let telemetry = InMemoryTelemetryContext(clock: clock.clock)
        var id = ""
        await telemetry.startSpan(SpanOptions(name: "timed")) { span in
            let carrier = telemetry.inject(span) ?? [:]
            id = "\(carrier["pi-memory-scope"] ?? ""):\(carrier["pi-memory-span"] ?? "")"
            clock.monotonic = 110
            span.addEvent("event", attributes: ["count": 1])
            clock.monotonic = 125
        }
        #expect(try await telemetry.getTrace(id) == StoredTrace(traceId: id, spans: [
            StoredSpan(id: id, traceId: id, name: "timed", startedMs: 1000, endedMs: 1025,
                       events: [StoredSpan.Event(name: "event", timeMs: 10, attributes: ["count": 1])]),
        ]))
        // Upstream also checks that the snapshot has no `startedMs`; `RecordedTelemetrySpan` has no such member.
        #expect(telemetry.getSpans().first?.events == [RecordedTelemetryEvent(name: "event", attributes: ["count": 1])])
    }

    @Test func mapsRawMetricMeasurementsToCountOneRowsWithoutExposingPrivateTimingInGetMetrics() async throws {
        let telemetry = InMemoryTelemetryContext(clock: ManualTelemetryClock(now: 20_001).clock)
        telemetry.counter("calls").add(2)
        telemetry.counter("calls").add(3)
        #expect(try await telemetry.findMetrics(MetricQuery(name: "calls")).map { [$0.intervalMs, Double($0.count), $0.sum] }
            == [[20_000, 1, 2], [20_000, 1, 3]])
        #expect(telemetry.getMetrics() == [
            RecordedTelemetryMeasurement(kind: .counter, name: "calls", value: 2),
            RecordedTelemetryMeasurement(kind: .counter, name: "calls", value: 3),
        ])
    }

    @Test func detachesLinkAttributesAndErrorDetails() async throws {
        let telemetry = InMemoryTelemetryContext()
        var target: (any TelemetrySpan)?
        await telemetry.startSpan(SpanOptions(name: "target")) { span in target = span }
        await telemetry.startSpan(SpanOptions(
            name: "source", links: [SpanLink(context: try #require(target), attributes: ["tags": .stringArray(["original"])])]
        )) { span in
            span.setStatus(.error(name: "Expected", message: "original"))
        }
        let trace = try #require(try await telemetry.findTraces(TraceQuery(name: "source")).traces.first)
        var span = trace.spans[0]
        span.links[0].attributes?["tags"] = .stringArray(["changed"])
        span.status = .error(name: "Expected", message: "changed")
        let fresh = try #require(try await telemetry.getTrace(trace.traceId)?.spans.first)
        #expect(fresh.links.first?.attributes?["tags"] == .stringArray(["original"]))
        #expect(fresh.status == .error(name: "Expected", message: "original"))
    }

    // Swift addition: the in-memory cursor is upstream's JSON pair, and text that is not one fails the query, as
    // upstream's `JSON.parse` throws.
    @Test func writesTheCursorAsAJSONPairAndRejectsOthers() async throws {
        let clock = ManualTelemetryClock(now: 20_000)
        let telemetry = InMemoryTelemetryContext(clock: clock.clock)
        for _ in 0..<2 { await telemetry.startSpan(SpanOptions(name: "root")) { _ in } }
        let page = try await telemetry.findTraces(TraceQuery(limit: 1))
        let scope = try #require(telemetry.getSpans().first?.context["pi-memory-scope"])
        #expect(page.cursor == "[20000,\"\(scope):1\"]")
        await #expect(throws: DecodingError.self) { try await telemetry.findTraces(TraceQuery(cursor: "[20000")) }
    }
}
