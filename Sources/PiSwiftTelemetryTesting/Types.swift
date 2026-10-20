// Ports upstream `packages/telemetry/src/testing/types.ts` at 482c1381a.

import PiSwiftTelemetry

/// A fresh adapter instance and normalized snapshot reader owned by one conformance case.
public struct TelemetryAdapterFixture: Sendable {
    /// The adapter's context.
    public let context: any TelemetryContext
    /// Returns the finished spans as normalized snapshots. It may flush an asynchronous exporter first.
    public let getSpans: @Sendable () async throws -> [RecordedTelemetrySpan]
    /// Releases the adapter. Each case calls it once, also after a failed check.
    public let dispose: @Sendable () async throws -> Void

    /// Creates a fixture.
    public init(
        context: any TelemetryContext,
        getSpans: @escaping @Sendable () async throws -> [RecordedTelemetrySpan],
        dispose: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.context = context
        self.getSpans = getSpans
        self.dispose = dispose
    }
}

/// Creates an isolated adapter fixture for one conformance case.
public typealias TelemetryAdapterFixtureFactory = @Sendable () async throws -> TelemetryAdapterFixture

/// A runner-independent conformance case that can be registered with any test framework.
public struct TelemetryAdapterConformanceCase: Sendable, CustomStringConvertible {
    /// The group the case belongs to.
    public let group: String
    /// The case name.
    public let name: String
    /// Runs the case with a fresh fixture.
    public let run: @Sendable () async throws -> Void

    /// Creates a case.
    public init(group: String, name: String, run: @escaping @Sendable () async throws -> Void) {
        self.group = group
        self.name = name
        self.run = run
    }

    /// The group and the case name.
    public var description: String { "\(group): \(name)" }
}

/// A failed conformance check, with its source location.
public struct TelemetryConformanceFailure: Error, Sendable, CustomStringConvertible {
    /// The failed check message.
    public let message: String
    /// The source file that contains the failed check.
    public let file: String
    /// The source line that contains the failed check.
    public let line: UInt

    /// Creates a failed check with its message and source location.
    public init(_ message: String, file: String = #filePath, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }

    /// The failure message and source location for display.
    public var description: String { "\(file):\(line): \(message)" }
}
