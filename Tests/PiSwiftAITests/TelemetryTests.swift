// Ports upstream `packages/ai/test/telemetry.test.ts` and `telemetry-options.test.ts` at 2ec55d808. Upstream observes
// `Models` requests; PiSwiftAI observes its dispatch functions (`stream`, `streamSimple`, `streamDeferred`, and the
// completion helpers over them). The providers are registered for `.piVirtual` in the serialized registry suite, as the
// deferred tests do.

import Foundation
import Synchronization
import Testing
import PiSwiftTelemetry
@testable import PiSwiftAI

private let telemetryModel = Model(
    id: "model", name: "Model", api: .piVirtual, provider: "test", baseUrl: "https://example.test",
    reasoning: true, input: [.text], cost: ModelCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4),
    contextWindow: 1000, maxTokens: 100)
private let telemetryHandle = DeferredHandle(provider: "test", modelId: "model", api: Api.piVirtual.rawValue, id: "deferred-secret")
private let telemetryContext = Context(messages: [])

private func telemetryMessage(_ stopReason: StopReason = .stop, errorMessage: String? = nil) -> AssistantMessage {
    AssistantMessage(
        content: [
            .text(TextContent(text: "text-secret")),
            .thinking(ThinkingContent(thinking: "thinking-secret")),
            .toolCall(ToolCall(id: "call-secret", name: "lookup", arguments: ["value": AnyCodable("argument-secret")])),
        ],
        api: .piVirtual, provider: "test", model: "model", responseId: "response",
        usage: Usage(input: 11, output: 22, cacheRead: 33, cacheWrite: 44, totalTokens: 110,
                     cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1)),
        stopReason: stopReason, errorMessage: errorMessage)
}

private func telemetryEvents(_ result: AssistantMessage) -> [AssistantMessageEvent] {
    guard case .toolCall(let toolCall) = result.content[2] else { return [] }
    let terminal: AssistantMessageEvent = switch result.stopReason {
    case .error, .aborted: .error(reason: result.stopReason, error: result)
    case .pending: .done(reason: .deferred, message: result)
    default: .done(reason: result.stopReason, message: result)
    }
    return [
        .start(partial: result),
        .textDelta(contentIndex: 0, delta: "text-secret", partial: result),
        .textEnd(contentIndex: 0, content: "text-secret", partial: result),
        .thinkingEnd(contentIndex: 1, content: "thinking-secret", partial: result),
        .toolCallDelta(contentIndex: 2, delta: #"{"value":"#, partial: result),
        .toolCallDelta(contentIndex: 2, delta: #""argument-secret"}"#, partial: result),
        .toolCallEnd(contentIndex: 2, toolCall: toolCall, partial: result),
        terminal,
    ]
}

/// A comparable shape of an event: its kind, index, and text; the partial message is the same in every event.
private func shape(_ event: AssistantMessageEvent) -> String {
    switch event {
    case .start: "start"
    case .textStart(let index, _): "text_start \(index)"
    case .textDelta(let index, let delta, _): "text_delta \(index) \(delta)"
    case .textEnd(let index, let content, _): "text_end \(index) \(content)"
    case .thinkingStart(let index, _): "thinking_start \(index)"
    case .thinkingDelta(let index, let delta, _): "thinking_delta \(index) \(delta)"
    case .thinkingEnd(let index, let content, _): "thinking_end \(index) \(content)"
    case .toolCallStart(let index, _): "toolcall_start \(index)"
    case .toolCallDelta(let index, let delta, _): "toolcall_delta \(index) \(delta)"
    case .toolCallEnd(let index, let call, _): "toolcall_end \(index) \(call.name)"
    case .done(let reason, let message): "done \(reason.rawValue) \(message.stopReason.rawValue)"
    case .error(let reason, let message): "error \(reason.rawValue) \(message.stopReason.rawValue)"
    }
}

private final class Calls: Sendable {
    private let state = Mutex<[String]>([])
    func append(_ value: String) { state.withLock { $0.append(value) } }
    var values: [String] { state.withLock { $0 } }
}

/// Registers a `.piVirtual` provider answering every request with `result` and its events; returns the source ID.
private func registerTelemetryProvider(_ result: AssistantMessage = telemetryMessage()) -> String {
    let events = telemetryEvents(result)
    let respond: @Sendable () -> AssistantMessageEventStream = {
        let stream = AssistantMessageEventStream()
        for event in events { stream.push(event) }
        stream.end(result)
        return stream
    }
    let sourceId = "telemetry-\(UUID().uuidString)"
    registerApiProvider(ApiProvider(api: .piVirtual, stream: { _, _, _ in respond() }, streamSimple: { _, _, _ in respond() },
                                    fetchDeferred: { _, _, _ in respond() }, cancelDeferred: { _, _, _ in }), sourceId: sourceId)
    return sourceId
}

private func settled(_ telemetry: InMemoryTelemetryContext) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !telemetry.getSpans().allSatisfy(\.settled) || telemetry.getSpans().isEmpty {
        guard ContinuousClock.now < deadline else { Issue.record("Spans did not settle"); return }
        await Task.yield()
    }
}

private func json(_ span: RecordedTelemetrySpan) -> String { String(describing: span) }

/// A span that forwards to `inner`, with its own `metrics`.
private final class MetricsOverrideSpan: TelemetrySpan {
    let inner: any TelemetrySpan
    let override: (any TelemetryMetrics)?
    init(_ inner: any TelemetrySpan, metrics: (any TelemetryMetrics)?) { self.inner = inner; override = metrics }
    var metrics: (any TelemetryMetrics)? { override }
    var propagation: (any TelemetryPropagation)? { inner.propagation }
    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions, _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T { try await inner.startSpan(options, body) }
    func addLink(_ link: SpanLink) { inner.addLink(link) }
    func addEvent(_ name: String, attributes: SpanAttributes?) { inner.addEvent(name, attributes: attributes) }
    func setAttributes(_ attributes: SpanAttributes) { inner.setAttributes(attributes) }
    func setStatus(_ status: SpanStatus) { inner.setStatus(status) }
}

/// Metrics that count factory calls and record into an in-memory adapter.
private final class CountingMetrics: TelemetryMetrics {
    let inner = InMemoryTelemetryContext()
    let histograms = Calls(), counters = Calls()
    func counter(_ name: String, options: InstrumentOptions?) -> any TelemetryCounter {
        counters.append(name); return inner.counter(name, options: options)
    }
    func upDownCounter(_ name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter {
        inner.upDownCounter(name, options: options)
    }
    func histogram(_ name: String, options: HistogramOptions?) -> any TelemetryHistogram {
        histograms.append(name); return inner.histogram(name, options: options)
    }
}

extension ApiRegistryTests {
    // MARK: telemetry-options.test.ts

    @Test func telemetryIsInheritedByEveryRequestOptionSurface() {
        let telemetry = noopTelemetryContext
        #expect(StreamOptions(telemetry: telemetry).telemetry === telemetry)
        #expect(SimpleStreamOptions(telemetry: telemetry).telemetry === telemetry)
        #expect(DeferredFetchOptions(telemetry: telemetry).telemetry === telemetry)
        #expect(DeferredCancelOptions(telemetry: telemetry).telemetry === telemetry)
        #expect(ImagesOptions(telemetry: telemetry).telemetry === telemetry)
    }

    @Test func telemetrySurvivesProviderAndDispatchStreamAndDeferredCalls() async throws {
        let telemetry = noopTelemetryContext
        let observed = Mutex<[(any TelemetrySpan)?]>([])
        let completed: @Sendable (Model) -> AssistantMessageEventStream = { model in
            let stream = AssistantMessageEventStream()
            Task { stream.push(.done(reason: .stop, message: AssistantMessage(
                content: [], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop, timestamp: 0))) }
            return stream
        }
        let provider = ApiProvider(
            api: .piVirtual,
            stream: { model, _, options in observed.withLock { $0.append(options?.telemetry) }; return completed(model) },
            streamSimple: { model, _, options in observed.withLock { $0.append(options?.telemetry) }; return completed(model) },
            fetchDeferred: { model, _, options in observed.withLock { $0.append(options?.telemetry) }; return completed(model) },
            cancelDeferred: { _, _, options in observed.withLock { $0.append(options?.telemetry) } })
        let context = normalizeContext(telemetryContext)
        _ = await provider.stream(telemetryModel, context, StreamOptions(telemetry: telemetry)).result()
        _ = await provider.streamSimple(telemetryModel, context, SimpleStreamOptions(telemetry: telemetry)).result()
        let fetch = try #require(provider.fetchDeferred), cancel = try #require(provider.cancelDeferred)
        _ = await fetch(telemetryModel, telemetryHandle, DeferredFetchOptions(telemetry: telemetry)).result()
        try await cancel(telemetryModel, telemetryHandle, DeferredCancelOptions(telemetry: telemetry))

        let sourceId = "telemetry-options-\(UUID().uuidString)"
        registerApiProvider(provider, sourceId: sourceId)
        defer { unregisterApiProviders(sourceId: sourceId) }
        _ = try await complete(model: telemetryModel, context: telemetryContext, options: StreamOptions(telemetry: telemetry))
        _ = try await completeSimple(model: telemetryModel, context: telemetryContext, options: SimpleStreamOptions(telemetry: telemetry))
        _ = try await fetchDeferred(model: telemetryModel, handle: telemetryHandle, options: DeferredFetchOptions(telemetry: telemetry))
        try await cancelDeferred(model: telemetryModel, handle: telemetryHandle, options: DeferredCancelOptions(telemetry: telemetry))

        let values = observed.withLock { $0 }
        #expect(values.count == 8)
        #expect(values.allSatisfy { $0 === telemetry })
    }

    // Swift: there is one image dispatch, `generateImages`; the provider is reached directly and through it (with an
    // explicit lookup, so the shared image registry is untouched).
    @Test func telemetrySurvivesDirectAndDispatchedImageCalls() async {
        let telemetry = noopTelemetryContext
        let observed = Mutex<[(any TelemetrySpan)?]>([])
        let imageModel = ImageModel(id: "image-model", name: "Image Model", api: .openrouterImages,
                                    provider: "telemetry-image-provider", baseUrl: "https://example.test",
                                    input: [.text], output: [.image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        let provider = ImageApiProvider(api: .openrouterImages) { model, _, options in
            observed.withLock { $0.append(options?.telemetry) }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
        }
        let context = ImagesContext(input: [.text(TextContent(text: "circle"))])
        _ = await provider.generateImages(imageModel, context, ImagesOptions(telemetry: telemetry))
        _ = await generateImages(model: imageModel, context: context, options: ImagesOptions(telemetry: telemetry),
                                 provider: { _ in provider })
        #expect(observed.withLock { $0.count } == 2)
        #expect(observed.withLock { $0 }.allSatisfy { $0 === telemetry })
    }

    // MARK: telemetry.test.ts

    enum TelemetryMethod: String, CaseIterable, Sendable { case stream, streamSimple, streamDeferred }

    @Test(arguments: TelemetryMethod.allCases)
    func observesARequestWithoutChangingDeliveredEventsOrResults(method: TelemetryMethod) async throws {
        let telemetry = InMemoryTelemetryContext()
        let result = telemetryMessage()
        let sourceId = registerTelemetryProvider(result)
        defer { unregisterApiProviders(sourceId: sourceId) }
        try await telemetry.startSpan(SpanOptions(name: "caller")) { parent in
            let stream = switch method {
            case .stream: try PiSwiftAI.stream(model: telemetryModel, context: telemetryContext, options: StreamOptions(telemetry: parent))
            case .streamSimple: try streamSimple(model: telemetryModel, context: telemetryContext,
                                                 options: SimpleStreamOptions(reasoning: .high, telemetry: parent))
            case .streamDeferred: try streamDeferred(model: telemetryModel, handle: telemetryHandle,
                                                     options: DeferredFetchOptions(telemetry: parent))
            }
            var received: [AssistantMessageEvent] = []
            for await event in stream { received.append(event) }
            #expect(received.map(shape) == telemetryEvents(result).map(shape))
            let final = await stream.result()
            #expect(final.responseId == result.responseId && final.usage.input == 11 && final.stopReason == .stop)
        }
        try await settled(telemetry)
        let spans = telemetry.getSpans()
        let parent = spans[0], span = spans[1]
        #expect(span.name == (method == .streamDeferred ? "pi.ai.poll" : "pi.ai.request"))
        #expect(span.parentId == parent.id)
        // Swift: `stream()` takes no reasoning (StreamOptions has none), so only `streamSimple` records it.
        var expected: [String: AttributeValue] = [
            "provider": "test", "api": "pi-virtual", "model": "model", "stop": "stop",
            "usage.input": 11, "usage.output": 22, "usage.cache_read": 33, "usage.cache_write": 44, "cost.total": 1,
            "response.id": "response",
        ]
        if method == .streamSimple { expected["reasoning"] = "high" }
        #expect(span.attributes == expected)
        #expect(span.events == [
            RecordedTelemetryEvent(name: "pi.ai.first_chunk"),
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "text", "index": 0, "chars": 11]),
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "thinking", "index": 1, "chars": 15]),
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "tool_call", "index": 2, "chars": 27, "tool": "lookup"]),
        ])
        for secret in ["text-secret", "thinking-secret", "argument-secret", "call-secret", "deferred-secret"] {
            #expect(!json(span).contains(secret))
        }
        let measurements = telemetry.getMetrics()
        #expect(measurements.count == 7)
        #expect(measurements.filter { $0.kind == .counter }.map(\.value) == [11, 22, 33, 44, 1])
        for measurement in measurements {
            let keys = measurement.attributes.keys.sorted()
            switch measurement.name {
            case "pi.ai.tokens": #expect(keys == ["kind", "model", "provider"])
            case "pi.ai.request.duration": #expect(keys == ["model", "provider", "stop"])
            default: #expect(keys == ["model", "provider"])
            }
            if measurement.kind == .histogram { #expect(measurement.context == span.context) }
        }
    }

    @Test(arguments: [StopReason.error, .aborted])
    func reportsErrorAndAbortedStatusWithoutErrorAttributesOrEvents(reason: StopReason) async throws {
        let telemetry = InMemoryTelemetryContext()
        let result = telemetryMessage(reason, errorMessage: "error-secret")
        let sourceId = registerTelemetryProvider(result)
        defer { unregisterApiProviders(sourceId: sourceId) }
        let final = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await completeSimple(model: telemetryModel, context: telemetryContext, options: SimpleStreamOptions(telemetry: span))
        }
        #expect(final.stopReason == reason && final.errorMessage == "error-secret")
        try await settled(telemetry)
        let span = telemetry.getSpans()[1]
        #expect(span.status == (reason == .error ? .error(name: "provider_error", message: "error-secret") : .ok))
        #expect(span.attributes["stop"] == .string(reason.rawValue))
        #expect(!String(describing: span.attributes).contains("error-secret"))
        #expect(!String(describing: span.events).contains("error-secret"))
        if reason == .aborted { #expect(!json(span).contains("error-secret")) }
    }

    @Test(arguments: [false, true])
    func boundsPollErrorMessagesIncludingMissingMessages(missing: Bool) async throws {
        let telemetry = InMemoryTelemetryContext()
        let result = telemetryMessage(.error, errorMessage: missing ? nil : String(repeating: "x", count: 500) + "discarded-tail")
        let sourceId = registerTelemetryProvider(result)
        defer { unregisterApiProviders(sourceId: sourceId) }
        let final = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await fetchDeferred(model: telemetryModel, handle: telemetryHandle, options: DeferredFetchOptions(telemetry: span))
        }
        #expect(final.stopReason == .error)
        try await settled(telemetry)
        let span = telemetry.getSpans()[1]
        #expect(span.status == .error(name: "provider_error", message: missing ? "" : String(repeating: "x", count: 500)))
        #expect(!json(span).contains("discarded-tail"))
        #expect(!String(describing: span.attributes).contains("xxx"))
        #expect(!String(describing: span.events).contains("xxx"))
    }

    // Swift: a setup failure throws from the dispatch function, where upstream's `Models` returns an error stream; the
    // span records it as upstream records the setup error event. `stream()` has no reasoning option, native or not.
    @Test func includesSetupFailuresAndOmitsNonScalarNativeReasoning() async throws {
        let telemetry = InMemoryTelemetryContext()
        try #require(getApiProvider(.piVirtual) == nil)
        await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            #expect(throws: StreamError.self) {
                _ = try PiSwiftAI.stream(model: telemetryModel, context: telemetryContext, options: StreamOptions(telemetry: span))
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while telemetry.getSpans().count < 2 || !telemetry.getSpans().allSatisfy(\.settled) {
            guard ContinuousClock.now < deadline else { Issue.record("The setup failure span did not settle"); return }
            await Task.yield()
        }
        let span = telemetry.getSpans()[1]
        #expect(span.attributes["reasoning"] == nil)
        #expect(span.events == [RecordedTelemetryEvent(name: "pi.ai.first_chunk")])
        #expect(span.status == .error(name: "provider_error", message: "No API provider registered for api: pi-virtual"))
        #expect(!String(describing: span.attributes).contains("No API provider"))
    }

    // Swift: upstream's tool call has an `arguments` getter that throws, so reading it fails the test; Swift arguments
    // are a value. The observer still never reads them.
    @Test func countsInterleavedToolDeltasIndependently() async throws {
        let telemetry = InMemoryTelemetryContext()
        let result = telemetryMessage()
        await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            await observeModelRequest(telemetryModel, telemetry: span, reasoning: nil, poll: false, started: 0) { observer in
                let toolCall = ToolCall(id: "call", name: "lookup", arguments: [:])
                for (index, delta) in [(2, "ab"), (3, "123"), (2, "c")] {
                    observer.onEvent(.toolCallDelta(contentIndex: index, delta: delta, partial: result))
                }
                observer.onEvent(.toolCallEnd(contentIndex: 3, toolCall: toolCall, partial: result))
                observer.onEvent(.toolCallEnd(contentIndex: 2, toolCall: toolCall, partial: result))
                observer.onEvent(.toolCallEnd(contentIndex: 4, toolCall: toolCall, partial: result))
                observer.onResult(result)
            }
        }
        try await settled(telemetry)
        #expect(Array(telemetry.getSpans()[1].events.dropFirst()) == [
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "tool_call", "index": 3, "chars": 3, "tool": "lookup"]),
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "tool_call", "index": 2, "chars": 3, "tool": "lookup"]),
            RecordedTelemetryEvent(name: "pi.ai.block", attributes: ["type": "tool_call", "index": 4, "chars": 0, "tool": "lookup"]),
        ])
    }

    @Test func supportsATracingOnlySpanWithoutMetricCapabilities() async throws {
        let adapter = InMemoryTelemetryContext()
        let sourceId = registerTelemetryProvider()
        defer { unregisterApiProviders(sourceId: sourceId) }
        _ = try await adapter.startSpan(SpanOptions(name: "caller")) { span in
            try await completeSimple(model: telemetryModel, context: telemetryContext,
                                     options: SimpleStreamOptions(telemetry: MetricsOverrideSpan(span, metrics: nil)))
        }
        try await settled(adapter)
        #expect(adapter.getSpans().count == 2)
        #expect(adapter.getMetrics().isEmpty)
    }

    @Test func defaultsToNoopTelemetry() async throws {
        let sourceId = registerTelemetryProvider()
        defer { unregisterApiProviders(sourceId: sourceId) }
        #expect(try await completeSimple(model: telemetryModel, context: telemetryContext).stopReason == .stop)
        #expect(aiTelemetrySchema.spans["pi.ai.request"]?.startAttributes["provider"]?.required == true)
    }

    @Test func recordsLowCardinalityMetricsWithMonotonicDurations() async throws {
        let telemetry = InMemoryTelemetryContext()
        let result = telemetryMessage()
        let clock = Mutex(100.0)
        await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            await observeModelRequest(telemetryModel, telemetry: span, reasoning: nil, poll: false, started: clock.withLock { $0 },
                                      now: { clock.withLock { $0 } }) { observer in
                clock.withLock { $0 = 125 }
                observer.onEvent(.start(partial: result))
                clock.withLock { $0 = 175 }
                observer.onResult(result)
            }
        }
        try await settled(telemetry)
        let metrics = telemetry.getMetrics()
        struct Row: Equatable { let name: String; let value: Double; let attributes: [String: AttributeValue]; let unit: String? }
        let base: [String: AttributeValue] = ["provider": "test", "model": "model"]
        #expect(metrics.map { Row(name: $0.name, value: $0.value, attributes: $0.attributes, unit: $0.unit) } == [
            Row(name: "pi.ai.first_chunk.duration", value: 25, attributes: base, unit: "ms"),
            Row(name: "pi.ai.request.duration", value: 75, attributes: base.merging(["stop": "stop"]) { $1 }, unit: "ms"),
        ] + [("input", 11.0), ("output", 22), ("cache_read", 33), ("cache_write", 44)].map { kind, value in
            Row(name: "pi.ai.tokens", value: value, attributes: base.merging(["kind": .string(kind)]) { $1 }, unit: "token")
        } + [Row(name: "pi.ai.cost", value: 1, attributes: base, unit: "USD")])
        #expect(metrics.prefix(2).allSatisfy { $0.context != nil })
    }

    @Test(arguments: [StopReason.pending, .deferred, .stop, .error])
    func recordsUsageForAPollOnlyWhenFinal(reason: StopReason) async throws {
        let telemetry = InMemoryTelemetryContext()
        let sourceId = registerTelemetryProvider(telemetryMessage(reason))
        defer { unregisterApiProviders(sourceId: sourceId) }
        _ = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await fetchDeferred(model: telemetryModel, handle: telemetryHandle, options: DeferredFetchOptions(telemetry: span))
        }
        try await settled(telemetry)
        let counters = telemetry.getMetrics().filter { $0.kind == .counter }
        #expect(counters.count == (reason == .pending || reason == .deferred ? 0 : 5))
    }

    // Swift: upstream spies on the adapter's factories; here the parent spans carry a metrics object that counts them.
    @Test func createsInstrumentsOncePerMetricsObjectAcrossRootAndChildRequests() async throws {
        let telemetry = InMemoryTelemetryContext()
        let metrics = CountingMetrics()
        let sourceId = registerTelemetryProvider()
        defer { unregisterApiProviders(sourceId: sourceId) }
        _ = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await completeSimple(model: telemetryModel, context: telemetryContext,
                                     options: SimpleStreamOptions(telemetry: MetricsOverrideSpan(span, metrics: metrics)))
        }
        _ = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await fetchDeferred(model: telemetryModel, handle: telemetryHandle,
                                    options: DeferredFetchOptions(telemetry: MetricsOverrideSpan(span, metrics: metrics)))
        }
        _ = try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            try await complete(model: telemetryModel, context: telemetryContext,
                               options: StreamOptions(telemetry: MetricsOverrideSpan(span, metrics: metrics)))
        }
        try await settled(telemetry)
        #expect(metrics.histograms.values == ["pi.ai.request.duration", "pi.ai.first_chunk.duration"])
        #expect(metrics.counters.values == ["pi.ai.tokens", "pi.ai.cost"])
        #expect(metrics.inner.getMetrics().count == 21)
    }

    // MARK: lazyStream observation (Swift: `forwardObserved`, the observed forwarding of the dispatch functions)

    private final class OrderObserver: RequestObservation {
        let order = Calls()
        let results = Mutex<[AssistantMessage?]>([])
        func onEvent(_ event: AssistantMessageEvent) { order.append("event") }
        func onResult(_ message: AssistantMessage?) { order.append("result"); results.withLock { $0.append(message) } }
    }

    // Swift: upstream also checks that a result waiter resolves before `onResult`, by a microtask; Swift has no ordering
    // between the task awaiting the result and the forwarding task, so this checks the push before each observation.
    @Test func forwardingUsesOneSourceIteratorAndObservesAfterPushOncePerTerminalResult() async {
        let result = telemetryMessage()
        let inner = AssistantMessageEventStream(), outer = AssistantMessageEventStream()
        inner.push(.done(reason: .stop, message: result))
        let observer = OrderObserver()
        await forwardObserved(inner, to: outer, observer)
        #expect(await outer.result().responseId == "response")
        #expect(observer.order.values == ["event", "result"])
        #expect(observer.results.withLock { $0.count } == 1)
    }

    @Test func forwardingObservesAResultOnlySourceOnce() async {
        let result = telemetryMessage()
        let inner = AssistantMessageEventStream(), outer = AssistantMessageEventStream()
        inner.end(result)
        let observer = OrderObserver()
        await forwardObserved(inner, to: outer, observer)
        #expect(await outer.result().responseId == "response")
        #expect(observer.order.values == ["result"])
    }

    // Swift: upstream's setup failure is an error event and the result; a Swift setup failure throws, and is recorded as
    // that event and result before the throw (see `includesSetupFailuresAndOmitsNonScalarNativeReasoning`). An iterable
    // without a `result()` method has no Swift counterpart: every stream has one.
}
