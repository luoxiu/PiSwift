import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let discoveryEditorToolNames = [
    "xo_editor_state",
    "xo_scene_current",
    "xo_scene_tree",
    "xo_node_property_list",
    "xo_node_property_get",
    "xo_batch"
]

private func discoveryResponse(_ model: Model, script: String?) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let content: [ContentBlock]
    if let script {
        content = [.toolCall(ToolCall(id: "discovery", name: "codemode", arguments: ["code": AnyCodable(script)]))]
    } else {
        content = [.text(TextContent(text: "done"))]
    }
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: script == nil ? .stop : .toolUse)
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

@Test(.timeLimit(.minutes(1)))
func codemodeDiscoveryZeroBudgetOverridesSettingsAndCallsAllEditorTools() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let settings = SettingsManager.inMemory()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let invoked = LockedState<[String]>([])
    let native = InlineExtension(name: "editor") { api in
        for name in discoveryEditorToolNames {
            try api.registerTool(CustomTool(name: name, label: name, description: "Inspect editor state.",
                parameters: ["type": AnyCodable("object")],
                execute: { _, _, _, _, _ in
                    invoked.withLock { $0.append(name) }
                    return AgentToolResult(content: [.text(TextContent(text: name))])
                }, exposure: .codemode)).get()
        }
    }
    let created = try await createAgentSession(CreateAgentSessionOptions(authStorage: auth,
        model: model, offline: true, toolNames: ["codemode"] + discoveryEditorToolNames,
        resourceLoader: TestResourceLoader(),
        inlineExtensions: [createCodemodeExtension(options: .init(mode: .only, inlineBudget: 0)), native],
        sessionManager: .inMemory(), settingsManager: settings))
    let session = created.session
    defer {
        session.dispose()
    }
    session.setActiveToolsByName(["codemode"])
    let codeTool = try #require(session.agent.tools.first { $0.name == "codemode" })
    #expect(!codeTool.description.contains("codemode tool declaration:"))
    #expect(!codeTool.description.contains("### `xo_"))
    #expect(session.agent.tools.map(\.name) == ["codemode"])
    #expect(Set(session.getCallableTools().map(\.name)).isSuperset(of: discoveryEditorToolNames))
    #expect(settings.getCodemodeInlineBudget() == defaultCodemodeInlineBudget)
    let turns = LockedState(0)
    session.agent.streamFn = { model, _, _ in
        let turn = turns.withLock { value in
            value += 1
            return value
        }
        let script = discoveryEditorToolNames.map { "text(await tools.\($0)({}));" }.joined(separator: "\n")
        return discoveryResponse(model, script: turn == 1 ? script : nil)
    }
    try await session.prompt("Inspect the editor.")
    #expect(invoked.withLock { $0 } == discoveryEditorToolNames)
    #expect(settings.getCodemodeInlineBudget() == defaultCodemodeInlineBudget)
}

@Test(.timeLimit(.minutes(1)), arguments: [CodemodeSearchResultDetail.full, .summary])
func codemodeDiscoverySearchDetailKeepsFullDescribeTool(detail: CodemodeSearchResultDetail) async throws {
    let description = "Read editor documentation. " + String(repeating: "Detailed usage guidance. ", count: 30)
    let tool = AgentTool(label: "editor", name: "editor-docs", description: description,
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]])],
        execute: { _, _, _, _ in AgentToolResult(content: []) },
        outputSchema: ["type": AnyCodable("object"), "properties": AnyCodable(["body": ["type": "string"]])])
    let plain = AgentTool(label: "plain", name: "plain_docs", description: String(repeating: "Documentation ", count: 30),
        parameters: [:], execute: { _, _, _, _ in AgentToolResult(content: []) })
    var context = CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
        model: nil, isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    context.setNestedToolHost(tools: [tool, plain]) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: name, name: name, arguments: args),
            result: AgentToolResult(content: []), isError: false)
    }
    let options = CodemodeToolOptions(getToolNamespace: { name in
        name == "editor-docs" ? ToolNamespace(name: "editor") : nil
    }, getToolGuidelines: { ["editor-docs": ["Read only selected documentation."]] }, searchResultDetail: detail)
    let result = try await executeCodemode(toolCallId: "search-detail", params: ["code": AnyCodable("""
        const hits = await searchTools('documentation');
        const filtered = await searchTools('documentation', {namespace: 'editor'});
        return { hits, filtered, schema: await describeTool('editor_docs') };
        """)], context: context, options: options)
    #expect(result.isError != true)
    let text = try #require(result.content.compactMap { block -> String? in
        if case .text(let value) = block {
            return value.text
        }
        return nil
    }.last)
    let value = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let rows = try #require(value["hits"] as? [[String: Any]])
    #expect(rows.count == 2)
    let row = try #require(rows.first { $0["name"] as? String == "editor_docs" })
    let plainRow = try #require(rows.first { $0["name"] as? String == "plain_docs" })
    let sample = try #require(value["schema"] as? String)
    #expect(sample.contains("codemode tool declaration:"))
    #expect(sample.contains("path"))
    #expect(sample.contains("body"))
    #expect(sample.contains("Read only selected documentation."))
    if detail == .summary {
        #expect(Set(row.keys) == ["name", "namespace", "description"])
        #expect(row["namespace"] as? String == "editor")
        #expect(row["description"] as? String == "Read editor documentation.")
        #expect(plainRow["namespace"] is NSNull)
        #expect((plainRow["description"] as? String)?.count ?? 0 <= 160)
        #expect(rows.allSatisfy { !($0["description"] as? String ?? "").contains("codemode tool declaration:") })
    } else {
        #expect(Set(row.keys) == ["name", "description"])
        #expect(row["description"] as? String == sample)
    }
    let filtered = try #require(value["filtered"] as? [[String: Any]])
    #expect(filtered.count == 1)
    #expect(filtered.first?["name"] as? String == "editor_docs")
}

@Test func codemodeDiscoveryOptionsDefaultToFullSearch() {
    #expect(CodemodeToolOptions().searchResultDetail == .full)
    #expect(CodemodeExtensionOptions().searchResultDetail == .full)
    let full = createCodemodeDescription([], options: .init(searchResultDetail: .full))
    let summary = createCodemodeDescription([], options: .init(searchResultDetail: .summary))
    #expect(!full.contains("returns short summaries"))
    #expect(summary.contains("returns short summaries"))
    #expect(summary.contains("call `describeTool(name)` for their full schemas"))
}
