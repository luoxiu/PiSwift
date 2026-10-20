// Ports upstream `packages/telemetry/test/conformance.test.ts` at 48909d987.

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
        // Upstream's two "passivity" cases and "recording: ignores failed attribute calls atomically"
        // pass Proxy values that throw on read. Swift values cannot, so those three are not ported.
        #expect(inMemoryConformance.map(\.description) == [
            "metrics: records ordered measurements and optional histogram exemplars",
            "metrics: copies inputs and suppresses invalid measurements atomically",
            "links: records initial and late links without changing parents",
            "links: suppresses malformed links atomically and ignores settled sources",
            "propagation: roundtrips parent identity through JSON without retaining the carrier",
            "propagation: unknown and unreadable carriers produce recorded roots",
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
