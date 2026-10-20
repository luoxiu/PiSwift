// Ports upstream `packages/telemetry/test/propagation.test.ts` at d9025a5f5.

import Foundation
import Synchronization
import Testing
import PiSwiftTelemetry

private func throughJSON(_ carrier: TelemetryCarrier?) throws -> TelemetryCarrier {
    try JSONDecoder().decode(TelemetryCarrier.self, from: JSONEncoder().encode(try #require(carrier)))
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

private final class SpanBox: Sendable {
    private let state = Mutex<(any TelemetrySpan)?>(nil)
    var span: (any TelemetrySpan)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@Suite("PiSwiftTelemetryTests.propagation and links")
struct PropagationTests {
    // Swift: upstream runs the receiver in a child Node process, which shares no WeakMap of carriers with the caller.
    // The Swift recorder keeps no carrier registry outside its own spans and parents, so a fresh recorder in this
    // process given the carrier through JSON receives only the carrier, the same.
    @Test func continuesAParentInAnotherRecorderWithoutSharedRecorderState() async throws {
        let telemetry = InMemoryTelemetryContext()
        var carrier: TelemetryCarrier?
        await telemetry.startSpan(SpanOptions(name: "caller")) { span in carrier = telemetry.inject(span) }
        let wire = try JSONEncoder().encode(try #require(carrier))
        let remote = InMemoryTelemetryContext()
        await remote.extract(try JSONDecoder().decode(TelemetryCarrier.self, from: wire)).startSpan(SpanOptions(name: "remote")) { _ in }
        let recorded = remote.getSpans()
        #expect(recorded.count == 1)
        #expect(recorded.first?.parentContext == carrier)
        #expect(recorded.first?.parentId == nil)
        #expect(recorded.first?.context != carrier)
    }

    // Swift: upstream starts both callers at once and their callbacks interleave at awaits; here `later` starts once
    // `first` has opened the shared activation, the order upstream's microtasks give.
    @Test func isolatesCrossedConcurrentRemoteParentsAndLinksSharedRoots() async throws {
        let caller = InMemoryTelemetryContext()
        let provider = InMemoryTelemetryContext()
        let activation = SpanBox(), started = Gate(), finish = Gate()
        async let first: Void = caller.startSpan(SpanOptions(name: "first")) { trigger in
            let parent = provider.extract(caller.inject(trigger))
            await parent.startSpan(SpanOptions(name: "first.method")) { getter in
                async let shared: Void = provider.startSpan(SpanOptions(
                    name: "activation", links: [SpanLink(context: getter)])) { span in
                    activation.span = span
                    started.open()
                    await finish.wait()
                }
                await started.wait()
                if let span = activation.span { getter.addLink(SpanLink(context: span)) }
                await shared
            }
        }
        await started.wait()
        await caller.startSpan(SpanOptions(name: "later")) { trigger in
            let parent = provider.extract(caller.inject(trigger))
            await parent.startSpan(SpanOptions(name: "later.method")) { getter in
                if let span = activation.span { getter.addLink(SpanLink(context: span)) }
                finish.open()
            }
        }
        await first
        let spans = provider.getSpans()
        let root = try #require(spans.first { $0.name == "activation" })
        #expect(root.parentContext == nil)
        let firstMethod = try #require(spans.first { $0.name == "first.method" })
        let laterMethod = try #require(spans.first { $0.name == "later.method" })
        #expect(firstMethod.parentContext == caller.getSpans()[0].context)
        #expect(laterMethod.parentContext == caller.getSpans()[1].context)
        #expect(root.links.first?.context == firstMethod.context)
        #expect(laterMethod.links.first?.context == root.context)
    }

    @Test func detachesCarrierAndLinkSnapshotsAndRetainsSettledTargetIdentities() async throws {
        let telemetry = InMemoryTelemetryContext()
        var target: (any TelemetrySpan)?
        await telemetry.startSpan(SpanOptions(name: "target")) { span in target = span }
        let settled = try #require(target)
        let original = telemetry.inject(settled)
        var injected = try #require(telemetry.inject(settled))
        injected["pi-memory-span"] = "999"
        #expect(telemetry.inject(settled) == original)
        await telemetry.startSpan(SpanOptions(
            name: "linked", links: [SpanLink(context: settled, attributes: ["tags": .stringArray(["original"])])]
        )) { _ in }
        var spans = telemetry.getSpans()
        spans[0].context["pi-memory-span"] = "123"
        spans[1].links[0].context["pi-memory-span"] = "456"
        spans[1].links[0].attributes["tags"] = .stringArray(["mutated"])
        #expect(telemetry.getSpans()[1].links == [
            RecordedTelemetryLink(context: try #require(original), attributes: ["tags": .stringArray(["original"])]),
        ])
    }

    @Test func linksANewRootToAnExtractedRemoteTarget() async throws {
        let sender = InMemoryTelemetryContext()
        let receiver = InMemoryTelemetryContext()
        var carrier: TelemetryCarrier?
        await sender.startSpan(SpanOptions(name: "trigger")) { span in carrier = sender.inject(span) }
        let target = receiver.extract(try throughJSON(carrier))
        await receiver.startSpan(SpanOptions(
            name: "background", links: [SpanLink(context: target, attributes: ["reason": "restart"])]
        )) { span in
            span.addLink(SpanLink(context: target))
        }
        let recorded = try #require(receiver.getSpans().first)
        #expect(recorded.parentContext == nil)
        let sent = try #require(carrier)
        #expect(recorded.links == [
            RecordedTelemetryLink(context: sent, attributes: ["reason": "restart"]),
            RecordedTelemetryLink(context: sent, attributes: [:]),
        ])
    }

    @Test func usesTheRootForAbsentAndUnknownCarriers() async {
        let telemetry = InMemoryTelemetryContext()
        let carriers: [TelemetryCarrier?] = [nil, [:], ["unknown": "format"]]
        for carrier in carriers {
            #expect(telemetry.extract(carrier) === telemetry)
        }
        #expect(noopTelemetryPropagation.inject(noopTelemetryContext) == nil)
        #expect(noopTelemetryPropagation.extract(["unknown": "format"]) === noopTelemetryContext)
        await noopTelemetryContext.startSpan(SpanOptions(name: "noop")) { span in
            span.addLink(SpanLink(context: span))
        }
    }

    @Test func treatsRecognizedCarrierIdentifiersAsOpaqueStrings() async {
        let telemetry = InMemoryTelemetryContext()
        let carrier = [
            "pi-memory-scope": "external-recorder",
            "pi-memory-span": "external-span",
            "pi-memory-trace": "external-trace",
        ]
        await telemetry.extract(carrier).startSpan(SpanOptions(name: "receiver")) { _ in }
        #expect(telemetry.getSpans().first?.parentContext == carrier)
    }

    // Swift addition: a carrier missing any of its three keys gives the root and extra keys are dropped; only a span of
    // this recorder's scope gets a local parent ID, even where another recorder has a span with the same number; and a
    // child inherits its parent's trace, local or remote.
    @Test func keepsTheThreeKeysAndGivesLocalParentIdsOnlyInItsOwnScope() async throws {
        let telemetry = InMemoryTelemetryContext()
        let complete = ["pi-memory-scope": "s", "pi-memory-span": "1", "pi-memory-trace": "t"]
        for key in complete.keys {
            var incomplete = complete
            incomplete[key] = nil
            #expect(telemetry.extract(incomplete) === telemetry, "\(incomplete)")
        }
        var extra = complete
        extra["extra"] = "x"
        #expect(telemetry.inject(telemetry.extract(extra)) == complete)
        await telemetry.extract(extra).startSpan(SpanOptions(name: "remote-trace")) { _ in }
        var own: TelemetryCarrier?
        await telemetry.startSpan(SpanOptions(name: "own")) { span in own = telemetry.inject(span) }
        await telemetry.extract(own).startSpan(SpanOptions(name: "local")) { _ in }
        let foreign = InMemoryTelemetryContext()
        var other: TelemetryCarrier?
        await foreign.startSpan(SpanOptions(name: "foreign")) { span in other = foreign.inject(span) }
        #expect(other?["pi-memory-span"] == "1")
        await telemetry.extract(other).startSpan(SpanOptions(name: "remote")) { _ in }
        let spans = telemetry.getSpans()
        let ownSpan = try #require(spans.first { $0.name == "own" })
        let scope = try #require(ownSpan.context["pi-memory-scope"])
        #expect(ownSpan.context["pi-memory-trace"] == "\(scope):\(ownSpan.id)")
        #expect(spans.first { $0.name == "remote-trace" }?.context["pi-memory-trace"] == "t")
        #expect(spans.first { $0.name == "remote-trace" }?.parentId == nil)
        #expect(spans.first { $0.name == "local" }?.parentId == ownSpan.id)
        #expect(spans.first { $0.name == "local" }?.context["pi-memory-trace"] == ownSpan.context["pi-memory-trace"])
        #expect(spans.first { $0.name == "remote" }?.parentId == nil)
        #expect(spans.first { $0.name == "remote" }?.parentContext == other)
        #expect(spans.first { $0.name == "remote" }?.context["pi-memory-trace"] == other?["pi-memory-trace"])
    }
}
