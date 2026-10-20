// Ports upstream `packages/telemetry/src/noop.ts` at 482c1381a.

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

    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

/// Shared telemetry context used when an application does not provide one.
/// It runs callbacks in the caller's task and passes them one shared inert span, including for nested
/// spans. It does not inspect or retain names, attributes, events, or statuses.
public let noopTelemetryContext: any TelemetryContext = NoopTelemetrySpan.shared
