// HarnessOptions.telemetry (upstream harness-telemetry-options.test.ts).
import Testing
import PiSwiftDurableTesting
import PiSwiftTelemetry
@testable import PiSwiftDurable

@Suite struct HarnessTelemetryOptionsTests {
    // Swift: upstream's `@ts-expect-error` for an object without `startSpan` is a type error in Swift too, so it is
    // not a test. The adapter's optional capabilities are protocols it may also implement.
    @Test func acceptsOneAdapterWithOptionalPropagationAndMetricsCapabilities() {
        let adapter = InMemoryTelemetryContext()
        let full = HarnessOptions(models: FakeDurableModels(), registry: Registry(), telemetry: adapter)
        let contextOnly = HarnessOptions(models: FakeDurableModels(), registry: Registry(), telemetry: noopTelemetryContext)
        let omitted = HarnessOptions(models: FakeDurableModels(), registry: Registry())
        #expect(full.telemetry === adapter)
        #expect(contextOnly.telemetry === noopTelemetryContext)
        #expect(omitted.telemetry == nil)
        #expect(full.telemetry is any TelemetryPropagation)
        #expect(full.telemetry is any TelemetryMetrics)
        #expect(!(contextOnly.telemetry is any TelemetryPropagation))
    }
}
