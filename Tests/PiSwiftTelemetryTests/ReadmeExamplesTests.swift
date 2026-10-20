// Runs the Swift code blocks of `Sources/PiSwiftTelemetry/README.md`.

import Testing
import PiSwiftTelemetry
import PiSwiftTelemetryTesting

struct Account: Sendable, Equatable {
    let id: String
}

private struct SaveResult: Sendable {
    let ok: Bool
    let reason: String
}

func readAccount(_ id: String) async throws -> Account? { id == "123" ? Account(id: id) : nil }
private func readAccounts() async throws -> [Account] { [Account(id: "1"), Account(id: "2")] }
private func readProjects() async throws -> [String] { ["p"] }
private func save() async throws -> SaveResult { SaveResult(ok: false, reason: "disk full") }

// README: core-context
func loadAccount(_ accountId: String, telemetry: any TelemetryContext = noopTelemetryContext) async throws -> Account? {
    try await telemetry.startSpan(SpanOptions(
        name: "example.account.load", attributes: ["example.account.id": .string(accountId)]
    )) { span in
        let account = try await readAccount(accountId)
        span.setAttributes(["example.account.found": .boolean(account != nil)])
        return account
    }
}
// README: end

// README: conformance
private let cases = createTelemetryAdapterConformance {
    let adapter = InMemoryTelemetryContext()
    return TelemetryAdapterFixture(context: adapter, getSpans: { adapter.getSpans() }, dispose: {})
}

@Test(arguments: cases)
func telemetryAdapterConformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
    try await testCase.run()
}
// README: end

@Suite("PiSwiftTelemetryTests.README examples")
struct ReadmeExamplesTests {
    @Test func coreContext() async throws {
        let telemetry = InMemoryTelemetryContext()
        #expect(try await loadAccount("123", telemetry: telemetry) == Account(id: "123"))
        #expect(try await loadAccount("9") == nil)
        #expect(telemetry.getSpans() == [RecordedTelemetrySpan(
            id: 1, parentId: nil, name: "example.account.load",
            attributes: ["example.account.id": "123", "example.account.found": true],
            settled: true, endSequence: 1)])
    }

    @Test func expectedFailure() async throws {
        let telemetry = InMemoryTelemetryContext()
        // README: expected-failure
        let result = try await telemetry.startSpan(SpanOptions(name: "example.save")) { span in
            let result = try await save()
            if !result.ok {
                span.setStatus(.error(name: "SaveError", message: result.reason))
            }
            return result
        }
        // README: end
        #expect(!result.ok)
        #expect(telemetry.getSpans().first?.status == .error(name: "SaveError", message: "disk full"))
    }

    @Test func inMemory() async {
        // README: in-memory
        let telemetry = InMemoryTelemetryContext()
        await telemetry.startSpan(SpanOptions(name: "example.operation", attributes: ["input": "demo"])) { span in
            span.addEvent("example.started")
            span.setAttributes(["output_count": 3])
        }
        print(telemetry.getSpans())
        // README: end
        #expect(telemetry.getSpans() == [RecordedTelemetrySpan(
            id: 1, parentId: nil, name: "example.operation",
            attributes: ["input": "demo", "output_count": 3],
            events: [RecordedTelemetryEvent(name: "example.started")],
            settled: true, endSequence: 1)])
    }

    @Test func typedSchemas() async throws {
        let telemetry = InMemoryTelemetryContext()
        // README: typed-schemas
        let exampleTelemetrySchema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [
            "example.read": TelemetrySpanDefinition(
                description: "Read one resource",
                parents: .any,
                startAttributes: [
                    "example.resource": .init(.string(values: ["account", "project"]),
                                              description: "Resource kind", required: true),
                ],
                endAttributes: [
                    "example.item_count": .init(.number(), description: "Number of returned items"),
                ],
                events: [
                    "example.cache": TelemetryEventDefinition(description: "Cache lookup result", attributes: [
                        "example.cache.hit": .init(.boolean(), description: "Whether the cache contained the resource",
                                                   required: true),
                    ]),
                ],
                status: TelemetryStatusDefinition(errorWhen: "The read throws or returns an error result")
            ),
        ]))

        let startSpan = createTypedSpanStarter(telemetry, [exampleTelemetrySchema])
        let accounts = try await startSpan("example.read", ["example.resource": "account"]) { span, startChildSpan in
            span.addEvent("example.cache", attributes: ["example.cache.hit": true])
            let accounts = try await readAccounts()
            span.setAttributes(["example.item_count": .number(Double(accounts.count))])
            try await startChildSpan("example.read", ["example.resource": "project"]) { childSpan, _ in
                let projects = try await readProjects()
                childSpan.setAttributes(["example.item_count": .number(Double(projects.count))])
            }
            return accounts
        }
        // README: end
        #expect(accounts.count == 2)
        #expect(telemetry.getSpans() == [
            RecordedTelemetrySpan(
                id: 1, parentId: nil, name: "example.read",
                attributes: ["example.resource": "account", "example.item_count": 2],
                events: [RecordedTelemetryEvent(name: "example.cache", attributes: ["example.cache.hit": true])],
                settled: true, endSequence: 2),
            RecordedTelemetrySpan(
                id: 2, parentId: 1, name: "example.read",
                attributes: ["example.resource": "project", "example.item_count": 1],
                settled: true, endSequence: 1),
        ])
    }
}
