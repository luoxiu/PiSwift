import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

// harness-host-inputs.test.ts: HarnessOptions.models as a function; settings are a provider read at each use.

/// A model service whose only model, faux/faux-1, answers every request with `text`.
private func answering(_ text: String) -> FakeDurableModels {
    FakeDurableModels(responses: (0..<10).map { _ in .message(chatAssistant(text)) })
}

private func hostOpen(_ options: HarnessOptions) async throws -> (harness: Harness, root: Conversation) {
    let harness = try await Harness.open(storage: MemoryStorage(), options: options, context: .background)
    let root = try await harness.root(options: .init(agent: .init(
        model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
    return (harness, root)
}

private func hostTurn(_ root: Conversation, _ content: String) async throws -> String? {
    let settled = try await root.submit(.input(content: .text(content)), context: .background).wait(context: .background)
    #expect(settled.status == "done")
    return textOf(try await allEntries(root).last?.messages()?.first)
}

@Suite struct HarnessHostInputsTests {
    // :52.
    @Test func generationUsesTheCurrentReturnValueOfAModelsFunctionAtEachRequest() async throws {
        let current = Mutex(answering("first"))
        let (harness, root) = try await hostOpen(HarnessOptions(models: { current.withLock { $0 } }, registry: createRegistry()))
        #expect(try await hostTurn(root, "one") == "first")
        current.withLock { $0 = answering("second") }
        #expect(try await hostTurn(root, "two") == "second")
        try await harness.close(context: .background)
    }
    // :61.
    @Test func stillAcceptsAPlainModelService() async throws {
        let (harness, root) = try await hostOpen(HarnessOptions(models: answering("plain"), registry: createRegistry()))
        #expect(try await hostTurn(root, "one") == "plain")
        try await harness.close(context: .background)
    }
    // :67. Each service answers its own request: the tool call before the swap, the answer after it.
    @Test func toolsReadTheCurrentModelsAtEachAccessOfApiModels() async throws {
        let first = FakeDurableModels(responses: [.message(try toolCalls([("probe", [:], "call-1")]))])
        let second = FakeDurableModels(responses: [.message(chatAssistant("done"))])
        let current = Mutex(first)
        let seen = Mutex<[ObjectIdentifier]>([])
        let registry = createRegistry()
        try registry.install(Extension(name: "probe", tools: [try ToolRegistration(name: "probe",
            description: "Records api.models before and after the host swaps it",
            parameters: ["type": "object", "properties": .object([:])]) { _, api, _ in
                seen.withLock { $0.append(ObjectIdentifier(api.models as AnyObject)) }
                current.withLock { $0 = second }
                seen.withLock { $0.append(ObjectIdentifier(api.models as AnyObject)) }
                return ToolExecutionResult(output: [])
            }]))
        let (harness, root) = try await hostOpen(HarnessOptions(models: { current.withLock { $0 } }, registry: registry))
        #expect(try await hostTurn(root, "go") == "done")
        #expect(seen.withLock { $0 } == [ObjectIdentifier(first), ObjectIdentifier(second)])
        try await harness.close(context: .background)
    }
    // Swift: hooks get a `HookApi` value rather than the runtime, so its `models` reads the current service too.
    @Test func hooksReadTheCurrentModelsAtEachAccessOfApiModels() async throws {
        let first = FakeDurableModels(), second = answering("done")
        let current = Mutex(first)
        let seen = Mutex<[ObjectIdentifier]>([])
        let registry = createRegistry()
        try registry.install(Extension(name: "probe", hooks: [hook(GenerationHooks(beforeRequest: { _, api, _ in
            seen.withLock { $0.append(ObjectIdentifier(api.models as AnyObject)) }
            current.withLock { $0 = second }
            seen.withLock { $0.append(ObjectIdentifier(api.models as AnyObject)) }
            return nil
        }))]))
        let (harness, root) = try await hostOpen(HarnessOptions(models: { current.withLock { $0 } }, registry: registry))
        #expect(try await hostTurn(root, "go") == "done")
        #expect(seen.withLock { $0 } == [ObjectIdentifier(first), ObjectIdentifier(second)])
        try await harness.close(context: .background)
    }
    // :102. Swift's settings were already a provider called at each use; this checks the generation reads.
    @Test func generationReadsTheCurrentReturnValueOfASettingsFunction() async throws {
        let timeouts = Mutex<[Int?]>([])
        let reply = FakeDurableResponseStep.factory { _, options, _, _ in
            timeouts.withLock { $0.append(options?.timeoutMs) }
            return chatAssistant("ok")
        }
        let settings = Mutex(HarnessSettings(stream: .init(timeoutMs: 1000)))
        let (harness, root) = try await hostOpen(HarnessOptions(models: FakeDurableModels(responses: [reply, reply]),
            registry: createRegistry(), settings: HarnessSettingsProvider { settings.withLock { $0 } }))
        _ = try await hostTurn(root, "one")
        settings.withLock { $0 = HarnessSettings(stream: .init(timeoutMs: 2000)) }
        _ = try await hostTurn(root, "two")
        #expect(timeouts.withLock { $0 } == [1000, 2000])
        try await harness.close(context: .background)
    }
}
