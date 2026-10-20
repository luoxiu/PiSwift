import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private let countSchema: JSONObject = ["type": "object", "properties": ["count": ["type": "number"]], "required": ["count"]]

/// A tool that returns `result`, with an optional schema and limits.
private func returning(_ name: String, _ result: ToolExecutionResult, schema: JSONObject? = nil,
                       limits: OutputLimitOverrides? = nil) throws -> ToolRegistration {
    try nestedTool(name, structuredOutputSchema: schema, outputLimits: limits) { _, _, _ in result }
}
/// Runs `name` as a nested call of a `probe` tool and returns what the probe received.
private func nested(_ setup: HarnessChatSetup, _ name: String) async throws -> NestedToolExecutionResult {
    let received = Mutex<NestedToolExecutionResult?>(nil)
    try installHarnessTool(try nestedTool("probe") { _, api, context in
        let result = try await api.executeTool(name, context: context)
        received.withLock { $0 = result }
        return .init()
    }, setup: setup)
    let run = try await runNestedOnce(setup, [try nestedCall("probe"), nestedDone])
    try await run.harness.close(context: .background)
    return try #require(received.withLock { $0 })
}
/// Runs `name` as a model-issued call and returns its transcript message.
private func direct(_ setup: HarnessChatSetup, _ name: String) async throws -> ToolResultMessage {
    let run = try await runNestedOnce(setup, [try nestedCall(name), nestedDone])
    try await run.harness.close(context: .background)
    return try #require(try harnessToolResults(run.entries).first)
}
private func codes(_ diagnostics: [ToolDiagnostic]?) -> [String?] { (diagnostics ?? []).map(\.code) }

/// Port of upstream `test/harness-structured-output.test.ts`.
@Suite struct HarnessStructuredOutputTests {
    @Test func givesCallersASchemaLessToolsOutputAsStringImageOrList() async throws {
        let text = ContentBlock.text(TextContent(text: "one"))
        let image = ContentBlock.image(ImageContent(data: "AAAA", mimeType: "image/png"))
        let textValue: JSONValue = ["type": "text", "text": "one"]
        let imageValue: JSONValue = ["type": "image", "data": "AAAA", "mimeType": "image/png"]
        let cases: [([ContentBlock], JSONValue)] = [
            ([text], "one"), ([image], imageValue), ([], ""), ([text, image], [textValue, imageValue]), ([text, text], [textValue, textValue]),
        ]
        for (output, value) in cases {
            let setup = HarnessChatSetup()
            try installHarnessTool(try returning("plain", .init(output: output)), setup: setup)
            let received = try await nested(setup, "plain")
            #expect(received == NestedToolExecutionResult(taskId: received.taskId, structuredOutput: value, isError: false,
                                                          diagnostics: [], durationMs: received.durationMs))
        }
    }

    @Test func givesCallersTheBoundedOutputWithoutTheRenderedDiagnostics() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("long", .init(output: [.text(TextContent(text: "a\nb\nc"))],
            diagnostics: [.init(severity: .info, message: "note")]), limits: .init(maxLines: 1)), setup: setup)
        let received = try await nested(setup, "long")
        #expect(received.structuredOutput == "a\n")
        #expect(codes(received.diagnostics) == [nil, "truncated"])
    }

    @Test func storesExactlyWhatCallersAndEventsGetAndKeepsAStoredNull() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("plain", .init(output: [.text(TextContent(text: "a"))])), setup: setup)
        try installHarnessTool(try returning("nothing", .init(structuredOutput: .null), schema: ["type": "null"]), setup: setup)
        let received = SessionTestLog<NestedToolExecutionResult>()
        try installHarnessTool(try nestedTool("probe") { _, api, context in
            received.append(try await api.executeTool("plain", context: context))
            received.append(try await api.executeTool("nothing", context: context))
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("probe")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        // The result each nested call's document got, as committed.
        let stored = SessionTestLog<NestedToolExecutionResult>()
        let subscription = try opened.harness.subscribeCommits { publication, _ in
            for case .document(let change) in publication.changes where change.record.kind == NestedCallDoc.definition.kind {
                let result = try change.value.map { try JSONValue.object($0).decode(NestedCallState.self) }?.result
                if let result, !change.ops.isEmpty { stored.append(result) }
            }
        }
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        subscription.cancel()
        let ends = events.values.compactMap { event -> NestedToolExecutionResult? in
            if case .toolExecutionEnd(let call, _, let result) = event, call.parentToolCallId != nil { return result }
            return nil
        }
        try await opened.harness.close(context: .background)
        #expect(received.values[0].structuredOutput == "a" && received.values[0].isError == false)
        #expect(received.values[1].structuredOutput == .null && received.values[1].isError == false)
        #expect(stored.values == received.values)
        #expect(ends == received.values)
    }

    @Test func givesCallersASchemaToolsValidatedStructuredOutputWhichTheTranscriptDoesNotStore() async throws {
        let result = ToolExecutionResult(output: [.text(TextContent(text: "3 things"))], structuredOutput: ["count": 3])
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("counter", result, schema: countSchema), setup: setup)
        let received = try await nested(setup, "counter")
        #expect(received.structuredOutput == ["count": 3] && received.isError == false)

        let modelSetup = HarnessChatSetup()
        try installHarnessTool(try returning("counter", result, schema: countSchema), setup: modelSetup)
        let stored = try await direct(modelSetup, "counter")
        #expect(!stored.isError && harnessToolText(stored) == "3 things")
        let message = try JSONValue(encoding: EntryRecord.encodeMessages([.toolResult(stored)]))
        #expect(message[0]?["structuredOutput"] == nil)
    }

    @Test func turnsStructuredOutputThatBreaksTheSchemaIntoAnErrorForCallersAndAReportForTheModel() async throws {
        let cases: [(String, ToolExecutionResult, Bool, String)] = [
            ("wrong", .init(structuredOutput: ["count": "three"]), true, "does not match its schema: count:"),
            ("missing", .init(output: []), true, "returned no structuredOutput"),
            ("undeclared", .init(structuredOutput: ["count": 3]), false, "declares no structuredOutputSchema"),
        ]
        for (name, result, schema, message) in cases {
            let setup = HarnessChatSetup()
            try installHarnessTool(try returning(name, result, schema: schema ? countSchema : nil), setup: setup)
            let received = try await nested(setup, name)
            #expect(received.isError)
            // The broken value is dropped; a schema-less tool's error result still carries its output, here none.
            if schema { #expect(received.structuredOutput == nil) } else { #expect(received.structuredOutput == "") }
            #expect(codes(received.diagnostics) == ["invalid_structured_output"])
            #expect(received.diagnostics.first?.message.contains(message) == true, "\(received.diagnostics)")

            let modelSetup = HarnessChatSetup()
            try installHarnessTool(try returning(name, result, schema: schema ? countSchema : nil), setup: modelSetup)
            // The model never sees structured output: its call stands, and the host gets a report.
            let stored = try await direct(modelSetup, name)
            #expect(!stored.isError)
            #expect(!harnessToolText(stored).contains(message))
            #expect(modelSetup.reports.values.map { String(describing: $0) }.joined(separator: "\n").contains(message))
        }
    }

    @Test func givesCallersTheOutputOfAnErrorResultOfAToolWithoutASchema() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("bad", .init(output: [.text(TextContent(text: "bad"))], isError: true)), setup: setup)
        let received = try await nested(setup, "bad")
        #expect(received.isError && received.structuredOutput == "bad")
    }

    @Test func givesCallersNoStructuredOutputForAnErrorResultTheHarnessWrote() async throws {
        let received = try await nested(HarnessChatSetup(), "missing")
        #expect(received.isError && codes(received.diagnostics) == ["tool_unavailable"])
        #expect(received.structuredOutput == nil)
    }

    @Test func letsAnErrorResultOfASchemaToolOmitStructuredOutputAndKeepsNoneOfItsOutput() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("fails", .init(output: [.text(TextContent(text: "nope"))], isError: true), schema: countSchema), setup: setup)
        let received = try await nested(setup, "fails")
        #expect(received.isError && received.diagnostics.isEmpty)
        #expect(received.structuredOutput == nil)
    }

    @Test func keepsStructuredOutputWhenAfterToolReplacesTheOutputAndValidatesOneAfterToolReplaces() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try returning("plain", .init(output: [.text(TextContent(text: "secret"))])), setup: setup)
        try installHarnessTool(try returning("counter", .init(structuredOutput: ["count": 1]), schema: countSchema), setup: setup)
        try installHarnessTool(try returning("other", .init(structuredOutput: ["count": 1]), schema: countSchema), setup: setup)
        try installToolHooks(setup, ToolHooks(afterTool: { call, result, _, _ in
            var next = result
            if call.name == "other" { next.structuredOutput = ["count": "broken"] }
            else if call.name != "probe" { next.output = [.text(TextContent(text: "rewritten"))] }
            return next
        }))
        let results = NestedResults()
        try installHarnessTool(try nestedTool("probe") { _, api, context in
            for name in ["plain", "counter", "other"] { results.set(name, try await api.executeTool(name, context: context)) }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("probe"), nestedDone])
        try await run.harness.close(context: .background)
        // A schema-less tool's value is its output, so redacting the output redacts what programs get.
        #expect(results["plain"]?.structuredOutput == "rewritten")
        #expect(results["counter"]?.structuredOutput == ["count": 1])
        #expect(results["other"]?.isError == true)
        #expect(codes(results["other"]?.diagnostics) == ["invalid_structured_output"])
    }

    #if os(macOS)
    @Test func givesCallersOfBashItsRetainedOutputAndExitCodeAlsoForANonzeroExit() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup()
        try installHarnessTool(try createBashTool(), setup: setup)
        let received = SessionTestLog<NestedToolExecutionResult>()
        try installHarnessTool(try nestedTool("probe") { _, api, context in
            received.append(try await api.executeTool("bash", arguments: ["command": "printf ok"], context: context))
            received.append(try await api.executeTool("bash", arguments: ["command": "printf bad; exit 4"], context: context))
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("probe")), .message(nestedDone)])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
            env: { _, _ in LocalExecutionEnv(cwd: directory.path) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        _ = try await root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        try await harness.close(context: .background)
        #expect(received.values[0].isError == false)
        #expect(received.values[0].structuredOutput == ["output": "ok", "truncated": false, "exitCode": 0])
        #expect(received.values[1].isError == true)
        #expect(received.values[1].structuredOutput == ["output": "bad", "truncated": false, "exitCode": 4])
        #expect(codes(received.values[1].diagnostics) == ["exit_code"])
    }
    #endif
}
