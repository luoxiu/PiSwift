// Ports the contract half of upstream `packages/telemetry/src/index.ts` at 482c1381a.
// The schema half is in `TelemetrySchema.swift`.

/// An attribute value: a string, number, or boolean, or an array of one of them.
public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case stringArray([String])
    case numberArray([Double])
    case booleanArray([Bool])
}

extension AttributeValue: ExpressibleByStringLiteral {
    /// A string value.
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AttributeValue: ExpressibleByIntegerLiteral {
    /// A number value.
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension AttributeValue: ExpressibleByFloatLiteral {
    /// A number value.
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension AttributeValue: ExpressibleByBooleanLiteral {
    /// A boolean value.
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

/// An open attribute bag. A nil value is ignored, as upstream ignores `undefined`.
public typealias SpanAttributes = [String: AttributeValue?]

/// The span name and its start attributes.
public struct SpanOptions: Sendable {
    /// The span name.
    public var name: String
    /// Attributes known when the span starts.
    public var attributes: SpanAttributes?

    /// Creates options for one span.
    public init(name: String, attributes: SpanAttributes? = nil) {
        self.name = name
        self.attributes = attributes
    }
}

/// An explicit `ok` or `error` outcome.
public enum SpanStatus: Sendable, Hashable {
    /// The name and message of a failed operation.
    public struct ErrorDetails: Sendable, Hashable {
        /// The error name.
        public var name: String
        /// The error message.
        public var message: String

        /// Creates error details.
        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    case ok
    /// A failure, with or without details.
    case error(ErrorDetails?)

    /// A failure with an error name and message.
    public static func error(name: String, message: String) -> SpanStatus {
        .error(ErrorDetails(name: name, message: message))
    }
}

/// Starts callback-managed child spans.
///
/// An adapter runs `body` once, in the caller's task, before `startSpan` returns. It keeps the span
/// open until `body` returns or throws, and returns the same value or throws the same error.
/// Implementations are `nonisolated(nonsending)`, so `body` runs on the caller's executor.
public protocol TelemetryContext: AnyObject, Sendable {
    /// Runs `body` in a new child span and settles the span when `body` finishes.
    nonisolated(nonsending) func startSpan<T, E: Error>(
        _ options: SpanOptions,
        _ body: (any TelemetrySpan) async throws(E) -> T
    ) async throws(E) -> T
}

/// Records attributes, events, and status. A span is also the parent context of its child spans.
/// Recording methods are synchronous and passive. Calls after settlement have no effect.
public protocol TelemetrySpan: TelemetryContext {
    /// Records an event at this point in the span.
    func addEvent(_ name: String, attributes: SpanAttributes?)
    /// Merges attributes. A later value replaces an earlier one, and a nil value is ignored.
    func setAttributes(_ attributes: SpanAttributes)
    /// Sets the outcome. The last call wins over the automatic status.
    func setStatus(_ status: SpanStatus)
}

extension TelemetrySpan {
    /// Records an event without attributes.
    public func addEvent(_ name: String) {
        addEvent(name, attributes: nil)
    }
}
