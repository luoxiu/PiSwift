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

