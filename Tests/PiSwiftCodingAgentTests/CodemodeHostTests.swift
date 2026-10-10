import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func hostContext(_ tool: AgentTool,
                         execute: @escaping NestedToolExecute) -> CustomToolContext {
    var context = CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    context.setNestedToolHost(tools: [tool], execute: execute)
    return context
}

private func hostText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block {
            return text.text
        }
        return nil
    }.joined(separator: "\n")
}

@Test(.timeLimit(.minutes(1))) func codemodeHostTimeoutOptions() async throws {
    #expect(CodemodeToolOptions().defaultTimeoutMs == nil)
    #expect(CodemodeToolOptions().maxTimeoutMs == nil)
    #expect(CodemodeExtensionOptions().defaultTimeoutMs == nil)
    let options = CodemodeToolOptions(defaultTimeoutMs: 50, maxTimeoutMs: 2_000,
                                      validationErrorPrefix: "validation: ")
    let timed = try await executeCodemode(toolCallId: "timeout", params: ["code": AnyCodable("while (true) {}")],
                                          options: options, forceWatchdog: true)
    #expect(timed.isError == true)
    #expect(hostText(timed).contains("50 ms"))
    let allowed = try await executeCodemode(toolCallId: "maximum",
        params: ["code": AnyCodable("// @options: {\"timeout_ms\":2000}\nreturn 1")], options: options)
    #expect(allowed.isError != true)
    for code in ["// @options: {\"timeout_ms\":2001}\nreturn 1", "// @options: {\"timeout_ms\":0}\nreturn 1"] {
        do {
            _ = try await executeCodemode(toolCallId: "invalid", params: ["code": AnyCodable(code)], options: options)
            Issue.record("Invalid timeout was accepted")
        } catch {
            #expect(error.localizedDescription.hasPrefix("validation: "))
        }
    }
}

@Test func codemodeHostTimeoutSettingsPersistAndMerge() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let manager = SettingsManager.create(directory.path, directory.path)
    #expect(manager.getCodemodeDefaultTimeoutMs() == nil)
    #expect(manager.getCodemodeMaxTimeoutMs() == nil)
    manager.setCodemodeDefaultTimeoutMs(60_000)
    manager.setCodemodeMaxTimeoutMs(600_000)
    let reloaded = SettingsManager.create(directory.path, directory.path)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 60_000)
    #expect(reloaded.getCodemodeMaxTimeoutMs() == 600_000)
    var overrides = Settings()
    overrides.codemode = CodemodeSettings(defaultTimeoutMs: 30_000)
    reloaded.applyOverrides(overrides)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 30_000)
    #expect(reloaded.getCodemodeMaxTimeoutMs() == 600_000)
    reloaded.setCodemodeDefaultTimeoutMs(0)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 30_000)
    try Data(#"{"codemode":{"defaultTimeoutMs":true,"maxTimeoutMs":1.5}}"#.utf8)
        .write(to: directory.appendingPathComponent("settings.json"))
    let invalid = SettingsManager.create(directory.path, directory.path)
    #expect(invalid.getCodemodeDefaultTimeoutMs() == nil)
    #expect(invalid.getCodemodeMaxTimeoutMs() == nil)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostRejectsCallsAfterResultAndBoundsRecords() async throws {
    let dispatches = LockedState(0)
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 2_000,
        preludeSource: #"""
        (function(bridge) {
            return { run() {
                bridge("done", "true", "null", "[]");
                for (let i = 0; i < 300; i++) {
                    bridge("call", String(i), "late", "x".repeat(1000));
                }
            }, settle() {}, stalled() {} };
        })
        """#,
        onCall: { _ in
            dispatches.withLock { $0 += 1 }
            return CodemodeRuntimeReply(ok: true)
        })
    #expect(result.execution.failure == nil)
    #expect(dispatches.withLock { $0 } == 0)
    #expect(result.rejectedCalls.count == 128)
    #expect(result.rejectedCalls.allSatisfy { ($0.argsJSON?.count ?? 0) <= 200 })
    #expect(result.rejectedCalls.allSatisfy { $0.signal.isCancelled })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeHostDisablesLateCallsAfterTimeoutOrAbort(abort: Bool) async throws {
    let dispatches = LockedState(0)
    let signal = CancellationToken()
    let task = Task {
        await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: abort ? 2_000 : 100,
            signal: signal, forceWatchdog: true,
            preludeSource: #"""
            (function(bridge) {
                return { run() {
                    bridge("output", "text", "started");
                    const end = Date.now() + 400;
                    while (Date.now() < end) {}
                    bridge("call", "1", "late", "{}");
                }, settle() {}, stalled() {} };
            })
            """#,
            onCall: { _ in
                dispatches.withLock { $0 += 1 }
                return CodemodeRuntimeReply(ok: true)
            })
    }
    if abort {
        try await Task.sleep(for: .milliseconds(100))
        signal.cancel()
    }
    let result = await task.value
    #expect(result.execution.failure?.kind == (abort ? .aborted : .timeout))
    try await Task.sleep(for: .milliseconds(600))
    #expect(dispatches.withLock { $0 } == 0)
    #expect(result.rejectedCalls.count == 1)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostUnknownOutcomeRejectsStructuredSuccess() async throws {
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) }, outputSchema: ["type": AnyCodable("object")])
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "operation-1", name: name, arguments: args),
            result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: operation-1 may still be running"))],
                details: AnyCodable(["outcome": "unknown"]), structuredContent: AnyCodable(["ok": true])),
            isError: false)
    }
    let result = try await executeCodemode(toolCallId: "unknown",
        params: ["code": AnyCodable("await tools.change({})")], context: context)
    #expect(result.isError == true)
    #expect(hostText(result).contains("outcome_unknown: operation-1 may still be running"))
    #expect(hostText(result).contains("outcome unknown — inspect before retrying"))
    let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "outcome_unknown")
    #expect(rows?.first?["id"] as? String == "operation-1")
}

@Test(.timeLimit(.minutes(1))) func codemodeHostPrefixesNestedSchemaValidationBeforeDispatch() async throws {
    let dispatches = LockedState(0)
    let tool = AgentTool(label: "read", name: "read", description: "Read",
        parameters: ["type": AnyCodable("object"),
                     "properties": AnyCodable(["path": ["type": "string"]]),
                     "required": AnyCodable(["path"])]) { _, _, _, _ in
        AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "read-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "validation",
        params: ["code": AnyCodable("try { await tools.read({}) } catch (e) { text(e.message) }")],
        context: context, options: CodemodeToolOptions(validationErrorPrefix: "validation: "))
    #expect(result.isError != true)
    #expect(hostText(result).contains("validation: "))
    #expect(dispatches.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostPublishesLateRejectedCallAfterAbort() async throws {
    let signal = CancellationToken()
    let dispatches = LockedState(0)
    let statuses = LockedState<[String]>([])
    let tool = AgentTool(label: "ready", name: "ready", description: "Ready", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            signal.cancel()
        }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "ready-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "late-abort",
        params: ["code": AnyCodable("await tools.ready({}); const end = Date.now() + 400; while (Date.now() < end) {} await tools.ready({})")],
        signal: signal, onUpdate: { result in
            let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
            statuses.withLock { $0 = rows.compactMap { $0["status"] as? String } }
        }, context: context, forceWatchdog: true)
    #expect(result.isError == true)
    try await Task.sleep(for: .milliseconds(600))
    #expect(dispatches.withLock { $0 } == 1)
    #expect(statuses.withLock { $0 }.contains("rejected_after_end"))
}

@Test(.timeLimit(.minutes(1))) func codemodeHostNamespaceIncludesCatalogVersion() async throws {
    let tool = AgentTool(label: "scene", name: "xo_scene", description: "Read scene", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "scene-1", name: name, arguments: args),
                            result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "namespace-version",
        params: ["code": AnyCodable("text(await describeNamespace('xo.scene'))")], context: context,
        options: CodemodeToolOptions(getToolNamespace: { _ in
            ToolNamespace(name: "xo.scene", version: "catalog-2")
        }))
    #expect(hostText(result).contains("\"version\":\"catalog-2\""))
}

@Test func codemodeHostUnknownNestedRecordRoundTrips() async throws {
    let host = NestedToolCallHost(getTools: { [] }, isSequential: { false },
        runToolCall: { call, _, _, _ in
            AgentToolCallOutcome(toolCall: call,
                result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: inspect operation-1"))],
                                        details: AnyCodable(["outcome": "unknown"])), isError: false)
        }, emit: { _ in })
    let runner = NestedToolCallRunner(host: host)
    _ = await runner.execute(callerId: "outer", name: "change", args: [:])
    let summary = try #require(await runner.takeRecord(toolCallId: "outer"))
    let calls = try #require(summary.calls)
    #expect(calls.calls.first?.status == .outcomeUnknown)
    #expect(calls.calls.first?.error == "outcome_unknown: inspect operation-1")
    let data = try JSONEncoder().encode(calls)
    #expect(String(decoding: data, as: UTF8.self).contains("outcome_unknown"))
    let decoded = try JSONDecoder().decode(NestedToolCalls.self, from: data)
    #expect(decoded.calls.first?.status == .outcomeUnknown)
    let wire = try #require(nestedToolCallsFromJSONObject(nestedToolCallsToJSONObject(calls)))
    #expect(wire.calls.first?.status == .outcomeUnknown)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeHostAbandonedNativeCallRemainsUnknownAndPublishesLateOutcome(abort: Bool) async throws {
    let signal = CancellationToken()
    let dispatches = LockedState(0)
    let latest = LockedState<[[String: AnyCodable]]>([])
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        if abort {
            signal.cancel()
        }
        try? await Task.sleep(for: .milliseconds(700))
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "late-native-1", name: name, arguments: args),
            result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: inspect late-native-1"))],
                                    details: AnyCodable(["outcome": "unknown"])), isError: true)
    }
    let result = try await executeCodemode(toolCallId: "abandoned",
        params: ["code": AnyCodable("await tools.change({})")], signal: signal,
        onUpdate: { result in
            let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
            latest.withLock { $0 = rows.map { $0.mapValues(AnyCodable.init) } }
        }, context: context, options: CodemodeToolOptions(defaultTimeoutMs: abort ? 2_000 : 400),
        forceWatchdog: true)
    #expect(result.isError == true)
    #expect(dispatches.withLock { $0 } == 1)
    let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "outcome_unknown")
    #expect(hostText(result).contains("outcome unknown — inspect before retrying: change"))
    try await Task.sleep(for: .milliseconds(900))
    #expect(latest.withLock { $0.first?["status"]?.value as? String } == "outcome_unknown")
    #expect(latest.withLock { $0.first?["id"]?.value as? String } == "late-native-1")
    #expect(latest.withLock { $0.first?["error"]?.value as? String } == "outcome_unknown: inspect late-native-1")
}
