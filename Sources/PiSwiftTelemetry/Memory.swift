// Ports upstream `packages/telemetry/src/memory.ts` at 482c1381a.

import Foundation
import Synchronization

/// A recorded event.
public struct RecordedTelemetryEvent: Sendable, Hashable {
    /// The event name.
    public var name: String
    /// The event attributes, without nil values.
    public var attributes: [String: AttributeValue]

    /// Creates a recorded event.
    public init(name: String, attributes: [String: AttributeValue] = [:]) {
        self.name = name
        self.attributes = attributes
    }
}

/// A normalized span snapshot.
public struct RecordedTelemetrySpan: Sendable, Hashable {
    /// The span ID, from 1 in start order.
    public var id: Int
    /// The parent span ID, or nil for a root span.
    public var parentId: Int?
    /// The span name.
    public var name: String
    /// The merged attributes, without nil values.
    public var attributes: [String: AttributeValue]
    /// The events in recording order.
    public var events: [RecordedTelemetryEvent]
    /// The explicit or automatic status. It is `ok` while the span is open.
    public var status: SpanStatus
    /// Whether the span's callback has finished.
    public var settled: Bool
    /// The position of the span in end order, from 1, once it is settled.
    public var endSequence: Int?

    /// Creates a span snapshot.
    public init(
        id: Int,
        parentId: Int?,
        name: String,
        attributes: [String: AttributeValue] = [:],
        events: [RecordedTelemetryEvent] = [],
        status: SpanStatus = .ok,
        settled: Bool,
        endSequence: Int? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.attributes = attributes
        self.events = events
        self.status = status
        self.settled = settled
        self.endSequence = endSequence
    }
}

private struct MutableRecordedTelemetrySpan {
    var span: RecordedTelemetrySpan
    var explicitStatus = false
}

private struct InMemoryTelemetryState {
    var spans: [MutableRecordedTelemetrySpan] = []
    var nextSpanId = 1
    var nextEndSequence = 1
}

/// The recording state that a context and all of its spans share.
private final class InMemoryTelemetryRecorder: Sendable {
    let state = Mutex(InMemoryTelemetryState())

    /// Appends a span, or returns nil when its parent is settled. Span IDs are positions plus one.
    func createSpan(parent: Int?, options: SpanOptions) -> Int? {
        let attributes = copyAttributes(options.attributes)
        return state.withLock { state in
            if let parent, state.spans[parent - 1].span.settled { return nil }
            let id = state.nextSpanId
            state.nextSpanId += 1
            state.spans.append(MutableRecordedTelemetrySpan(span: RecordedTelemetrySpan(
                id: id, parentId: parent, name: options.name, attributes: attributes, settled: false)))
            return id
        }
    }

    func settle(_ id: Int, error: (any Error)?) {
        guard let error else {
            state.withLock { state in Self.settle(&state, id, status: nil) }
            return
        }
        let explicit = state.withLock { state in state.spans[id - 1].explicitStatus }
        // The error's own description code runs outside the lock.
        let status = explicit ? nil : automaticErrorStatus(error)
        state.withLock { state in Self.settle(&state, id, status: status) }
    }

    private static func settle(_ state: inout InMemoryTelemetryState, _ id: Int, status: SpanStatus?) {
        guard !state.spans[id - 1].span.settled else { return }
        if let status, !state.spans[id - 1].explicitStatus { state.spans[id - 1].span.status = status }
        state.spans[id - 1].span.settled = true
        state.spans[id - 1].span.endSequence = state.nextEndSequence
        state.nextEndSequence += 1
    }

    /// Applies `change` to an open span. A settled span ignores it.
    func record(_ id: Int, _ change: (inout MutableRecordedTelemetrySpan) -> Void) {
        state.withLock { state in
            guard !state.spans[id - 1].span.settled else { return }
            change(&state.spans[id - 1])
        }
    }
}

private func copyAttributes(_ attributes: SpanAttributes?) -> [String: AttributeValue] {
    attributes?.compactMapValues { $0 } ?? [:]
}

/// Swift errors have no `name` or `message`, so the type name and description stand in for them.
private func automaticErrorStatus(_ error: any Error) -> SpanStatus {
    let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    return .error(name: String(describing: type(of: error)), message: message)
}

private final class InMemoryTelemetrySpan: TelemetrySpan {
    let recorder: InMemoryTelemetryRecorder
    let id: Int

    init(recorder: InMemoryTelemetryRecorder, id: Int) {
        self.recorder = recorder
        self.id = id
    }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await startInMemorySpan(recorder, parent: id, options, body)
    }

    func addEvent(_ name: String, attributes: SpanAttributes?) {
        let event = RecordedTelemetryEvent(name: name, attributes: copyAttributes(attributes))
        recorder.record(id) { $0.span.events.append(event) }
    }

    func setAttributes(_ attributes: SpanAttributes) {
        let attributes = copyAttributes(attributes)
        recorder.record(id) { $0.span.attributes.merge(attributes) { _, later in later } }
    }

    func setStatus(_ status: SpanStatus) {
        recorder.record(id) { span in
            span.span.status = status
            span.explicitStatus = true
        }
    }
}

nonisolated(nonsending) private func startInMemorySpan<T, E: Error>(
    _ recorder: InMemoryTelemetryRecorder,
    parent: Int?,
    _ options: SpanOptions,
    _ body: (any TelemetrySpan) async throws(E) -> T
) async throws(E) -> T {
    guard let id = recorder.createSpan(parent: parent, options: options) else {
        return try await noopTelemetryContext.startSpan(options, body)
    }
    do throws(E) {
        let value = try await body(InMemoryTelemetrySpan(recorder: recorder, id: id))
        recorder.settle(id, error: nil)
        return value
    } catch {
        recorder.settle(id, error: error)
        throw error
    }
}

/// Backend-neutral reference implementation that records spans in process memory.
/// Create a fresh instance to isolate tests or independent recording scopes.
///
/// Storage is unbounded and process-local. A thrown error records its type name and description
/// as the automatic error status, unless the callback set a status.
public final class InMemoryTelemetryContext: TelemetryContext {
    private let recorder = InMemoryTelemetryRecorder()

    /// Creates an empty recorder.
    public init() {}

    nonisolated(nonsending) public func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await startInMemorySpan(recorder, parent: nil, options, body)
    }

    /// Returns snapshots in span-start order.
    public func getSpans() -> [RecordedTelemetrySpan] {
        recorder.state.withLock { state in state.spans.map(\.span) }
    }
}
