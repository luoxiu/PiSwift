// Runs the Swift code blocks of `Sources/PiSwiftTelemetry/README.md`. The `TelemetryPropagation` block is the
// declaration in `Telemetry.swift`.

import Foundation
import Testing
import PiSwiftTelemetry
import PiSwiftTelemetryTesting

struct Account: Sendable, Equatable {
    let id: String
}

private struct SaveResult: Sendable {
    let ok: Bool
    let reason: String
}

func readAccount(_ id: String) async throws -> Account? { id == "123" ? Account(id: id) : nil }
private func readAccounts() async throws -> [Account] { [Account(id: "1"), Account(id: "2")] }
private func readProjects() async throws -> [String] { ["p"] }
private func save() async throws -> SaveResult { SaveResult(ok: false, reason: "disk full") }
private func handleRequest(_ span: any TelemetrySpan) async throws { span.addEvent("handled") }
private func activate() async throws {}

// README: core-context
func loadAccount(_ accountId: String, telemetry: any TelemetryContext = noopTelemetryContext) async throws -> Account? {
    try await telemetry.startSpan(SpanOptions(
        name: "example.account.load", attributes: ["example.account.id": .string(accountId)]
    )) { span in
        let account = try await readAccount(accountId)
        span.setAttributes(["example.account.found": .boolean(account != nil)])
        return account
    }
}
// README: end

// README: conformance
private let cases = createTelemetryAdapterConformance {
    let adapter = InMemoryTelemetryContext()
    return TelemetryAdapterFixture(context: adapter, propagation: adapter, metrics: adapter,
                                   getMetrics: { adapter.getMetrics() }, getSpans: { adapter.getSpans() },
                                   dispose: {})
}

@Test(arguments: cases)
func telemetryAdapterConformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
    try await testCase.run()
}
// README: end

/// The in-memory carrier of span `id`: the recorder's scope, which every span of `spans` shares, and the span ID.
func memoryCarrier(_ spans: [RecordedTelemetrySpan], _ id: Int) -> TelemetryCarrier {
    ["pi-memory-scope": spans.first?.context["pi-memory-scope"] ?? "", "pi-memory-span": String(id)]
}

@Suite("PiSwiftTelemetryTests.README examples")
struct ReadmeExamplesTests {
    @Test func coreContext() async throws {
        let telemetry = InMemoryTelemetryContext()
        #expect(try await loadAccount("123", telemetry: telemetry) == Account(id: "123"))
        #expect(try await loadAccount("9") == nil)
        let spans = telemetry.getSpans()
        #expect(spans == [RecordedTelemetrySpan(
            id: 1, parentId: nil, context: memoryCarrier(spans, 1), name: "example.account.load",
            attributes: ["example.account.id": "123", "example.account.found": true],
            settled: true, endSequence: 1)])
    }

    @Test func expectedFailure() async throws {
        let telemetry = InMemoryTelemetryContext()
        // README: expected-failure
        let result = try await telemetry.startSpan(SpanOptions(name: "example.save")) { span in
            let result = try await save()
            if !result.ok {
                span.setStatus(.error(name: "SaveError", message: result.reason))
            }
            return result
        }
        // README: end
        #expect(!result.ok)
        #expect(telemetry.getSpans().first?.status == .error(name: "SaveError", message: "disk full"))
    }

    @Test func inMemory() async {
        // README: in-memory
        let telemetry = InMemoryTelemetryContext()
        await telemetry.startSpan(SpanOptions(name: "example.operation", attributes: ["input": "demo"])) { span in
            span.addEvent("example.started")
            span.setAttributes(["output_count": 3])
        }
        print(telemetry.getSpans())
        // README: end
        let spans = telemetry.getSpans()
        #expect(spans == [RecordedTelemetrySpan(
            id: 1, parentId: nil, context: memoryCarrier(spans, 1), name: "example.operation",
            attributes: ["input": "demo", "output_count": 3],
            events: [RecordedTelemetryEvent(name: "example.started")],
            settled: true, endSequence: 1)])
    }

    @Test func propagation() async throws {
        // README: propagation
        let caller = InMemoryTelemetryContext()
        let provider = InMemoryTelemetryContext()
        try await caller.startSpan(SpanOptions(name: "rpc.client")) { span in
            let wire = try JSONEncoder().encode(caller.inject(span))
            let carrier = try JSONDecoder().decode(TelemetryCarrier?.self, from: wire)
            try await provider.extract(carrier).startSpan(SpanOptions(name: "rpc.server")) { serverSpan in
                try await handleRequest(serverSpan)
            }
        }
        // README: end
        let server = try #require(provider.getSpans().first)
        #expect(server.parentContext == caller.getSpans().first?.context)
        #expect(server.parentId == nil)
        #expect(server.events == [RecordedTelemetryEvent(name: "handled")])
    }

    @Test func links() async throws {
        let telemetry = InMemoryTelemetryContext()
        var getters: [any TelemetrySpan] = []
        for name in ["first", "later"] {
            await telemetry.startSpan(SpanOptions(name: "\(name).getter")) { span in getters.append(span) }
        }
        let firstGetter = getters[0], laterGetter = getters[1]
        // README: links
        try await telemetry.startSpan(SpanOptions(
            name: "activation", links: [SpanLink(context: firstGetter, attributes: ["reason": "trigger"])]
        )) { activation in
            laterGetter.addLink(SpanLink(context: activation))
            try await activate()
        }
        // README: end
        let spans = telemetry.getSpans()
        #expect(spans[2].links == [RecordedTelemetryLink(context: spans[0].context, attributes: ["reason": "trigger"])])
        // The later getter had settled, so it ignores the link.
        #expect(spans[1].links.isEmpty)
    }

    @Test func metrics() async {
        let telemetry = InMemoryTelemetryContext()
        let encodedSize = 64, elapsedMs = 12.5
        await telemetry.startSpan(SpanOptions(name: "call")) { currentSpan in
            // README: metrics
            let bytes = telemetry.counter("network.bytes", options: InstrumentOptions(
                description: "Encoded WebSocket bytes", unit: "By"))
            bytes.add(Double(encodedSize), attributes: ["direction": "out"])

            let active = telemetry.upDownCounter("calls.active")
            active.add(1)
            active.add(-1)

            let duration = telemetry.histogram("call.duration", options: HistogramOptions(
                unit: "ms", boundaries: [1, 10, 100, 1000]))
            duration.record(elapsedMs, attributes: ["method": "read"], context: currentSpan)
            // README: end
        }
        #expect(telemetry.getMetrics() == [
            RecordedTelemetryMeasurement(kind: .counter, name: "network.bytes", description: "Encoded WebSocket bytes",
                                         unit: "By", value: 64, attributes: ["direction": "out"]),
            RecordedTelemetryMeasurement(kind: .upDownCounter, name: "calls.active", value: 1),
            RecordedTelemetryMeasurement(kind: .upDownCounter, name: "calls.active", value: -1),
            RecordedTelemetryMeasurement(kind: .histogram, name: "call.duration", unit: "ms", boundaries: [1, 10, 100, 1000],
                                         value: 12.5, attributes: ["method": "read"],
                                         context: telemetry.getSpans().first?.context),
        ])
    }

    @Test func typedMetrics() {
        let telemetry = InMemoryTelemetryContext()
        let encodedSize = 64
        // README: typed-metrics
        let schema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [:], metrics: [
            "network.bytes": .counter(description: "Encoded bytes", unit: "By", attributes: [
                "direction": .init(.string(values: ["in", "out"]), description: "Direction", required: true,
                                   cardinality: .low),
            ]),
        ]))

        let metrics = createTypedMetrics(telemetry, [schema])
        metrics.counter("network.bytes").add(Double(encodedSize), attributes: ["direction": "out"])
        // README: end
        #expect(telemetry.getMetrics() == [RecordedTelemetryMeasurement(
            kind: .counter, name: "network.bytes", description: "Encoded bytes", unit: "By", value: 64,
            attributes: ["direction": "out"])])
    }

    @Test func typedSchemas() async throws {
        let telemetry = InMemoryTelemetryContext()
        // README: typed-schemas
        let exampleTelemetrySchema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [
            "example.read": TelemetrySpanDefinition(
                description: "Read one resource",
                parents: .any,
                startAttributes: [
                    "example.resource": .init(.string(values: ["account", "project"]),
                                              description: "Resource kind", required: true),
                ],
                endAttributes: [
                    "example.item_count": .init(.number(), description: "Number of returned items"),
                ],
                events: [
                    "example.cache": TelemetryEventDefinition(description: "Cache lookup result", attributes: [
                        "example.cache.hit": .init(.boolean(), description: "Whether the cache contained the resource",
                                                   required: true),
                    ]),
                ],
                status: TelemetryStatusDefinition(errorWhen: "The read throws or returns an error result")
            ),
        ]))

        let startSpan = createTypedSpanStarter(telemetry, [exampleTelemetrySchema])
        let accounts = try await startSpan("example.read", ["example.resource": "account"]) { span, startChildSpan in
            span.addEvent("example.cache", attributes: ["example.cache.hit": true])
            let accounts = try await readAccounts()
            span.setAttributes(["example.item_count": .number(Double(accounts.count))])
            try await startChildSpan("example.read", ["example.resource": "project"]) { childSpan, _ in
                let projects = try await readProjects()
                childSpan.setAttributes(["example.item_count": .number(Double(projects.count))])
            }
            return accounts
        }
        // README: end
        #expect(accounts.count == 2)
        let spans = telemetry.getSpans()
        #expect(spans == [
            RecordedTelemetrySpan(
                id: 1, parentId: nil, context: memoryCarrier(spans, 1), name: "example.read",
                attributes: ["example.resource": "account", "example.item_count": 2],
                events: [RecordedTelemetryEvent(name: "example.cache", attributes: ["example.cache.hit": true])],
                settled: true, endSequence: 2),
            RecordedTelemetrySpan(
                id: 2, parentId: 1, context: memoryCarrier(spans, 2), parentContext: memoryCarrier(spans, 1),
                name: "example.read",
                attributes: ["example.resource": "project", "example.item_count": 1],
                settled: true, endSequence: 1),
        ])
    }
}
