// Ports upstream `packages/telemetry/src/metrics.ts` at 48909d987.
// Upstream infers exact names, kinds, and attributes from schema data. Swift cannot, so only the data
// and the runtime behavior of `createTypedMetrics` are ported.

/// The description and unit of an instrument.
public struct InstrumentOptions: Sendable, Hashable {
    /// What the instrument measures.
    public var description: String?
    /// The unit of its values, such as `ms` or `By`.
    public var unit: String?

    /// Creates instrument options.
    public init(description: String? = nil, unit: String? = nil) {
        self.description = description
        self.unit = unit
    }
}

/// The description, unit, and bucket boundaries of a histogram.
public struct HistogramOptions: Sendable, Hashable {
    /// What the histogram measures.
    public var description: String?
    /// The unit of its values.
    public var unit: String?
    /// Bucket hints: finite and strictly increasing. Backends own aggregation and may translate them.
    public var boundaries: [Double]?

    /// Creates histogram options.
    public init(description: String? = nil, unit: String? = nil, boundaries: [Double]? = nil) {
        self.description = description
        self.unit = unit
        self.boundaries = boundaries
    }
}

/// A monotonic counter. It accepts non-negative finite increments.
public protocol TelemetryCounter: Sendable {
    /// Adds `value`.
    func add(_ value: Double, attributes: SpanAttributes?)
}

/// A counter that also decreases. It accepts finite signed values.
public protocol TelemetryUpDownCounter: Sendable {
    /// Adds `value`, which may be negative.
    func add(_ value: Double, attributes: SpanAttributes?)
}

/// A distribution of finite signed values.
public protocol TelemetryHistogram: Sendable {
    /// Records `value`. `context` optionally correlates the measurement with a span, as an exemplar.
    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?)
}

extension TelemetryCounter {
    /// Adds `value` without attributes.
    public func add(_ value: Double) { add(value, attributes: nil) }
}

extension TelemetryUpDownCounter {
    /// Adds `value` without attributes.
    public func add(_ value: Double) { add(value, attributes: nil) }
}

extension TelemetryHistogram {
    /// Records `value` without an exemplar context.
    public func record(_ value: Double, attributes: SpanAttributes? = nil) { record(value, attributes: attributes, context: nil) }
}

/// Optional adapter capability. Factories and recording methods are synchronous, passive, and do not throw;
/// an invalid measurement or invalid boundaries are ignored.
public protocol TelemetryMetrics: AnyObject, Sendable {
    /// Returns a counter named `name`.
    func counter(_ name: String, options: InstrumentOptions?) -> any TelemetryCounter
    /// Returns an up-down counter named `name`.
    func upDownCounter(_ name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter
    /// Returns a histogram named `name`.
    func histogram(_ name: String, options: HistogramOptions?) -> any TelemetryHistogram
}

extension TelemetryMetrics {
    /// Returns a counter without options.
    public func counter(_ name: String) -> any TelemetryCounter { counter(name, options: nil) }
    /// Returns an up-down counter without options.
    public func upDownCounter(_ name: String) -> any TelemetryUpDownCounter { upDownCounter(name, options: nil) }
    /// Returns a histogram without options.
    public func histogram(_ name: String) -> any TelemetryHistogram { histogram(name, options: nil) }
}

/// The cardinality a metric attribute may declare: only `low`. Omitting it does not waive the low-cardinality policy.
public enum TelemetryMetricCardinality: String, Sendable, Hashable, Codable {
    case low
}

/// A metric attribute definition: a start attribute definition whose cardinality can only be `low`.
public struct TelemetryMetricAttributeDefinition: Sendable, Hashable {
    /// The type, values, and examples.
    public var kind: TelemetryAttributeKind
    /// What the attribute records.
    public var description: String
    /// Whether every measurement must pass the attribute.
    public var required: Bool
    /// Whether the data needs special handling.
    public var sensitive: Bool?
    /// The expected cardinality.
    public var cardinality: TelemetryMetricCardinality?

    /// Creates a metric attribute definition.
    public init(
        _ kind: TelemetryAttributeKind,
        description: String,
        required: Bool,
        sensitive: Bool? = nil,
        cardinality: TelemetryMetricCardinality? = nil
    ) {
        self.kind = kind
        self.description = description
        self.required = required
        self.sensitive = sensitive
        self.cardinality = cardinality
    }

    /// The type name.
    public var type: TelemetryAttributeType { kind.type }
}

/// The kind of a metric instrument.
public enum TelemetryMetricKind: String, Sendable, Hashable, Codable {
    case counter
    case upDownCounter
    case histogram
}

/// Serializable instrument metadata: kind, description, unit, attributes, and, for histograms, boundaries.
public struct TelemetryMetricDefinition: Sendable, Hashable {
    /// The instrument kind.
    public let kind: TelemetryMetricKind
    /// What the instrument measures.
    public var description: String
    /// The unit of its values.
    public var unit: String?
    /// The measurement attributes.
    public var attributes: [String: TelemetryMetricAttributeDefinition]
    /// Bucket hints. Only histograms have them.
    public let boundaries: [Double]?

    private init(kind: TelemetryMetricKind, description: String, unit: String?,
                 attributes: [String: TelemetryMetricAttributeDefinition], boundaries: [Double]?) {
        self.kind = kind
        self.description = description
        self.unit = unit
        self.attributes = attributes
        self.boundaries = boundaries
    }

    /// A counter definition.
    public static func counter(description: String, unit: String? = nil,
                               attributes: [String: TelemetryMetricAttributeDefinition]) -> TelemetryMetricDefinition {
        TelemetryMetricDefinition(kind: .counter, description: description, unit: unit, attributes: attributes, boundaries: nil)
    }

    /// An up-down counter definition.
    public static func upDownCounter(description: String, unit: String? = nil,
                                     attributes: [String: TelemetryMetricAttributeDefinition]) -> TelemetryMetricDefinition {
        TelemetryMetricDefinition(kind: .upDownCounter, description: description, unit: unit, attributes: attributes,
                                  boundaries: nil)
    }

    /// A histogram definition.
    public static func histogram(description: String, unit: String? = nil, boundaries: [Double]? = nil,
                                 attributes: [String: TelemetryMetricAttributeDefinition]) -> TelemetryMetricDefinition {
        TelemetryMetricDefinition(kind: .histogram, description: description, unit: unit, attributes: attributes,
                                  boundaries: boundaries)
    }
}

/// Instruments bound to the metric names of one or more schemas. Each factory passes the schema's description, unit,
/// and boundaries to the adapter. Nothing checks the measurement attributes at run time.
public struct TypedTelemetryMetrics: Sendable {
    private let metrics: any TelemetryMetrics
    private let definitions: [String: TelemetryMetricDefinition]

    fileprivate init(_ metrics: any TelemetryMetrics, _ definitions: [String: TelemetryMetricDefinition]) {
        self.metrics = metrics
        self.definitions = definitions
    }

    /// The counter `name`.
    public func counter(_ name: String) -> any TelemetryCounter {
        metrics.counter(name, options: definitions[name].map(instrumentOptions))
    }

    /// The up-down counter `name`.
    public func upDownCounter(_ name: String) -> any TelemetryUpDownCounter {
        metrics.upDownCounter(name, options: definitions[name].map(instrumentOptions))
    }

    /// The histogram `name`.
    public func histogram(_ name: String) -> any TelemetryHistogram {
        metrics.histogram(name, options: definitions[name].map {
            HistogramOptions(description: $0.description, unit: $0.unit, boundaries: $0.boundaries)
        })
    }
}

private func instrumentOptions(_ definition: TelemetryMetricDefinition) -> InstrumentOptions {
    InstrumentOptions(description: definition.description, unit: definition.unit)
}

/// Binds instrument names, kinds, and metadata to one or more schemas. A later schema's definition of a name wins;
/// upstream rejects duplicate names at compile time.
public func createTypedMetrics(_ metrics: any TelemetryMetrics, _ schemas: [TelemetrySchemaDefinition]) -> TypedTelemetryMetrics {
    var definitions: [String: TelemetryMetricDefinition] = [:]
    for schema in schemas {
        for (name, definition) in schema.metrics ?? [:] { definitions[name] = definition }
    }
    return TypedTelemetryMetrics(metrics, definitions)
}

// MARK: - JSON in upstream's shape

private enum MetricAttributeKeys: String, CodingKey {
    case type, values, elementValues, examples, description, sensitive, cardinality, required
}

extension TelemetryMetricAttributeDefinition: Codable {
    /// Encodes the flat upstream shape: `type`, values, examples, `required`, and metadata.
    public func encode(to encoder: any Encoder) throws {
        // The attribute kind shares the start attribute coding.
        try TelemetryStartAttributeDefinition(kind, description: description, required: required, sensitive: sensitive,
                                              cardinality: cardinality.map { _ in .low }).encode(to: encoder)
    }

    /// Decodes the flat upstream shape. A `high` cardinality is invalid.
    public init(from decoder: any Decoder) throws {
        let start = try TelemetryStartAttributeDefinition(from: decoder)
        let container = try decoder.container(keyedBy: MetricAttributeKeys.self)
        self.init(start.kind, description: start.description, required: start.required, sensitive: start.sensitive,
                  cardinality: try container.decodeIfPresent(TelemetryMetricCardinality.self, forKey: .cardinality))
    }
}

extension TelemetryMetricDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, description, unit, attributes, boundaries
    }

    /// Encodes `{ kind, description, unit?, attributes, boundaries? }`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encode(attributes, forKey: .attributes)
        try container.encodeIfPresent(boundaries, forKey: .boundaries)
    }

    /// Decodes a definition. Boundaries on a counter are invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(TelemetryMetricKind.self, forKey: .kind)
        let boundaries = try container.decodeIfPresent([Double].self, forKey: .boundaries)
        if boundaries != nil && kind != .histogram {
            throw DecodingError.dataCorruptedError(
                forKey: .boundaries, in: container, debugDescription: "Only histograms declare boundaries")
        }
        self.init(kind: kind, description: try container.decode(String.self, forKey: .description),
                  unit: try container.decodeIfPresent(String.self, forKey: .unit),
                  attributes: try container.decode([String: TelemetryMetricAttributeDefinition].self, forKey: .attributes),
                  boundaries: boundaries)
    }
}
