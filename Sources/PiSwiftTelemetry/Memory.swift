// Ports upstream `packages/telemetry/src/memory.ts` at 48909d987.

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

/// A recorded link: the target's carrier and the link attributes.
public struct RecordedTelemetryLink: Sendable, Hashable {
    /// The target's carrier.
    public var context: TelemetryCarrier
    /// The link attributes, without nil values.
    public var attributes: [String: AttributeValue]

    /// Creates a recorded link.
    public init(context: TelemetryCarrier, attributes: [String: AttributeValue] = [:]) {
        self.context = context
        self.attributes = attributes
    }
}

/// A normalized span snapshot.
public struct RecordedTelemetrySpan: Sendable, Hashable {
    /// The span ID, from 1 in start order.
    public var id: Int
    /// The local parent span ID, or nil for a root and for a parent another recorder owns.
    public var parentId: Int?
    /// The span's own carrier.
    public var context: TelemetryCarrier
    /// The parent's carrier, local or remote, or nil for a root.
    public var parentContext: TelemetryCarrier?
    /// The links in the order they were added.
    public var links: [RecordedTelemetryLink]
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
        context: TelemetryCarrier,
        parentContext: TelemetryCarrier? = nil,
        links: [RecordedTelemetryLink] = [],
        name: String,
        attributes: [String: AttributeValue] = [:],
        events: [RecordedTelemetryEvent] = [],
        status: SpanStatus = .ok,
        settled: Bool,
        endSequence: Int? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.context = context
        self.parentContext = parentContext
        self.links = links
        self.name = name
        self.attributes = attributes
        self.events = events
        self.status = status
        self.settled = settled
        self.endSequence = endSequence
    }
}

/// A recorded measurement, with its instrument's metadata and an optional exemplar context.
public struct RecordedTelemetryMeasurement: Sendable, Hashable {
    /// The instrument kind.
    public enum Kind: String, Sendable, Hashable {
        case counter
        case upDownCounter
        case histogram
    }

    /// The instrument kind.
    public var kind: Kind
    /// The instrument name.
    public var name: String
    /// The instrument description.
    public var description: String?
    /// The instrument unit.
    public var unit: String?
    /// The histogram's boundaries.
    public var boundaries: [Double]?
    /// The measured value.
    public var value: Double
    /// The measurement attributes, without nil values.
    public var attributes: [String: AttributeValue]
    /// The carrier of the exemplar span, or nil.
    public var context: TelemetryCarrier?

    /// Creates a measurement snapshot.
    public init(
        kind: Kind,
        name: String,
        description: String? = nil,
        unit: String? = nil,
        boundaries: [Double]? = nil,
        value: Double,
        attributes: [String: AttributeValue] = [:],
        context: TelemetryCarrier? = nil
    ) {
        self.kind = kind
        self.name = name
        self.description = description
        self.unit = unit
        self.boundaries = boundaries
        self.value = value
        self.attributes = attributes
        self.context = context
    }
}

/// A context with an in-memory carrier: a span or an extracted parent of any in-memory recorder. Identity survives
/// settlement without exposing backend IDs on the generic contract. Upstream keeps these carriers in a module-level
/// WeakMap.
private protocol InMemoryCarrierContext: TelemetryContext {
    var carrier: TelemetryCarrier { get }
}

private func carrier(of context: any TelemetryContext) -> TelemetryCarrier? {
    (context as? any InMemoryCarrierContext)?.carrier
}

private struct MutableRecordedTelemetrySpan {
    var span: RecordedTelemetrySpan
    var explicitStatus = false
}

/// Where a new span belongs: the parent's carrier, its local ID if this recorder owns it, and, for a parent span (not
/// an extracted parent), the span whose settlement makes children inert.
private struct InMemoryParent {
    let context: TelemetryCarrier
    let localId: Int?
    let span: Int?
}

private struct InMemoryTelemetryState {
    var spans: [MutableRecordedTelemetrySpan] = []
    var measurements: [RecordedTelemetryMeasurement] = []
    var nextSpanId = 1
    var nextEndSequence = 1
}

/// The recording state that a context and all of its spans share.
private final class InMemoryTelemetryRecorder: Sendable {
    let scope = UUID().uuidString.lowercased()
    let state = Mutex(InMemoryTelemetryState())

    /// Appends a span, or returns nil when its parent span is settled. Span IDs are positions plus one.
    func createSpan(parent: InMemoryParent?, options: SpanOptions) -> (id: Int, carrier: TelemetryCarrier)? {
        let attributes = copyAttributes(options.attributes)
        let links = (options.links ?? []).compactMap(copyLink)
        return state.withLock { state in
            if let parent = parent?.span, state.spans[parent - 1].span.settled { return nil }
            let id = state.nextSpanId
            state.nextSpanId += 1
            let context = ["pi-memory-scope": scope, "pi-memory-span": String(id)]
            state.spans.append(MutableRecordedTelemetrySpan(span: RecordedTelemetrySpan(
                id: id, parentId: parent?.localId, context: context, parentContext: parent?.context, links: links,
                name: options.name, attributes: attributes, settled: false)))
            return (id, context)
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

/// A link to a context without an in-memory carrier, such as a root or the no-op span, is ignored.
private func copyLink(_ link: SpanLink) -> RecordedTelemetryLink? {
    guard let context = carrier(of: link.context) else { return nil }
    return RecordedTelemetryLink(context: context, attributes: copyAttributes(link.attributes))
}

/// Swift errors have no `name` or `message`, so the type name and description stand in for them.
private func automaticErrorStatus(_ error: any Error) -> SpanStatus {
    let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    return .error(name: String(describing: type(of: error)), message: message)
}

private final class InMemoryTelemetrySpan: TelemetrySpan, InMemoryCarrierContext {
    let recorder: InMemoryTelemetryRecorder
    let id: Int
    let carrier: TelemetryCarrier

    init(recorder: InMemoryTelemetryRecorder, id: Int, carrier: TelemetryCarrier) {
        self.recorder = recorder
        self.id = id
        self.carrier = carrier
    }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await startInMemorySpan(recorder, parent: InMemoryParent(context: carrier, localId: id, span: id), options, body)
    }

    func addLink(_ link: SpanLink) {
        guard let link = copyLink(link) else { return }
        recorder.record(id) { $0.span.links.append(link) }
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

/// A parent extracted from a carrier. Children record it as their parent context; it never becomes inert.
private final class InMemoryExtractedParent: InMemoryCarrierContext {
    let recorder: InMemoryTelemetryRecorder
    let carrier: TelemetryCarrier
    let localId: Int?

    init(recorder: InMemoryTelemetryRecorder, carrier: TelemetryCarrier, localId: Int?) {
        self.recorder = recorder
        self.carrier = carrier
        self.localId = localId
    }

    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await startInMemorySpan(recorder, parent: InMemoryParent(context: carrier, localId: localId, span: nil), options, body)
    }
}

nonisolated(nonsending) private func startInMemorySpan<T, E: Error>(
    _ recorder: InMemoryTelemetryRecorder,
    parent: InMemoryParent?,
    _ options: SpanOptions,
    _ body: (any TelemetrySpan) async throws(E) -> T
) async throws(E) -> T {
    guard let created = recorder.createSpan(parent: parent, options: options) else {
        return try await noopTelemetryContext.startSpan(options, body)
    }
    let id = created.id
    do throws(E) {
        let value = try await body(InMemoryTelemetrySpan(recorder: recorder, id: id, carrier: created.carrier))
        recorder.settle(id, error: nil)
        return value
    } catch {
        recorder.settle(id, error: error)
        throw error
    }
}

/// The instrument metadata, or nil for an instrument whose boundaries are invalid, which records nothing.
private struct InMemoryInstrumentMetadata: Sendable {
    let kind: RecordedTelemetryMeasurement.Kind
    let name: String
    let description: String?
    let unit: String?
    let boundaries: [Double]?
}

private final class InMemoryInstrument: TelemetryCounter, TelemetryUpDownCounter, TelemetryHistogram {
    let recorder: InMemoryTelemetryRecorder
    let metadata: InMemoryInstrumentMetadata?

    init(_ recorder: InMemoryTelemetryRecorder, _ metadata: InMemoryInstrumentMetadata?) {
        self.recorder = recorder
        self.metadata = metadata
    }

    func add(_ value: Double, attributes: SpanAttributes?) {
        record(value, attributes: attributes, context: nil)
    }

    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?) {
        guard let metadata, value.isFinite, metadata.kind != .counter || value >= 0 else { return }
        let measurement = RecordedTelemetryMeasurement(
            kind: metadata.kind, name: metadata.name, description: metadata.description, unit: metadata.unit,
            boundaries: metadata.boundaries, value: value, attributes: copyAttributes(attributes),
            context: context.flatMap(carrier(of:)))
        recorder.state.withLock { $0.measurements.append(measurement) }
    }
}

/// A UUID in `crypto.randomUUID()`'s lowercase form.
private func isMemoryScope(_ value: String) -> Bool {
    let characters = Array(value.utf8)
    guard characters.count == 36 else { return false }
    for (index, character) in characters.enumerated() {
        if [8, 13, 18, 23].contains(index) {
            if character != UInt8(ascii: "-") { return false }
        } else if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(character)
                    && !(UInt8(ascii: "a")...UInt8(ascii: "f")).contains(character) {
            return false
        }
    }
    return true
}

/// A positive decimal integer without leading zeros that a JavaScript number holds exactly.
private func memorySpanId(_ value: String) -> Int? {
    let characters = Array(value.utf8)
    guard let first = characters.first, first != UInt8(ascii: "0"),
          characters.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
          let id = Int(value), id <= 9_007_199_254_740_991 else { return nil }
    return id
}

/// Backend-neutral reference implementation that records spans and measurements in process memory.
/// Create a fresh instance to isolate tests or independent recording scopes.
///
/// It is also the adapter's propagation and metrics. Storage is unbounded and process-local. A thrown error
/// records its type name and description as the automatic error status, unless the callback set a status.
public final class InMemoryTelemetryContext: TelemetryContext, TelemetryPropagation, TelemetryMetrics {
    private let recorder = InMemoryTelemetryRecorder()

    /// Creates an empty recorder.
    public init() {}

    nonisolated(nonsending) public func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T {
        try await startInMemorySpan(recorder, parent: nil, options, body)
    }

    /// Returns a detached carrier for a known span or extracted parent, including settled spans.
    public func inject(_ context: any TelemetryContext) -> TelemetryCarrier? {
        carrier(of: context)
    }

    /// Returns a parent for an in-memory carrier, from this recorder or another one. An absent or unrecognized
    /// carrier falls back to this recorder's root.
    public func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext {
        guard let carrier, let scope = carrier["pi-memory-scope"], let span = carrier["pi-memory-span"],
              isMemoryScope(scope), let id = memorySpanId(span) else { return self }
        let context = ["pi-memory-scope": scope, "pi-memory-span": span]
        let local = scope == recorder.scope && recorder.state.withLock { id <= $0.spans.count }
        return InMemoryExtractedParent(recorder: recorder, carrier: context, localId: local ? id : nil)
    }

    public func counter(_ name: String, options: InstrumentOptions?) -> any TelemetryCounter {
        instrument(.counter, name, description: options?.description, unit: options?.unit, boundaries: nil)
    }

    public func upDownCounter(_ name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter {
        instrument(.upDownCounter, name, description: options?.description, unit: options?.unit, boundaries: nil)
    }

    public func histogram(_ name: String, options: HistogramOptions?) -> any TelemetryHistogram {
        instrument(.histogram, name, description: options?.description, unit: options?.unit, boundaries: options?.boundaries)
    }

    private func instrument(_ kind: RecordedTelemetryMeasurement.Kind, _ name: String, description: String?, unit: String?,
                            boundaries: [Double]?) -> InMemoryInstrument {
        if let boundaries, boundaries.indices.contains(where: {
            !boundaries[$0].isFinite || ($0 > 0 && boundaries[$0] <= boundaries[$0 - 1])
        }) {
            return InMemoryInstrument(recorder, nil)
        }
        return InMemoryInstrument(recorder, InMemoryInstrumentMetadata(
            kind: kind, name: name, description: description, unit: unit, boundaries: boundaries))
    }

    /// Returns the measurements in recording order, without aggregation.
    public func getMetrics() -> [RecordedTelemetryMeasurement] {
        recorder.state.withLock { $0.measurements }
    }

    /// Returns snapshots in span-start order.
    public func getSpans() -> [RecordedTelemetrySpan] {
        recorder.state.withLock { state in state.spans.map(\.span) }
    }
}
