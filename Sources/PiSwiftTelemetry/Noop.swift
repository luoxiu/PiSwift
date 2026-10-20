// Ports upstream `packages/telemetry/src/noop.ts` at 48909d987.

/// The one inert span. It is its own child for nested spans.
internal final class NoopTelemetrySpan: TelemetrySpan {
    static let shared = NoopTelemetrySpan()

    private init() {}

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await body(self)
    }

    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

/// Shared telemetry context used when an application does not provide one.
/// It runs callbacks in the caller's task and passes them one shared inert span, including for nested
/// spans. It does not inspect or retain names, attributes, links, events, or statuses.
public let noopTelemetryContext: any TelemetryContext = NoopTelemetrySpan.shared

private final class NoopTelemetryPropagation: TelemetryPropagation {
    static let shared = NoopTelemetryPropagation()
    private init() {}
    func inject(_ context: any TelemetryContext) -> TelemetryCarrier? { nil }
    func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext { noopTelemetryContext }
}

/// Shared propagation that neither inspects nor retains its inputs: injection returns nil, extraction returns
/// `noopTelemetryContext`.
public let noopTelemetryPropagation: any TelemetryPropagation = NoopTelemetryPropagation.shared

private final class NoopInstrument: TelemetryCounter, TelemetryUpDownCounter, TelemetryHistogram {
    static let counter = NoopInstrument()
    static let upDownCounter = NoopInstrument()
    static let histogram = NoopInstrument()
    private init() {}
    func add(_ value: Double, attributes: SpanAttributes?) {}
    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?) {}
}

private final class NoopTelemetryMetrics: TelemetryMetrics {
    static let shared = NoopTelemetryMetrics()
    private init() {}
    func counter(_ name: String, options: InstrumentOptions?) -> any TelemetryCounter { NoopInstrument.counter }
    func upDownCounter(_ name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter { NoopInstrument.upDownCounter }
    func histogram(_ name: String, options: HistogramOptions?) -> any TelemetryHistogram { NoopInstrument.histogram }
}

/// Shared instruments that never inspect or retain metadata, measurements, or contexts. Each factory returns one
/// shared instrument for every name.
public let noopTelemetryMetrics: any TelemetryMetrics = NoopTelemetryMetrics.shared
