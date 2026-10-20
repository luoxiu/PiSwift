// Ports the schema half of upstream `packages/telemetry/src/index.ts` at 482c1381a.
// Upstream infers exact TypeScript types from schema data. Swift cannot, so only the data
// and the runtime behavior of the typed starter are ported.

/// A supported attribute type name.
public enum TelemetryAttributeType: String, Sendable, Hashable, Codable, CaseIterable {
    case string
    case number
    case boolean
    case stringArray = "string[]"
    case numberArray = "number[]"
    case booleanArray = "boolean[]"
}

/// The expected cardinality of an attribute.
public enum TelemetryCardinality: String, Sendable, Hashable, Codable {
    case low
    case high
}

/// Description, sensitivity, and cardinality metadata.
public struct TelemetryAttributeMetadata: Sendable, Hashable, Codable {
    /// What the attribute records.
    public var description: String
    /// Whether the data needs special handling.
    public var sensitive: Bool?
    /// The expected cardinality.
    public var cardinality: TelemetryCardinality?

    /// Creates attribute metadata.
    public init(description: String, sensitive: Bool? = nil, cardinality: TelemetryCardinality? = nil) {
        self.description = description
        self.sensitive = sensitive
        self.cardinality = cardinality
    }
}

/// An attribute type with its closed set of values and its examples.
/// Scalars have `values`; arrays have `elementValues`.
public enum TelemetryAttributeKind: Sendable, Hashable {
    case string(values: [String]? = nil, examples: [String]? = nil)
    case number(values: [Double]? = nil, examples: [Double]? = nil)
    case boolean(values: [Bool]? = nil, examples: [Bool]? = nil)
    case stringArray(elementValues: [String]? = nil, examples: [[String]]? = nil)
    case numberArray(elementValues: [Double]? = nil, examples: [[Double]]? = nil)
    case booleanArray(elementValues: [Bool]? = nil, examples: [[Bool]]? = nil)

    /// The type name.
    public var type: TelemetryAttributeType {
        switch self {
        case .string: .string
        case .number: .number
        case .boolean: .boolean
        case .stringArray: .stringArray
        case .numberArray: .numberArray
        case .booleanArray: .booleanArray
        }
    }
}

/// An attribute type, allowed values, examples, and metadata. End attributes use it.
public struct TelemetryAttributeDefinition: Sendable, Hashable {
    /// The type, values, and examples.
    public var kind: TelemetryAttributeKind
    /// What the attribute records.
    public var description: String
    /// Whether the data needs special handling.
    public var sensitive: Bool?
    /// The expected cardinality.
    public var cardinality: TelemetryCardinality?

    /// Creates an attribute definition.
    public init(
        _ kind: TelemetryAttributeKind,
        description: String,
        sensitive: Bool? = nil,
        cardinality: TelemetryCardinality? = nil
    ) {
        self.kind = kind
        self.description = description
        self.sensitive = sensitive
        self.cardinality = cardinality
    }

    /// The type name.
    public var type: TelemetryAttributeType { kind.type }
    /// The description, sensitivity, and cardinality.
    public var metadata: TelemetryAttributeMetadata {
        TelemetryAttributeMetadata(description: description, sensitive: sensitive, cardinality: cardinality)
    }
}

/// A start or event attribute definition, which always states whether it is required.
public struct TelemetryStartAttributeDefinition: Sendable, Hashable {
    /// The type, values, and examples.
    public var kind: TelemetryAttributeKind
    /// What the attribute records.
    public var description: String
    /// Whether every call must pass the attribute.
    public var required: Bool
    /// Whether the data needs special handling.
    public var sensitive: Bool?
    /// The expected cardinality.
    public var cardinality: TelemetryCardinality?

    /// Creates a start or event attribute definition.
    public init(
        _ kind: TelemetryAttributeKind,
        description: String,
        required: Bool,
        sensitive: Bool? = nil,
        cardinality: TelemetryCardinality? = nil
    ) {
        self.kind = kind
        self.description = description
        self.required = required
        self.sensitive = sensitive
        self.cardinality = cardinality
    }

    /// The type name.
    public var type: TelemetryAttributeType { kind.type }
    /// The description, sensitivity, and cardinality.
    public var metadata: TelemetryAttributeMetadata {
        TelemetryAttributeMetadata(description: description, sensitive: sensitive, cardinality: cardinality)
    }
}

/// An event attribute definition. It has the same shape as a start attribute definition.
public typealias TelemetryEventAttributeDefinition = TelemetryStartAttributeDefinition

/// An event description and its attribute definitions.
public struct TelemetryEventDefinition: Sendable, Hashable, Codable {
    /// What the event records.
    public var description: String
    /// The event attributes.
    public var attributes: [String: TelemetryEventAttributeDefinition]

    /// Creates an event definition.
    public init(description: String, attributes: [String: TelemetryEventAttributeDefinition]) {
        self.description = description
        self.attributes = attributes
    }
}

/// Which spans may be the parent. The rule is descriptive; nothing enforces it.
public enum TelemetryParentDefinition: Sendable, Hashable {
    /// A root or any caller span.
    case any
    /// A root or a caller-owned span outside the schema.
    case rootOrExternal
    /// Only the listed schema spans.
    case spans([String])
}

/// The status rule of a span: `ok` by default, and when it is an error.
public struct TelemetryStatusDefinition: Sendable, Hashable, Codable {
    /// The default status, which is always `ok`.
    public enum Default: String, Sendable, Hashable, Codable {
        case ok
    }

    /// The default status.
    public var `default`: Default
    /// When the span ends with an error.
    public var errorWhen: String

    /// Creates a status rule.
    public init(default: Default = .ok, errorWhen: String) {
        self.default = `default`
        self.errorWhen = errorWhen
    }
}

/// Span metadata, parents, attributes, events, and status rule.
public struct TelemetrySpanDefinition: Sendable, Hashable, Codable {
    /// What the span records.
    public var description: String
    /// Which spans may be the parent.
    public var parents: TelemetryParentDefinition
    /// Attributes passed when the span starts.
    public var startAttributes: [String: TelemetryStartAttributeDefinition]
    /// Optional attributes set while the span runs.
    public var endAttributes: [String: TelemetryAttributeDefinition]
    /// The events the span may record.
    public var events: [String: TelemetryEventDefinition]?
    /// The status rule.
    public var status: TelemetryStatusDefinition

    /// Creates a span definition.
    public init(
        description: String,
        parents: TelemetryParentDefinition,
        startAttributes: [String: TelemetryStartAttributeDefinition],
        endAttributes: [String: TelemetryAttributeDefinition],
        events: [String: TelemetryEventDefinition]? = nil,
        status: TelemetryStatusDefinition
    ) {
        self.description = description
        self.parents = parents
        self.startAttributes = startAttributes
        self.endAttributes = endAttributes
        self.events = events
        self.status = status
    }
}

/// A versioned set of span definitions.
public struct TelemetrySchemaDefinition: Sendable, Hashable, Codable {
    /// The schema version.
    public var version: Int
    /// The spans, by name.
    public var spans: [String: TelemetrySpanDefinition]

    /// Creates a schema.
    public init(version: Int, spans: [String: TelemetrySpanDefinition]) {
        self.version = version
        self.spans = spans
    }
}

/// Identity helper for serializable telemetry schema data.
public func defineTelemetrySchema(_ schema: TelemetrySchemaDefinition) -> TelemetrySchemaDefinition {
    schema
}

/// Starts spans of one or more schemas under one explicit parent context.
/// Each callback receives a starter bound to its own span for child spans.
public struct TypedSpanStarter: Sendable {
    private let telemetryContext: any TelemetryContext

    fileprivate init(_ telemetryContext: any TelemetryContext) {
        self.telemetryContext = telemetryContext
    }

    /// Runs `body` in a child span named `name` with the start attributes.
    nonisolated(nonsending) public func callAsFunction<T, E: Error>(
        _ name: String,
        _ attributes: SpanAttributes,
        _ body: (any TelemetrySpan, TypedSpanStarter) async throws(E) -> T
    ) async throws(E) -> T {
        try await telemetryContext.startSpan(SpanOptions(name: name, attributes: attributes)) {
            (span) async throws(E) -> T in
            try await body(span, TypedSpanStarter(span))
        }
    }
}

/// Binds an explicit parent context to the span vocabulary of one or more schemas.
/// The schemas are not validated, merged, or retained.
public func createTypedSpanStarter(
    _ telemetryContext: any TelemetryContext,
    _ schemas: [TelemetrySchemaDefinition]
) -> TypedSpanStarter {
    TypedSpanStarter(telemetryContext)
}

// MARK: - JSON in upstream's shape

private enum AttributeDefinitionKeys: String, CodingKey {
    case type, values, elementValues, examples, description, sensitive, cardinality, required
}

extension TelemetryAttributeKind {
    fileprivate func encode(to container: inout KeyedEncodingContainer<AttributeDefinitionKeys>) throws {
        try container.encode(type, forKey: .type)
        switch self {
        case .string(let values, let examples):
            try container.encodeIfPresent(values, forKey: .values)
            try container.encodeIfPresent(examples, forKey: .examples)
        case .number(let values, let examples):
            try container.encodeIfPresent(values, forKey: .values)
            try container.encodeIfPresent(examples, forKey: .examples)
        case .boolean(let values, let examples):
            try container.encodeIfPresent(values, forKey: .values)
            try container.encodeIfPresent(examples, forKey: .examples)
        case .stringArray(let values, let examples):
            try container.encodeIfPresent(values, forKey: .elementValues)
            try container.encodeIfPresent(examples, forKey: .examples)
        case .numberArray(let values, let examples):
            try container.encodeIfPresent(values, forKey: .elementValues)
            try container.encodeIfPresent(examples, forKey: .examples)
        case .booleanArray(let values, let examples):
            try container.encodeIfPresent(values, forKey: .elementValues)
            try container.encodeIfPresent(examples, forKey: .examples)
        }
    }

    fileprivate init(from container: KeyedDecodingContainer<AttributeDefinitionKeys>) throws {
        switch try container.decode(TelemetryAttributeType.self, forKey: .type) {
        case .string:
            self = .string(values: try container.decodeIfPresent([String].self, forKey: .values),
                           examples: try container.decodeIfPresent([String].self, forKey: .examples))
        case .number:
            self = .number(values: try container.decodeIfPresent([Double].self, forKey: .values),
                           examples: try container.decodeIfPresent([Double].self, forKey: .examples))
        case .boolean:
            self = .boolean(values: try container.decodeIfPresent([Bool].self, forKey: .values),
                            examples: try container.decodeIfPresent([Bool].self, forKey: .examples))
        case .stringArray:
            self = .stringArray(elementValues: try container.decodeIfPresent([String].self, forKey: .elementValues),
                                examples: try container.decodeIfPresent([[String]].self, forKey: .examples))
        case .numberArray:
            self = .numberArray(elementValues: try container.decodeIfPresent([Double].self, forKey: .elementValues),
                                examples: try container.decodeIfPresent([[Double]].self, forKey: .examples))
        case .booleanArray:
            self = .booleanArray(elementValues: try container.decodeIfPresent([Bool].self, forKey: .elementValues),
                                 examples: try container.decodeIfPresent([[Bool]].self, forKey: .examples))
        }
    }
}

extension TelemetryAttributeDefinition: Codable {
    /// Encodes the flat upstream shape: `type`, values, examples, and metadata.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AttributeDefinitionKeys.self)
        try kind.encode(to: &container)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(sensitive, forKey: .sensitive)
        try container.encodeIfPresent(cardinality, forKey: .cardinality)
    }

    /// Decodes the flat upstream shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AttributeDefinitionKeys.self)
        self.init(try TelemetryAttributeKind(from: container),
                  description: try container.decode(String.self, forKey: .description),
                  sensitive: try container.decodeIfPresent(Bool.self, forKey: .sensitive),
                  cardinality: try container.decodeIfPresent(TelemetryCardinality.self, forKey: .cardinality))
    }
}

extension TelemetryStartAttributeDefinition: Codable {
    /// Encodes the flat upstream shape: `type`, values, examples, `required`, and metadata.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AttributeDefinitionKeys.self)
        try kind.encode(to: &container)
        try container.encode(required, forKey: .required)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(sensitive, forKey: .sensitive)
        try container.encodeIfPresent(cardinality, forKey: .cardinality)
    }

    /// Decodes the flat upstream shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AttributeDefinitionKeys.self)
        self.init(try TelemetryAttributeKind(from: container),
                  description: try container.decode(String.self, forKey: .description),
                  required: try container.decode(Bool.self, forKey: .required),
                  sensitive: try container.decodeIfPresent(Bool.self, forKey: .sensitive),
                  cardinality: try container.decodeIfPresent(TelemetryCardinality.self, forKey: .cardinality))
    }
}

extension TelemetryParentDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, spans
    }

    /// Encodes `{ kind: "any" }`, `{ kind: "root_or_external" }`, or `{ kind: "spans", spans }`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try container.encode("any", forKey: .kind)
        case .rootOrExternal:
            try container.encode("root_or_external", forKey: .kind)
        case .spans(let spans):
            try container.encode("spans", forKey: .kind)
            try container.encode(spans, forKey: .spans)
        }
    }

    /// Decodes one of the three upstream parent rules.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "any": self = .any
        case "root_or_external": self = .rootOrExternal
        case "spans": self = .spans(try container.decode([String].self, forKey: .spans))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown telemetry parent kind \(kind)")
        }
    }
}
