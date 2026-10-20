// Ports upstream `packages/ai/src/telemetry.ts` and the observation half of `packages/ai/src/api/lazy.ts` at
// 2ec55d808. Upstream observes `Models` requests through `lazyStream`; PiSwiftAI has no `Models` object, so the
// dispatch functions `stream`, `streamSimple`, and `streamDeferred` (and `complete`, `completeSimple`, and
// `fetchDeferred`, which use them) start the spans when the request options carry a parent span.

import Foundation
import Synchronization
import PiSwiftTelemetry

private let provider = TelemetryStartAttributeDefinition(.string(), description: "Provider identifier.", required: true)
private let model = TelemetryStartAttributeDefinition(.string(), description: "Requested model identifier.", required: true)
private let stopValues = ["pending", "stop", "length", "toolUse", "error", "aborted", "deferred"]
private let request = TelemetrySpanDefinition(
    description: "One logical model request, including authentication and provider setup.",
    parents: .any,
    startAttributes: [
        "provider": provider,
        "api": .init(.string(), description: "API identifier.", required: true),
        "model": model,
        "reasoning": .init(.string(), description: "Scalar requested reasoning level.", required: false),
    ],
    endAttributes: [
        "stop": .init(.string(values: stopValues), description: "Normalized stop reason."),
        "usage.input": .init(.number(), description: "Uncached input tokens."),
        "usage.output": .init(.number(), description: "Output tokens."),
        "usage.cache_read": .init(.number(), description: "Cache-read tokens."),
        "usage.cache_write": .init(.number(), description: "Cache-write tokens."),
        "cost.total": .init(.number(), description: "Total request cost in USD."),
        "response.id": .init(.string(), description: "Provider response identifier.", cardinality: .high),
    ],
    events: [
        "pi.ai.first_chunk": TelemetryEventDefinition(description: "First normalized stream event delivered.", attributes: [:]),
        "pi.ai.block": TelemetryEventDefinition(description: "A completed content block; content is never recorded.", attributes: [
            "type": .init(.string(values: ["text", "thinking", "tool_call"]), description: "Block kind.", required: true),
            "index": .init(.number(), description: "Content block index.", required: true),
            "chars": .init(.number(), description: "UTF-16 character count.", required: true),
            "tool": .init(.string(), description: "Tool name, for tool-call blocks only.", required: false),
        ]),
    ],
    status: TelemetryStatusDefinition(
        errorWhen: "Stop reason is error: provider_error with at most 500 error-message characters. Aborted stays ok.")
)
private func metricAttribute(_ attribute: TelemetryStartAttributeDefinition) -> TelemetryMetricAttributeDefinition {
    TelemetryMetricAttributeDefinition(attribute.kind, description: attribute.description, required: attribute.required)
}

/// Pi-owned request metadata, bounded error status, events, and low-cardinality metrics (upstream `AI_TELEMETRY_SCHEMA`).
///
/// `stream()` and `streamSimple()` record `pi.ai.request`, `streamDeferred()` one `pi.ai.poll` per poll, when the
/// request options carry a parent span (`telemetry`); their completion helpers record the same spans. A span covers the
/// provider setup and ends at the terminal result, whether or not the caller reads the events.
///
/// - Start attributes: `provider`, `api`, `model`, and `reasoning` when `SimpleStreamOptions.reasoning` is set.
/// - End attributes: `stop`, `usage.input`, `usage.output`, `usage.cache_read`, `usage.cache_write`, `cost.total`, and
///   `response.id` when present. `stop: "error"` sets the error status `provider_error` with
///   `AssistantMessage.errorMessage` cut to 500 characters (empty when absent); `aborted` keeps `ok`.
/// - `pi.ai.first_chunk` marks the first normalized event, a setup error included. Each completed text, thinking, or
///   tool-call block records `pi.ai.block` with `type`, `index`, and `chars` (UTF-16 code units; a tool call sums the
///   lengths of its argument deltas), and `tool` for tool calls.
/// - With `telemetry.metrics`: `pi.ai.request.duration` and `pi.ai.first_chunk.duration` (milliseconds on a monotonic
///   clock), `pi.ai.tokens` by `kind`, and `pi.ai.cost` in USD. A pending or deferred poll adds no tokens or cost.
///
/// Prompts, generated text, reasoning, and arguments are never recorded; the error status holds up to 500 characters
/// of provider error text.
public let aiTelemetrySchema = defineTelemetrySchema(TelemetrySchemaDefinition(
    version: 1,
    spans: [
        "pi.ai.request": request,
        "pi.ai.poll": TelemetrySpanDefinition(
            description: "One deferred-response poll, not the deferred request's lifetime.", parents: request.parents,
            startAttributes: request.startAttributes, endAttributes: request.endAttributes, events: request.events,
            status: request.status),
    ],
    metrics: [
        "pi.ai.request.duration": .histogram(description: "Logical request or poll duration.", unit: "ms", attributes: [
            "provider": metricAttribute(provider), "model": metricAttribute(model),
            "stop": .init(.string(values: stopValues), description: "Normalized stop reason.", required: true),
        ]),
        "pi.ai.first_chunk.duration": .histogram(description: "Time to the first normalized stream event.", unit: "ms", attributes: [
            "provider": metricAttribute(provider), "model": metricAttribute(model),
        ]),
        "pi.ai.tokens": .counter(description: "Reported model token usage; pending and deferred polls are excluded.",
                                 unit: "token", attributes: [
            "provider": metricAttribute(provider), "model": metricAttribute(model),
            "kind": .init(.string(values: ["input", "output", "cache_read", "cache_write"]),
                          description: "Token usage category.", required: true),
        ]),
        "pi.ai.cost": .counter(description: "Reported model cost; pending and deferred polls are excluded.", unit: "USD",
                               attributes: ["provider": metricAttribute(provider), "model": metricAttribute(model)]),
    ]
))

private struct RequestInstruments: Sendable {
    let requestDuration: any TelemetryHistogram
    let firstChunkDuration: any TelemetryHistogram
    let tokens: any TelemetryCounter
    let cost: any TelemetryCounter

    init(_ adapter: any TelemetryMetrics) {
        let metrics = createTypedMetrics(adapter, [aiTelemetrySchema])
        requestDuration = metrics.histogram("pi.ai.request.duration")
        firstChunkDuration = metrics.histogram("pi.ai.first_chunk.duration")
        tokens = metrics.counter("pi.ai.tokens")
        cost = metrics.counter("pi.ai.cost")
    }
}

/// The instruments of each metrics object, created once (upstream's WeakMap). The key is held weakly, so an entry goes
/// once its metrics object does; instruments that keep their metrics object alive keep the entry too.
private final class InstrumentCache: Sendable {
    private struct Entry { weak var metrics: (any TelemetryMetrics)?; let instruments: RequestInstruments }
    private let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    func instruments(_ metrics: any TelemetryMetrics) -> RequestInstruments {
        let key = ObjectIdentifier(metrics)
        if let found = entries.withLock({ $0[key] }), found.metrics === metrics { return found.instruments }
        // Created outside the lock: the factories are the adapter's code.
        let created = RequestInstruments(metrics)
        return entries.withLock { entries in
            if let found = entries[key], found.metrics === metrics { return found.instruments }
            entries = entries.filter { $0.value.metrics != nil }
            entries[key] = Entry(metrics: metrics, instruments: created)
            return created
        }
    }
}
private let instrumentCache = InstrumentCache()

/// Milliseconds on a monotonic clock, for durations (upstream `performance.now()`).
internal typealias MonotonicMilliseconds = @Sendable () -> Double
private let monotonicStart = ContinuousClock.now
internal let monotonicMilliseconds: MonotonicMilliseconds = {
    let elapsed = monotonicStart.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}

/// Synchronous, read-only observation of a forwarded stream (upstream `LazyStreamObserver`).
internal protocol RequestObservation: Sendable {
    func onEvent(_ event: AssistantMessageEvent)
    func onResult(_ message: AssistantMessage?)
}

/// Forwards `inner` to `outer` and observes each event after pushing it, then the terminal result once (upstream
/// `forwardStream`). An inner stream that ends without a terminal event gives its `result()`.
internal func forwardObserved(_ inner: AssistantMessageEventStream, to outer: AssistantMessageEventStream,
                              _ observer: some RequestObservation) async {
    var result: AssistantMessage?
    for await event in inner {
        outer.push(event)
        observer.onEvent(event)
        switch event {
        case .done(_, let message), .error(_, let message): result = message
        default: break
        }
    }
    if result == nil { result = await inner.result() }
    outer.end(result)
    observer.onResult(result)
}

/// Observation of one request's events and result inside its span (upstream `observeModelRequest`'s observer).
internal final class ModelRequestObserver: RequestObservation {
    private struct State {
        var first = true
        var toolChars: [Int: Int] = [:]
        var finished = false
    }
    private let span: any TelemetrySpan
    private let attributes: SpanAttributes
    private let poll: Bool
    private let started: Double
    private let now: MonotonicMilliseconds
    private let instruments: RequestInstruments
    private let state = Mutex(State())

    fileprivate init(span: any TelemetrySpan, attributes: SpanAttributes, poll: Bool, started: Double,
                     now: @escaping MonotonicMilliseconds, instruments: RequestInstruments) {
        self.span = span; self.attributes = attributes; self.poll = poll; self.started = started; self.now = now
        self.instruments = instruments
    }

    func onEvent(_ event: AssistantMessageEvent) {
        let first = state.withLock { state in defer { state.first = false }; return state.first }
        if first {
            span.addEvent("pi.ai.first_chunk")
            instruments.firstChunkDuration.record(now() - started, attributes: attributes, context: span)
        }
        switch event {
        case .toolCallDelta(let index, let delta, _):
            state.withLock { $0.toolChars[index, default: 0] += delta.utf16.count }
        case .textEnd(let index, let content, _):
            span.addEvent("pi.ai.block", attributes: [
                "type": "text", "index": .number(Double(index)), "chars": .number(Double(content.utf16.count)),
            ])
        case .thinkingEnd(let index, let content, _):
            span.addEvent("pi.ai.block", attributes: [
                "type": "thinking", "index": .number(Double(index)), "chars": .number(Double(content.utf16.count)),
            ])
        case .toolCallEnd(let index, let toolCall, _):
            let chars = state.withLock { $0.toolChars.removeValue(forKey: index) } ?? 0
            span.addEvent("pi.ai.block", attributes: [
                "type": "tool_call", "index": .number(Double(index)), "chars": .number(Double(chars)),
                "tool": .string(toolCall.name),
            ])
        default:
            break
        }
    }

    /// Records the terminal result once; the span ends after it.
    func onResult(_ message: AssistantMessage?) {
        guard state.withLock({ state in defer { state.finished = true }; return !state.finished }) else { return }
        guard let message else { return }
        let stop = message.stopReason.rawValue
        span.setAttributes([
            "stop": .string(stop),
            "usage.input": .number(Double(message.usage.input)),
            "usage.output": .number(Double(message.usage.output)),
            "usage.cache_read": .number(Double(message.usage.cacheRead)),
            "usage.cache_write": .number(Double(message.usage.cacheWrite)),
            "cost.total": .number(message.usage.cost.total),
            "response.id": message.responseId.map(AttributeValue.string),
        ])
        if message.stopReason == .error {
            span.setStatus(.error(name: "provider_error", message: utf16Prefix(message.errorMessage ?? "", 500)))
        }
        var withStop = attributes
        withStop["stop"] = .string(stop)
        instruments.requestDuration.record(now() - started, attributes: withStop, context: span)
        if !poll || (message.stopReason != .pending && message.stopReason != .deferred) {
            for (kind, value) in [("input", message.usage.input), ("output", message.usage.output),
                                  ("cache_read", message.usage.cacheRead), ("cache_write", message.usage.cacheWrite)] {
                var tagged = attributes
                tagged["kind"] = .string(kind)
                instruments.tokens.add(Double(value), attributes: tagged)
            }
            instruments.cost.add(message.usage.cost.total, attributes: attributes)
        }
    }
}

/// The first `limit` UTF-16 code units, as JavaScript's `slice(0, limit)`. A Swift string cannot hold half a surrogate
/// pair, so a pair cut in half drops its first half.
private func utf16Prefix(_ text: String, _ limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    var prefix = Array(text.utf16.prefix(limit))
    if let last = prefix.last, UTF16.isLeadSurrogate(last) { prefix.removeLast() }
    return String(decoding: prefix, as: UTF16.self)
}

/// Runs `body` with an observer inside a `pi.ai.request` or `pi.ai.poll` span under `telemetry`. `started` is when the
/// request began, on `now`.
nonisolated(nonsending) internal func observeModelRequest<T>(
    _ requestedModel: Model,
    telemetry: (any TelemetrySpan)?,
    reasoning: ThinkingLevel?,
    poll: Bool,
    started: Double,
    now: @escaping MonotonicMilliseconds = monotonicMilliseconds,
    _ body: (ModelRequestObserver) async -> T
) async -> T {
    let attributes: SpanAttributes = ["provider": .string(requestedModel.provider), "model": .string(requestedModel.id)]
    let instruments = instrumentCache.instruments(telemetry?.metrics ?? noopTelemetryMetrics)
    var startAttributes = attributes
    startAttributes["api"] = .string(requestedModel.api.rawValue)
    if let reasoning { startAttributes["reasoning"] = .string(reasoning.rawValue) }
    let start = createTypedSpanStarter(telemetry ?? noopTelemetryContext, [aiTelemetrySchema])
    return await start(poll ? "pi.ai.poll" : "pi.ai.request", startAttributes) { span, _ in
        await body(ModelRequestObserver(span: span, attributes: attributes, poll: poll, started: started, now: now,
                                        instruments: instruments))
    }
}

/// A request's setup failure as an assistant error message, as upstream `createSetupErrorMessage` builds it.
private func setupErrorMessage(_ model: Model, _ error: any Error) -> AssistantMessage {
    AssistantMessage(
        content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error, errorMessage: (error as? any LocalizedError)?.errorDescription ?? String(describing: error))
}

/// Dispatches a request and, with a parent span, forwards its events through an observed stream (upstream `lazyStream`
/// with an observer). Without one the provider's stream is returned unchanged. A setup failure still throws, as the
/// dispatch functions do; with a parent span it is recorded first as upstream records a setup error event.
internal func observedRequest(
    _ model: Model,
    telemetry: (any TelemetrySpan)?,
    reasoning: ThinkingLevel?,
    poll: Bool,
    _ setup: () throws -> AssistantMessageEventStream
) throws -> AssistantMessageEventStream {
    guard let telemetry else { return try setup() }
    let started = monotonicMilliseconds()
    let inner: AssistantMessageEventStream
    do {
        inner = try setup()
    } catch {
        let message = setupErrorMessage(model, error)
        Task {
            await observeModelRequest(model, telemetry: telemetry, reasoning: reasoning, poll: poll, started: started) { observer in
                observer.onEvent(.error(reason: .error, error: message))
                observer.onResult(message)
            }
        }
        throw error
    }
    let outer = AssistantMessageEventStream()
    Task {
        await observeModelRequest(model, telemetry: telemetry, reasoning: reasoning, poll: poll, started: started) { observer in
            await forwardObserved(inner, to: outer, observer)
        }
    }
    return outer
}
