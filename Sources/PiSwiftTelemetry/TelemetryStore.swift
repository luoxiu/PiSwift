// Ports the store half of upstream `packages/telemetry/src/index.ts` at d9025a5f5: `StoredSpan`, `StoredTrace`,
// `TraceQuery`, `MetricQuery`, `StoredMetric`, and `TelemetryStore`. The contract half is in `Telemetry.swift`.

/// A scalar a query compares attributes with: a string, number, or boolean. A number never equals a boolean.
public enum ScalarAttributeValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    /// Whether a stored attribute is this scalar: the same type and value, as upstream's `===`.
    package func matches(_ value: AttributeValue?) -> Bool {
        switch (self, value) {
        case let (.string(expected), .string(actual)?): expected == actual
        case let (.number(expected), .number(actual)?): expected == actual
        case let (.boolean(expected), .boolean(actual)?): expected == actual
        default: false
        }
    }
}

extension ScalarAttributeValue: ExpressibleByStringLiteral {
    /// A string value.
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ScalarAttributeValue: ExpressibleByIntegerLiteral {
    /// A number value.
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension ScalarAttributeValue: ExpressibleByFloatLiteral {
    /// A number value.
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension ScalarAttributeValue: ExpressibleByBooleanLiteral {
    /// A boolean value.
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

/// A settled span snapshot, independent of the recording adapter. Event times are relative to the span's start.
public struct StoredSpan: Sendable, Hashable {
    /// An event, at an offset from the span's start.
    public struct Event: Sendable, Hashable {
        /// The event name.
        public var name: String
        /// Milliseconds from the span's start.
        public var timeMs: Double
        /// The event attributes.
        public var attributes: [String: AttributeValue]

        /// Creates an event.
        public init(name: String, timeMs: Double, attributes: [String: AttributeValue] = [:]) {
            self.name = name
            self.timeMs = timeMs
            self.attributes = attributes
        }
    }

    /// A link: the target's trace and span IDs.
    public struct Link: Sendable, Hashable {
        /// The target's trace ID.
        public var traceId: String
        /// The target's span ID.
        public var spanId: String
        /// The link attributes, if the store has them.
        public var attributes: [String: AttributeValue]?

        /// Creates a link.
        public init(traceId: String, spanId: String, attributes: [String: AttributeValue]? = nil) {
            self.traceId = traceId
            self.spanId = spanId
            self.attributes = attributes
        }
    }

    /// The globally unique span ID.
    public var id: String
    /// The trace ID: the ID of the trace's root span, inherited through propagation.
    public var traceId: String
    /// The parent span's ID, local or remote, or nil for a root.
    public var parentId: String?
    /// The span name.
    public var name: String
    /// Wall-clock start, in milliseconds since the epoch.
    public var startedMs: Double
    /// Wall-clock end: the start plus the duration a monotonic clock measured.
    public var endedMs: Double
    /// The merged attributes.
    public var attributes: [String: AttributeValue]
    /// The events in recording order.
    public var events: [Event]
    /// The links in the order they were added.
    public var links: [Link]
    /// The final status.
    public var status: SpanStatus

    /// Creates a stored span.
    public init(
        id: String,
        traceId: String,
        parentId: String? = nil,
        name: String,
        startedMs: Double,
        endedMs: Double,
        attributes: [String: AttributeValue] = [:],
        events: [Event] = [],
        links: [Link] = [],
        status: SpanStatus = .ok
    ) {
        self.id = id
        self.traceId = traceId
        self.parentId = parentId
        self.name = name
        self.startedMs = startedMs
        self.endedMs = endedMs
        self.attributes = attributes
        self.events = events
        self.links = links
        self.status = status
    }
}

/// The locally stored spans of one trace, in start order.
public struct StoredTrace: Sendable, Hashable {
    /// The trace ID.
    public var traceId: String
    /// The spans, by start time and then span ID.
    public var spans: [StoredSpan]

    /// Creates a stored trace.
    public init(traceId: String, spans: [StoredSpan]) {
        self.traceId = traceId
        self.spans = spans
    }
}

/// Filters and paging for `TelemetryStore.findTraces`.
public struct TraceQuery: Sendable, Hashable {
    /// Name of the earliest stored span, with span ID breaking timestamp ties.
    public var name: String?
    /// All equalities must match one span; that span may be anywhere in the trace.
    public var attributes: [String: ScalarAttributeValue]?
    /// Only traces with a span whose status is `error`. Upstream's `errors?: true`; `false` does not filter.
    public var errors: Bool
    /// Inclusive lower bound on the earliest stored span's start time.
    public var startMin: Double?
    /// Inclusive upper bound on the earliest stored span's start time.
    public var startMax: Double?
    /// Positive page size; defaults to 20.
    public var limit: Int?
    /// Opaque continuation from the previous page; retain the same filters.
    public var cursor: String?

    /// Creates a query. Every filter is optional.
    public init(
        name: String? = nil,
        attributes: [String: ScalarAttributeValue]? = nil,
        errors: Bool = false,
        startMin: Double? = nil,
        startMax: Double? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.name = name
        self.attributes = attributes
        self.errors = errors
        self.startMin = startMin
        self.startMax = startMax
        self.limit = limit
        self.cursor = cursor
    }
}

/// One page of `TelemetryStore.findTraces`: the traces, newest first, and a cursor while more match.
public struct StoredTracePage: Sendable, Hashable {
    /// The traces, newest trace start first.
    public var traces: [StoredTrace]
    /// The continuation for the next page, or nil on the last one.
    public var cursor: String?

    /// Creates a page.
    public init(traces: [StoredTrace], cursor: String? = nil) {
        self.traces = traces
        self.cursor = cursor
    }
}

/// Filters for `TelemetryStore.findMetrics`.
public struct MetricQuery: Sendable, Hashable {
    /// The instrument name.
    public var name: String
    /// Inclusive lower bound on the interval start time.
    public var startMin: Double?
    /// Inclusive upper bound on the interval start time.
    public var startMax: Double?
    /// Equalities every returned row's attributes match.
    public var attributes: [String: ScalarAttributeValue]?

    /// Creates a query for the instrument `name`.
    public init(
        name: String,
        startMin: Double? = nil,
        startMax: Double? = nil,
        attributes: [String: ScalarAttributeValue]? = nil
    ) {
        self.name = name
        self.startMin = startMin
        self.startMax = startMax
        self.attributes = attributes
    }
}

/// A metric interval row: count, sum, minimum, and maximum of one series' measurements.
public struct StoredMetric: Sendable, Hashable {
    /// The interval start, in milliseconds since the epoch.
    public var intervalMs: Double
    /// The instrument name.
    public var name: String
    /// The instrument kind.
    public var kind: TelemetryMetricKind
    /// The instrument unit.
    public var unit: String?
    /// The measurement attributes.
    public var attributes: [String: AttributeValue]
    /// The number of measurements.
    public var count: Int
    /// The sum of the measurements.
    public var sum: Double
    /// The smallest measurement.
    public var min: Double
    /// The largest measurement.
    public var max: Double

    /// Creates a metric row.
    public init(
        intervalMs: Double,
        name: String,
        kind: TelemetryMetricKind,
        unit: String? = nil,
        attributes: [String: AttributeValue] = [:],
        count: Int,
        sum: Double,
        min: Double,
        max: Double
    ) {
        self.intervalMs = intervalMs
        self.name = name
        self.kind = kind
        self.unit = unit
        self.attributes = attributes
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max
    }
}

/// Reads settled traces without depending on a storage backend.
public protocol TelemetryStore: Sendable {
    /// Returns complete locally stored traces that match `query`, newest trace start first.
    func findTraces(_ query: TraceQuery) async throws -> StoredTracePage
    /// Returns the trace, or nil when no span of it is stored.
    func getTrace(_ traceId: String) async throws -> StoredTrace?
    /// Returns the metric rows that match `query`.
    func findMetrics(_ query: MetricQuery) async throws -> [StoredMetric]
}

extension TelemetryStore {
    /// Returns the newest 20 traces.
    public func findTraces() async throws -> StoredTracePage {
        try await findTraces(TraceQuery())
    }
}
