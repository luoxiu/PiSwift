// Ports upstream `packages/telemetry/test/conformance.test.ts` at d9025a5f5.

import Testing
import PiSwiftTelemetry
import PiSwiftTelemetryTesting

private let inMemoryConformance = createTelemetryAdapterConformance {
    let context = InMemoryTelemetryContext()
    return TelemetryAdapterFixture(context: context, propagation: context, metrics: context,
                                   getMetrics: { context.getMetrics() }, getSpans: { context.getSpans() })
}

@Suite("PiSwiftTelemetryTests.InMemoryTelemetryContext conformance")
struct InMemoryTelemetryConformanceTests {
    @Test(arguments: inMemoryConformance)
    func conformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
        try await testCase.run()
    }

    @Test func returnsDetachedSnapshotsWithoutExposingMutableRecordingState() async throws {
        let context = InMemoryTelemetryContext()
        var openSettled: Bool?
        var openEndSequence: Int?
        await context.startSpan(SpanOptions(name: "snapshot", attributes: ["tags": .stringArray(["initial"])])) { span in
            span.addEvent("event", attributes: ["value": 1])
            let open = context.getSpans().first
            openSettled = open?.settled
            openEndSequence = open?.endSequence
        }

        #expect(openSettled == false)
        #expect(openEndSequence == nil)
        var first = try #require(context.getSpans().first)
        #expect(first.settled)
        #expect(first.endSequence == 1)
        first.attributes["tags"] = .stringArray(["mutated"])
        first.events[0].attributes["value"] = 2

        let second = try #require(context.getSpans().first)
        #expect(second.attributes == ["tags": .stringArray(["initial"])])
        #expect(second.events == [RecordedTelemetryEvent(name: "event", attributes: ["value": 1])])
    }

    @Test func conformanceKeepsUpstreamGroupsAndNames() {
        #expect(inMemoryConformance.map(\.description) == [
            "capabilities: carries adapter capabilities through contexts and spans",
            "metrics: records ordered measurements and optional histogram exemplars",
            "metrics: copies instrument metadata and measurement attributes",
            "links: records initial and late links without changing parents",
            "links: ignores links added after source settlement",
            "propagation: roundtrips parent identity through JSON without retaining the carrier",
            "propagation: absent and unknown carriers produce recorded roots",
            "propagation: propagates across fresh adapters and multiple hops",
            "callback lifecycle: admits once synchronously and preserves the result",
            "callback lifecycle: preserves synchronous and asynchronous rejection values",
            "status: uses last explicit status without automatic overwrite",
            "recording: merges attributes and records ordered events",
            "recording: makes calls after settlement inert",
            "parentage: records nested and concurrent child relationships",
        ])
    }
}
