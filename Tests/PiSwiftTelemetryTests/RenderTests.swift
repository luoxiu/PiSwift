// Ports upstream `packages/telemetry/test/render.test.ts` at d9025a5f5.

import Testing
import PiSwiftTelemetry

private func span(
    _ id: String,
    traceId: String = "trace",
    parentId: String? = nil,
    name: String? = nil,
    startedMs: Double = 0,
    endedMs: Double = 10,
    attributes: [String: AttributeValue] = [:],
    events: [StoredSpan.Event] = [],
    links: [StoredSpan.Link] = [],
    status: SpanStatus = .ok
) -> StoredSpan {
    StoredSpan(id: id, traceId: traceId, parentId: parentId, name: name ?? id, startedMs: startedMs, endedMs: endedMs,
               attributes: attributes, events: events, links: links, status: status)
}

@Suite("PiSwiftTelemetryTests.renderTrace")
struct RenderTests {
    // Swift: attributes print in key order, where upstream keeps the object's insertion order
    // (`request`, `attempt`, `cached`, `tags`, `sizes`, `flags`).
    @Test func rendersAnUnorderedTraceWithAttributesDurationsErrorsEventsAndLinks() {
        let root = span("root", startedMs: 1000, endedMs: 1020, attributes: [
            "request": "a b",
            "attempt": 2,
            "cached": false,
            "tags": .stringArray(["a", "b"]),
            "sizes": .numberArray([1, 2]),
            "flags": .booleanArray([true, false]),
        ], events: [
            StoredSpan.Event(name: "checkpoint", timeMs: 2, attributes: ["phase": "tools"]),
            StoredSpan.Event(name: "tick", timeMs: 3.5),
        ], links: [
            StoredSpan.Link(traceId: "remote-trace", spanId: "remote", attributes: ["reason": "steer"]),
            StoredSpan.Link(traceId: "other-trace", spanId: "other"),
        ])
        let first = span("first", parentId: "root", startedMs: 1005, endedMs: 1009.5,
                         status: .error(name: "Error", message: "failed call"))
        let nested = span("nested", parentId: "first", startedMs: 1006, endedMs: 1007)
        let second = span("second", parentId: "root", startedMs: 1010, endedMs: 1012, status: .error(nil))
        let spans = [second, nested, first, root]
        let before = spans
        #expect(renderTrace(spans) == [
            #"root attempt=2 cached=false flags=[true,false] request="a b" sizes=[1,2] tags=["a","b"] (20ms)"#,
            #"  · checkpoint phase="tools" (+2ms)"#,
            "  · tick (+3.5ms)",
            #"  → link trace remote-trace span remote reason="steer""#,
            "  → link trace other-trace span other",
            "  first (4.5ms) error Error: failed call",
            "    nested (1ms)",
            "  second (2ms) error",
        ].joined(separator: "\n"))
        #expect(spans == before)
    }

    @Test func treatsMissingParentsAsRootsAndOrdersRootsAndChildrenByStartTime() {
        #expect(renderTrace([
            span("later", parentId: "external", startedMs: 20, endedMs: 30),
            span("child", parentId: "later", startedMs: 25, endedMs: 30),
            span("earlier", startedMs: 10, endedMs: 15, links: [StoredSpan.Link(traceId: "trace", spanId: "later")]),
        ]) == ["earlier (5ms)", "  → link trace trace span later", "later (10ms)", "  child (5ms)"].joined(separator: "\n"))
    }

    @Test func printsCrossTraceLinksWithoutFollowingThemIncludingCycles() {
        #expect(renderTrace([
            span("server:1", traceId: "server-trace", name: "server",
                 links: [StoredSpan.Link(traceId: "worker-trace", spanId: "worker:1")]),
            span("worker:1", traceId: "worker-trace", name: "worker",
                 links: [StoredSpan.Link(traceId: "server-trace", spanId: "server:1")]),
        ]) == [
            "server (10ms)",
            "  → link trace worker-trace span worker:1",
            "worker (10ms)",
            "  → link trace server-trace span server:1",
        ].joined(separator: "\n"))
    }

    @Test func deduplicatesSpansMergedFromStoresByGlobalId() {
        let root = span("server:1", name: "root")
        let child = span("worker:1", parentId: "server:1", name: "child",
                         events: [StoredSpan.Event(name: "done", timeMs: 3)])
        let grandchild = span("worker:2", parentId: "worker:1", name: "grandchild")
        #expect(renderTrace([child, root, grandchild, root, child])
            == "root (10ms)\n  child (10ms)\n    · done (+3ms)\n    grandchild (10ms)")
    }

    @Test func preservesInputOrderForEqualStartTimesWithoutMutatingTheInput() {
        let spans = [span("root"), span("z", parentId: "root"), span("a", parentId: "root"), span("other")]
        #expect(renderTrace(spans) == "root (10ms)\n  z (10ms)\n  a (10ms)\nother (10ms)")
    }

    @Test func escapesStringAttributeValuesWithoutHidingTheirContents() {
        #expect(renderTrace([span("root", attributes: ["text": "line one\n\"line two\""])])
            == #"root text="line one\n\"line two\"" (10ms)"#)
    }

    @Test func rendersDeepTreesWithoutRecursiveCalls() {
        let spans = (0..<2000).map { index in span(String(index), parentId: index == 0 ? nil : String(index - 1)) }
        let rendered = renderTrace(spans)
        #expect(rendered.split(separator: "\n").count == spans.count)
        #expect(rendered.hasSuffix(String(repeating: "  ", count: 1999) + "1999 (10ms)"))
    }

    @Test func rendersAnEmptyInputAsAnEmptyString() {
        #expect(renderTrace([]) == "")
    }

    // Swift addition: number text is hand-written for JavaScript's `String(number)` and `JSON.stringify`.
    @Test func writesNumbersAsJavaScriptDoes() {
        let values: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-1.5, "-1.5"), (0.1 + 0.2, "0.30000000000000004"), (1e-7, "1e-7"),
            (0.000001, "0.000001"), (1e21, "1e+21"), (123456789012345680000, "123456789012345680000"),
            (1.5e300, "1.5e+300"),
        ]
        for (value, text) in values {
            #expect(renderTrace([span("n", endedMs: value)]) == "n (\(text)ms)")
        }
        #expect(renderTrace([span("n", attributes: ["x": .number(.nan), "y": .numberArray([.infinity, 1])])])
            == "n x=null y=[null,1] (10ms)")
    }
}
