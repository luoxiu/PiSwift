// Ports upstream `packages/telemetry/test/telemetry.test.ts` at 482c1381a.
// Upstream's compile-time checks (`expectTypeOf`, `@ts-expect-error`) test TypeScript inference,
// which Swift does not have. The "does not inspect or retain telemetry payloads" case passes
// Proxy values that throw on read, which Swift values cannot be.

import Foundation
import Testing
import PiSwiftTelemetry

private final class Thrown: Error, Sendable {
    let kind: String
    init(_ kind: String) { self.kind = kind }
}

private func rejection(_ operation: () async throws -> Void) async -> (any Error)? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("PiSwiftTelemetryTests.telemetry schemas")
struct TelemetrySchemaTests {
    @Test func preservesSerializableDefinitions() throws {
        let definition = TelemetrySchemaDefinition(version: 1, spans: [
            "operation": TelemetrySpanDefinition(
                description: "Test operation",
                parents: .any,
                startAttributes: [
                    "kind": .init(.string(values: ["read", "write"]), description: "Kind", required: true),
                ],
                endAttributes: [:],
                events: [
                    "result": TelemetryEventDefinition(description: "Result", attributes: [
                        "outcome": .init(.string(values: ["ok", "error"]), description: "Outcome", required: true),
                    ]),
                ],
                status: TelemetryStatusDefinition(errorWhen: "The operation fails")
            ),
        ])
        let schema = defineTelemetrySchema(definition)
        #expect(schema == definition)

        #expect(try json(schema) == #"{"spans":{"operation":{"description":"Test operation","endAttributes":{},"#
            + #""events":{"result":{"attributes":{"outcome":{"description":"Outcome","required":true,"type":"string","#
            + #""values":["ok","error"]}},"description":"Result"}},"parents":{"kind":"any"},"startAttributes":{"kind":"#
            + #"{"description":"Kind","required":true,"type":"string","values":["read","write"]}},"#
            + #""status":{"default":"ok","errorWhen":"The operation fails"}}},"version":1}"#)
        let decoded = try JSONDecoder().decode(TelemetrySchemaDefinition.self, from: JSONEncoder().encode(schema))
        #expect(decoded == schema)
    }

    @Test func combinesSchemaVocabulariesAndBindsChildStartersToTheirParentSpans() async throws {
        let operationSchema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [
            "operation": TelemetrySpanDefinition(
                description: "Operation",
                parents: .rootOrExternal,
                startAttributes: [
                    "kind": .init(.string(values: ["read", "write"]), description: "Kind", required: true),
                ],
                endAttributes: [:],
                status: TelemetryStatusDefinition(errorWhen: "The operation fails")
            ),
        ]))
        let requestSchema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 3, spans: [
            "request": TelemetrySpanDefinition(
                description: "Request",
                parents: .spans(["operation"]),
                startAttributes: [
                    "provider": .init(.string(), description: "Provider", required: true),
                ],
                endAttributes: [
                    "response": .init(.string(), description: "Response kind"),
                ],
                status: TelemetryStatusDefinition(errorWhen: "The request fails")
            ),
        ]))
        let telemetryContext = InMemoryTelemetryContext()
        let startSpan = createTypedSpanStarter(telemetryContext, [operationSchema, requestSchema])

        let result = await startSpan("operation", ["kind": "read"]) { _, startChildSpan in
            await startChildSpan("request", ["provider": "example"]) { requestSpan, _ in
                requestSpan.setAttributes(["response": "cached"])
                return 42
            }
        }

        #expect(result == 42)
        let spans = telemetryContext.getSpans()
        let operationSpan = try #require(spans.first { $0.name == "operation" })
        let requestSpan = try #require(spans.first { $0.name == "request" })
        #expect(operationSpan.parentId == nil)
        #expect(requestSpan.parentId == operationSpan.id)
        #expect(requestSpan.attributes == ["provider": "example", "response": "cached"])

        let syncError = Thrown("sync")
        let syncResult = await rejection {
            try await startSpan("operation", ["kind": "write"]) { _, _ in throw syncError }
        }
        #expect((syncResult as? Thrown) === syncError)

        let asyncError = Thrown("async")
        let asyncResult = await rejection {
            try await startSpan("request", ["provider": "example"]) { _, _ in
                await Task.yield()
                throw asyncError
            }
        }
        #expect((asyncResult as? Thrown) === asyncError)
    }

    // Swift addition: the JSON coding of schemas is hand-written, so every attribute type and
    // parent rule goes through upstream's shape and back.
    @Test func codesEveryAttributeTypeAndParentRuleInUpstreamsShape() throws {
        let attributes: [String: TelemetryAttributeDefinition] = [
            "string": .init(.string(values: ["a"], examples: ["a"]), description: "S", sensitive: true, cardinality: .high),
            "number": .init(.number(values: [1, 2.5], examples: [1]), description: "N", cardinality: .low),
            "boolean": .init(.boolean(values: [true]), description: "B"),
            "strings": .init(.stringArray(elementValues: ["x"], examples: [["x"]]), description: "SA"),
            "numbers": .init(.numberArray(elementValues: [3], examples: [[3, 4]]), description: "NA"),
            "booleans": .init(.booleanArray(examples: [[false]]), description: "BA"),
        ]
        #expect(try json(attributes) == #"{"boolean":{"description":"B","type":"boolean","values":[true]},"#
            + #""booleans":{"description":"BA","examples":[[false]],"type":"boolean[]"},"#
            + #""number":{"cardinality":"low","description":"N","examples":[1],"type":"number","values":[1,2.5]},"#
            + #""numbers":{"description":"NA","elementValues":[3],"examples":[[3,4]],"type":"number[]"},"#
            + #""string":{"cardinality":"high","description":"S","examples":["a"],"sensitive":true,"type":"string","#
            + #""values":["a"]},"strings":{"description":"SA","elementValues":["x"],"examples":[["x"]],"type":"string[]"}}"#)
        let decoded = try JSONDecoder().decode(
            [String: TelemetryAttributeDefinition].self, from: JSONEncoder().encode(attributes))
        #expect(decoded == attributes)

        let parents: [TelemetryParentDefinition] = [.any, .rootOrExternal, .spans(["a", "b"])]
        #expect(try json(parents) == #"[{"kind":"any"},{"kind":"root_or_external"},{"kind":"spans","spans":["a","b"]}]"#)
        let parentData = try JSONEncoder().encode(parents)
        #expect(try JSONDecoder().decode([TelemetryParentDefinition].self, from: parentData) == parents)
    }
}

@Suite("PiSwiftTelemetryTests.noopTelemetryContext")
struct NoopTelemetryContextTests {
    @Test func admitsCallbacksSynchronouslyAndReusesOneInertSpan() async {
        var admitted = false
        var firstSpan: (any TelemetrySpan)?
        let result = await noopTelemetryContext.startSpan(SpanOptions(name: "first")) { span in
            admitted = true
            firstSpan = span
            let child = await span.startSpan(SpanOptions(name: "child")) { childSpan in childSpan }
            #expect(child === span)
            return 42
        }

        #expect(admitted)
        #expect(result == 42)
        // Upstream checks that the span is frozen; the Swift span is stateless and is the shared context.
        #expect(firstSpan === noopTelemetryContext)
    }

    @Test func preservesSynchronousAndAsynchronousRejectionValues() async {
        let syncError = Thrown("sync")
        let sync = await rejection {
            try await noopTelemetryContext.startSpan(SpanOptions(name: "sync")) { _ in throw syncError }
        }
        #expect((sync as? Thrown) === syncError)

        let asyncError = Thrown("async")
        let asyncResult = await rejection {
            try await noopTelemetryContext.startSpan(SpanOptions(name: "async")) { _ in
                await Task.yield()
                throw asyncError
            }
        }
        #expect((asyncResult as? Thrown) === asyncError)
    }
}
