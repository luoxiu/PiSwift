// Ports upstream `packages/telemetry/test/metrics.test.ts` at 48909d987.
// Upstream's compile-time checks (`expectTypeOf`, `@ts-expect-error`) test TypeScript inference, which
// Swift does not have. Its Proxy options and attributes that throw on read have no Swift counterpart.

import Foundation
import Testing
import PiSwiftTelemetry

private let traffic = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [:], metrics: [
    "network.bytes": .counter(description: "Encoded bytes", unit: "By", attributes: [
        "direction": .init(.string(values: ["in", "out"]), description: "Direction", required: true, cardinality: .low),
    ]),
    "network.active": .upDownCounter(description: "Open links", attributes: [:]),
]))
private let latency = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [:], metrics: [
    "call.duration": .histogram(description: "Call duration", unit: "ms", boundaries: [1, 10, 100], attributes: [
        "method": .init(.string(), description: "Method", required: false),
    ]),
]))

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func sameObject(_ first: Any, _ second: Any) -> Bool {
    first as AnyObject === second as AnyObject
}

@Suite("PiSwiftTelemetryTests.metrics")
struct MetricsTests {
    @Test func bindsSchemaNamesKindsMetadataAndExactMeasurementAttributes() async throws {
        let adapter = InMemoryTelemetryContext()
        let metrics = createTypedMetrics(adapter, [traffic, latency])
        metrics.counter("network.bytes").add(128, attributes: ["direction": "out"])
        metrics.upDownCounter("network.active").add(1)
        metrics.upDownCounter("network.active").add(-1)
        await adapter.startSpan(SpanOptions(name: "request")) { span in
            metrics.histogram("call.duration").record(12, attributes: ["method": "read"], context: span)
            metrics.histogram("call.duration").record(13)
            metrics.histogram("call.duration").record(14, attributes: nil, context: span)
        }
        let measurements = adapter.getMetrics()
        let request = try #require(adapter.getSpans().first).context
        #expect(measurements[0] == RecordedTelemetryMeasurement(
            kind: .counter, name: "network.bytes", description: "Encoded bytes", unit: "By", value: 128,
            attributes: ["direction": "out"]))
        #expect(measurements[3].kind == .histogram)
        #expect(measurements[3].boundaries == [1, 10, 100])
        #expect(measurements[3].context == request)
        #expect(measurements[4].context == nil)
        #expect(measurements[5].context == request)
        // Upstream checks that `JSON.stringify` does not throw; Swift checks the JSON shape and the round trip.
        #expect(try json(traffic) == #"{"metrics":{"network.active":{"attributes":{},"description":"Open links","#
            + #""kind":"upDownCounter"},"network.bytes":{"attributes":{"direction":{"cardinality":"low","#
            + #""description":"Direction","required":true,"type":"string","values":["in","out"]}},"#
            + #""description":"Encoded bytes","kind":"counter","unit":"By"}},"spans":{},"version":1}"#)
        let decoded = try JSONDecoder().decode(TelemetrySchemaDefinition.self, from: JSONEncoder().encode(latency))
        #expect(decoded == latency)
    }

    // Swift: upstream checks only at compile time that the required attribute is passed; this records the call.
    @Test func requiresHistogramAttributesWhenTheSchemaDeclaresThem() {
        let schema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [:], metrics: [
            "required": .histogram(description: "Required tag", attributes: [
                "cache": .init(.boolean(), description: "Cache hit", required: true),
            ]),
        ]))
        let adapter = InMemoryTelemetryContext()
        let metrics = createTypedMetrics(adapter, [schema])
        metrics.histogram("required").record(1, attributes: ["cache": true])
        #expect(adapter.getMetrics() == [RecordedTelemetryMeasurement(
            kind: .histogram, name: "required", description: "Required tag", value: 1, attributes: ["cache": true])])
    }

    @Test func returnsDetachedMeasurementSnapshotsIncludingExemplarsAndBoundaries() async throws {
        let telemetry = InMemoryTelemetryContext()
        let histogram = telemetry.histogram("duration", options: HistogramOptions(boundaries: [1, 2]))
        await telemetry.startSpan(SpanOptions(name: "request")) { span in
            histogram.record(1, attributes: ["tags": .stringArray(["original"])], context: span)
        }
        var measurement = try #require(telemetry.getMetrics().first)
        #expect(measurement.context != nil)
        measurement.boundaries?.append(3)
        measurement.attributes["tags"] = .stringArray(["mutated"])
        measurement.context?["pi-memory-span"] = "999"
        let fresh = try #require(telemetry.getMetrics().first)
        #expect(fresh.boundaries == [1, 2])
        #expect(fresh.attributes == ["tags": .stringArray(["original"])])
        #expect(fresh.context == telemetry.getSpans().first?.context)
    }

    @Test func ignoresMalformedMetadataNonfiniteValuesAndUnreadableAttributes() {
        let telemetry = InMemoryTelemetryContext()
        for boundaries: [Double] in [[1, 1], [2, 1], [.nan], [.infinity]] {
            telemetry.histogram("bad", options: HistogramOptions(boundaries: boundaries)).record(1)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            telemetry.counter("bad").add(value)
            telemetry.upDownCounter("bad").add(value)
            telemetry.histogram("bad").record(value)
        }
        telemetry.counter("bad").add(-1)
        #expect(telemetry.getMetrics().isEmpty)
        telemetry.histogram("valid").record(-1, attributes: [:], context: noopTelemetryContext)
        #expect(telemetry.getMetrics().first?.context == nil)
    }

    @Test func sharesFrozenNoopInstrumentsWithoutInspectingArguments() {
        let options = HistogramOptions(unit: "By")
        let counter = noopTelemetryMetrics.counter("bytes", options: InstrumentOptions(unit: options.unit))
        let active = noopTelemetryMetrics.upDownCounter("active", options: InstrumentOptions(unit: options.unit))
        let histogram = noopTelemetryMetrics.histogram("duration", options: options)
        // Upstream checks that the instruments are frozen; the Swift ones are stateless shared instances.
        #expect(sameObject(counter, noopTelemetryMetrics.counter("other")))
        #expect(sameObject(active, noopTelemetryMetrics.upDownCounter("other")))
        #expect(sameObject(histogram, noopTelemetryMetrics.histogram("other")))
        counter.add(1, attributes: ["secret": "value"])
        active.add(-1, attributes: ["secret": "value"])
        histogram.record(1, attributes: ["secret": "value"], context: noopTelemetryContext)
    }

    // Swift addition: metric definitions are hand-coded, so the kinds, the boundaries, and the low-only cardinality
    // go through upstream's JSON shape, and a definition upstream's types reject does not decode.
    @Test func codesMetricDefinitionsInUpstreamsShape() throws {
        let definitions: [String: TelemetryMetricDefinition] = [
            "c": .counter(description: "C", attributes: [
                "a": .init(.number(values: [1]), description: "A", required: false, sensitive: true),
            ]),
            "h": .histogram(description: "H", boundaries: [0.5, 1], attributes: [:]),
        ]
        #expect(try json(definitions) == #"{"c":{"attributes":{"a":{"description":"A","required":false,"#
            + #""sensitive":true,"type":"number","values":[1]}},"description":"C","kind":"counter"},"#
            + #""h":{"attributes":{},"boundaries":[0.5,1],"description":"H","kind":"histogram"}}"#)
        #expect(try JSONDecoder().decode([String: TelemetryMetricDefinition].self, from: JSONEncoder().encode(definitions))
            == definitions)
        let counterWithBoundaries = Data(#"{"kind":"counter","description":"C","attributes":{},"boundaries":[1]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TelemetryMetricDefinition.self, from: counterWithBoundaries) }
        let highCardinality = Data(#"{"type":"string","description":"R","required":false,"cardinality":"high"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TelemetryMetricAttributeDefinition.self, from: highCardinality)
        }
    }
}
