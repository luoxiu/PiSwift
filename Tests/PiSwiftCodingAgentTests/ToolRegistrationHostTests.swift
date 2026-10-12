import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func registrationTool(_ name: String, _ value: String) -> CustomTool {
    CustomTool(name: name, label: name, description: value,
        parameters: ["type": AnyCodable("object")],
        execute: { _, _, _, _, _ in
            CustomToolResult(content: [.text(TextContent(text: value))])
        })
}

private func registrationSession(policy: ToolNameCollisionPolicy = .overwrite,
                                 custom: [CustomToolDefinition] = [],
                                 extensions: [InlineExtension] = []) async throws -> CreateAgentSessionResult {
    let model = try #require(getModel(provider: .openai, modelId: "gpt-4o-mini"))
    return try await createAgentSession(CreateAgentSessionOptions(
        cwd: "/tmp", agentDir: "/tmp/registration-\(UUID().uuidString)",
        authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
        model: model, offline: true, noTools: .builtin, toolNameCollisionPolicy: policy,
        customTools: custom, resourceLoader: TestResourceLoader(), hooks: [],
        inlineExtensions: extensions, sessionManager: .inMemory(), settingsManager: .inMemory()))
}

@Test func hostRegistrationHasDeterministicOrderAndWinningOwner() async throws {
    let result = try await registrationSession(custom: [
        CustomToolDefinition(path: "/tmp/earlier.swift", tool: registrationTool("same", "file"))
    ], extensions: [InlineExtension(name: "later") { api in
        try api.registerTool(registrationTool("zeta", "z")).get()
        try api.registerTool(registrationTool("same", "inline")).get()
        try api.registerTool(registrationTool("alpha", "a")).get()
    }])
    defer { result.session.dispose() }
    let same = try #require(result.session.getAllTools().first { $0.name == "same" })
    #expect(same.ownerPath == "<inline:later>")
    #expect(same.sourceInfo?.path == same.ownerPath)
    #expect(same.description == "inline")
    #expect(result.session.getAllTools().filter { ["same", "zeta", "alpha"].contains($0.name) }.map(\.name) == ["same", "zeta", "alpha"])
    let tool = try #require(result.session.getCallableTools().first { $0.name == "same" })
    let reply = try await tool.execute("call", [:], nil, nil)
    if case .text(let text) = reply.content.first {
        #expect(text.text == "inline")
    } else {
        Issue.record("Expected text result")
    }
}

@Test func hostRegistrationLiveOverwriteKeepsActualOwnerAndExecutable() async throws {
    let firstAPI = LockedState<HookAPI?>(nil)
    let laterAPI = LockedState<HookAPI?>(nil)
    let result = try await registrationSession(extensions: [
        InlineExtension(name: "first") { api in
            firstAPI.withLock { $0 = api }
            try api.registerTool(registrationTool("same", "first")).get()
        },
        InlineExtension(name: "later") { api in
            laterAPI.withLock { $0 = api }
            try api.registerTool(registrationTool("same", "later")).get()
        }
    ])
    defer { result.session.dispose() }
    let first = try #require(firstAPI.withLock { $0 })
    let later = try #require(laterAPI.withLock { $0 })
    try first.registerTool(registrationTool("same", "live")).get()
    #expect(result.session.getAllTools().first { $0.name == "same" }?.ownerPath == "<inline:first>")
    #expect(later.unregisterTool("same"))
    let tool = try #require(result.session.getCallableTools().first { $0.name == "same" })
    let reply = try await tool.execute("call", [:], nil, nil)
    if case .text(let text) = reply.content.first {
        #expect(text.text == "live")
    } else {
        Issue.record("Expected text result")
    }
    #expect(first.unregisterTool("same"))
    #expect(!result.session.getAllTools().contains { $0.name == "same" })
}

@Test func hostRegistrationRejectsDuplicateFactoriesAndReportsOwner() async throws {
    let result = try await registrationSession(policy: .reject, extensions: [
        InlineExtension(name: "first") { api in
            try api.registerTool(registrationTool("same", "first")).get()
        },
        InlineExtension(name: "later") { api in
            let rejected = api.registerTool(registrationTool("same", "later"))
            if case .failure(.toolNameCollision(let name, let owner, let path)) = rejected {
                #expect(name == "same")
                #expect(owner == "<inline:first>")
                #expect(path == "<inline:later>")
            } else {
                Issue.record("Expected duplicate registration failure")
            }
        }
    ])
    defer { result.session.dispose() }
    #expect(result.session.getAllTools().first { $0.name == "same" }?.description == "first")
    #expect(result.diagnostics.contains { $0.type == "error" && $0.message.contains("<inline:first>") })
}

@Test func hostRegistrationRejectsDuplicateCustomTools() async throws {
    await #expect(throws: HookAPIError.self) {
        try await registrationSession(policy: .reject, custom: [
            CustomToolDefinition(path: "first", tool: registrationTool("same", "first")),
            CustomToolDefinition(path: "later", tool: registrationTool("same", "later"))
        ])
    }
}

@Test func hostRegistrationRejectsLiveDuplicateWithoutChangingOwner() async throws {
    let saved = LockedState<HookAPI?>(nil)
    let result = try await registrationSession(policy: .reject,
        custom: [CustomToolDefinition(path: "custom", tool: registrationTool("same", "custom"))],
        extensions: [InlineExtension(name: "live") { api in
            saved.withLock { $0 = api }
        }])
    defer { result.session.dispose() }
    let api = try #require(saved.withLock { $0 })
    let diagnostics = LockedState<[HookError]>([])
    let stop = result.session.hookRunner?.onError { error in
        diagnostics.withLock { $0.append(error) }
    }
    defer { stop?() }
    #expect(throws: HookAPIError.self) {
        try api.registerTool(registrationTool("same", "live")).get()
    }
    #expect(result.session.getAllTools().first { $0.name == "same" }?.ownerPath == "custom")
    #expect(api.tools["same"] == nil)
    #expect(diagnostics.withLock { $0 }.contains { $0.event == "register_tool" && $0.error.contains("custom") })
    try api.registerTool(registrationTool("other", "other")).get()
    #expect(result.session.getAllTools().contains { $0.name == "other" })
}

@Test func hostRegistrationPreservesLegacyHandlers() throws {
    let api = HookAPI(hookPath: "legacy")
    let registered = LockedState<[String]>([])
    api.setRegisterToolHandler { tool in
        registered.withLock { $0.append(tool.name) }
    }
    api.setUnregisterToolHandler { name in
        registered.withLock { $0.removeAll { $0 == name } }
    }
    try api.registerTool(registrationTool("test", "test")).get()
    #expect(registered.withLock { $0 } == ["test"])
    #expect(api.unregisterTool("test"))
    #expect(registered.withLock { $0 }.isEmpty)
}

@Test func hostNamespaceVersionRoundTripsAndIdentifierCollisionsHaveDiagnostics() throws {
    let namespace = ToolNamespace(name: "editor", instructions: "Use editor tools.", version: "1.2")
    let decoded = try JSONDecoder().decode(ToolNamespace.self, from: JSONEncoder().encode(namespace))
    #expect(decoded.version == "1.2")
    #expect(ToolNamespace(name: "old").version == nil)
    #expect(codemodeToolIdentifierCollision(["edit-node", "edit_node"])?.contains("edit-node") == true)
    #expect(codemodeToolIdentifierCollision(["edit_node", "read_node"]) == nil)
}

@Test func hostRegistrationEarlierFileOwnerCanReplaceLaterInlineOwner() async throws {
    let manager = SessionManager.inMemory()
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let bus = createEventBus()
    let filePath = "/tmp/earlier-extension.swift"
    let fileAPI = HookAPI(events: bus, hookPath: filePath)
    try fileAPI.registerTool(registrationTool("same", "file")).get()
    let fileHook = LoadedHook(path: filePath, resolvedPath: filePath, handlers: [:],
        tools: fileAPI.tools, currentTools: { fileAPI.tools },
        currentToolOrder: { fileAPI.toolRegistrationOrder },
        setRegisterOwnedToolHandler: fileAPI.setRegisterOwnedToolHandler,
        setUnregisterOwnedToolHandler: fileAPI.setUnregisterOwnedToolHandler,
        isExtension: true)
    let inlineHook = try #require(ExtensionLoader.load(InlineExtension(name: "later") { api in
        try api.registerTool(registrationTool("same", "inline")).get()
    }, cwd: "/tmp", eventBus: bus).hook)
    let runner = HookRunner([fileHook, inlineHook], "/tmp", manager, registry)
    let context = CustomToolContext(sessionManager: manager, modelRegistry: registry,
        model: nil, isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: bus, sendMessage: { _, _ in })
    let wrap: @Sendable ([CustomTool]) -> [AgentTool] = { tools in
        wrapCustomTools(tools.map { LoadedCustomTool(path: "fixture", resolvedPath: "fixture", tool: $0) },
                        contextFactory: { _, _ in context })
    }
    let tools = wrap(runner.getExtensionTools())
    let agent = Agent(AgentOptions(initialState: AgentState(tools: tools)))
    let definitions = Dictionary(uniqueKeysWithValues: runner.getExtensionTools().map { ($0.name, $0) })
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), hookRunner: runner,
        modelRegistry: registry, toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
        toolRegistryOrder: tools.map(\.name), toolDefinitions: definitions, wrapExtensionTools: wrap))
    defer { session.dispose() }
    #expect(session.getAllTools().first?.ownerPath == "<inline:later>")
    try fileAPI.registerTool(registrationTool("same", "file replacement")).get()
    let info = try #require(session.getAllTools().first)
    #expect(info.ownerPath == filePath)
    #expect(info.sourceInfo?.path == filePath)
    #expect(info.description == "file replacement")
    let installed = try #require(session.getCallableTools().first)
    let reply = try await installed.execute("call", [:], nil, nil)
    if case .text(let text) = reply.content.first {
        #expect(text.text == "file replacement")
    } else {
        Issue.record("Expected file replacement result")
    }
}

@Test func hostRegistrationRejectsDuplicateWithinFactory() {
    let registry = ToolRegistrationRegistry(collisionPolicy: .reject)
    let result = ExtensionLoader.load(InlineExtension(name: "twice") { api in
        try api.registerTool(registrationTool("same", "first")).get()
        try api.registerTool(registrationTool("same", "second")).get()
    }, cwd: "/tmp", eventBus: createEventBus(), toolRegistrationRegistry: registry)
    #expect(result.hook == nil)
    #expect(result.error?.localizedDescription.contains("<inline:twice>") == true)
    let next = ExtensionLoader.load(InlineExtension(name: "next") { api in
        try api.registerTool(registrationTool("same", "next")).get()
    }, cwd: "/tmp", eventBus: createEventBus(), toolRegistrationRegistry: registry)
    #expect(next.hook != nil)
}

@Test func hostRegistrationRejectsFactoryCollisionWithCustomOwner() async throws {
    let rejected = LockedState(false)
    let result = try await registrationSession(policy: .reject,
        custom: [CustomToolDefinition(path: "/tmp/custom.swift", tool: registrationTool("same", "custom"))],
        extensions: [InlineExtension(name: "later") { api in
            if case .failure(.toolNameCollision(_, let owner, _)) = api.registerTool(registrationTool("same", "later")) {
                rejected.withLock { $0 = owner == "/tmp/custom.swift" }
            }
        }])
    defer { result.session.dispose() }
    #expect(rejected.withLock { $0 })
    #expect(result.session.getAllTools().first { $0.name == "same" }?.ownerPath == "/tmp/custom.swift")
}

@Test func hostRegistrationRejectsStartupJavaScriptIdentifierCollisionWithDiagnostic() async throws {
    let rejected = LockedState(false)
    let result = try await registrationSession(policy: .reject, extensions: [
        InlineExtension(name: "first") { api in
            try api.registerTool(registrationTool("foo-bar", "first")).get()
        },
        InlineExtension(name: "later") { api in
            let result = api.registerTool(registrationTool("foo_bar", "later"))
            if case .failure(.toolIdentifierCollision(let identifier, _, let ownerName, let ownerPath, _)) = result {
                rejected.withLock { $0 = identifier == "foo_bar" && ownerName == "foo-bar" && ownerPath == "<inline:first>" }
            }
        }
    ])
    defer { result.session.dispose() }
    #expect(rejected.withLock { $0 })
    #expect(!result.session.getAllTools().contains { $0.name == "foo_bar" })
    #expect(result.diagnostics.contains { $0.type == "error" && $0.message.contains("JavaScript identifier") })
}

@Test func hostRegistrationRejectsLiveJavaScriptIdentifierCollisionWithDiagnostic() async throws {
    let saved = LockedState<HookAPI?>(nil)
    let result = try await registrationSession(policy: .reject,
        custom: [CustomToolDefinition(path: "custom", tool: registrationTool("foo-bar", "custom"))],
        extensions: [InlineExtension(name: "live") { api in
            saved.withLock { $0 = api }
        }])
    defer { result.session.dispose() }
    let diagnostics = LockedState<[HookError]>([])
    let stop = result.session.hookRunner?.onError { error in
        diagnostics.withLock { $0.append(error) }
    }
    defer { stop?() }
    let api = try #require(saved.withLock { $0 })
    #expect(throws: HookAPIError.self) {
        try api.registerTool(registrationTool("foo_bar", "live")).get()
    }
    #expect(!result.session.getAllTools().contains { $0.name == "foo_bar" })
    #expect(diagnostics.withLock { $0 }.contains { $0.event == "register_tool" && $0.error.contains("foo-bar") && $0.error.contains("custom") })
}

@Test func hostRegistrationDefaultPolicyPreservesJavaScriptIdentifierCollisions() async throws {
    let result = try await registrationSession(custom: [
        CustomToolDefinition(path: "first", tool: registrationTool("foo-bar", "first")),
        CustomToolDefinition(path: "later", tool: registrationTool("foo_bar", "later"))
    ])
    defer { result.session.dispose() }
    #expect(result.session.getAllTools().contains { $0.name == "foo-bar" })
    #expect(result.session.getAllTools().contains { $0.name == "foo_bar" })
    #expect(result.diagnostics.isEmpty)
}

@Test func hostRegistrationRejectsCustomJavaScriptIdentifierCollisions() async throws {
    await #expect(throws: HookAPIError.self) {
        try await registrationSession(policy: .reject, custom: [
            CustomToolDefinition(path: "first", tool: registrationTool("foo-bar", "first")),
            CustomToolDefinition(path: "later", tool: registrationTool("foo_bar", "later"))
        ])
    }
}

@Test func hostRegistrationHandledCollisionKeepsOtherToolsAndEventHooks() async throws {
    let eventCalls = LockedState(0)
    let result = try await registrationSession(policy: .reject, extensions: [
        InlineExtension(name: "first") { api in
            try api.registerTool(registrationTool("same", "first")).get()
        },
        InlineExtension(name: "later") { api in
            _ = api.registerTool(registrationTool("same", "rejected"))
            try api.registerTool(registrationTool("unrelated", "kept")).get()
            api.onAny("session_start") { _, _ in
                eventCalls.withLock { $0 += 1 }
                return nil
            }
        }
    ])
    defer { result.session.dispose() }
    #expect(result.session.hookRunner?.getExtensionHookPaths().contains("<inline:later>") == true)
    #expect(result.session.getAllTools().contains { $0.name == "unrelated" })
    #expect(result.session.getAllTools().first { $0.name == "same" }?.description == "first")
    await result.session.hookRunner?.emitToExtensions(SessionStartEvent(reason: .reload))
    #expect(eventCalls.withLock { $0 } >= 1)
    #expect(result.diagnostics.contains { $0.type == "error" && $0.path == "<inline:later>" })
}

@Test func hostRegistrationRejectPolicyLetsOwnerUpdateItsTool() async throws {
    let saved = LockedState<HookAPI?>(nil)
    let result = try await registrationSession(policy: .reject, extensions: [InlineExtension(name: "owner") { api in
        saved.withLock { $0 = api }
        try api.registerTool(registrationTool("same", "first")).get()
    }])
    defer { result.session.dispose() }
    let api = try #require(saved.withLock { $0 })
    var updated = registrationTool("same", "updated")
    updated.exposure = .codemode
    try api.registerTool(updated).get()
    var withdrawn = registrationTool("same", "withdrawn")
    withdrawn.exposure = .hidden
    try api.registerTool(withdrawn).get()
    let info = try #require(result.session.getAllTools().first { $0.name == "same" })
    #expect(info.ownerPath == "<inline:owner>")
    #expect(info.exposure == .hidden)
    #expect(info.description == "withdrawn")
    #expect(!result.session.getCallableTools().contains { $0.name == "same" })
}

private func replaceableBuiltin(_ events: LockedState<Int>) -> InlineExtension {
    InlineExtension(name: "replaceable-tool", builtin: true, replaceable: true) { api in
        _ = api.registerTool(registrationTool("same", "builtin"))
        api.onAny("session_start") { _, _ in
            events.withLock { $0 += 1 }
            return nil
        }
    }
}

@Test(arguments: [false, true])
func hostRegistrationRejectPolicyReplacesReplaceableBuiltin(extensionFirst: Bool) async throws {
    let events = LockedState(0)
    let user = InlineExtension(name: "user") { api in
        try api.registerTool(registrationTool("same", "user")).get()
    }
    let extensions = extensionFirst ? [user, replaceableBuiltin(events)] : [replaceableBuiltin(events), user]
    let result = try await registrationSession(policy: .reject, extensions: extensions)
    defer { result.session.dispose() }
    let info = try #require(result.session.getAllTools().first { $0.name == "same" })
    #expect(info.ownerPath == "<inline:user>")
    #expect(info.description == "user")
    #expect(result.session.hookRunner?.getExtensionHookPaths().contains("builtin:replaceable-tool") == false)
    #expect(!result.diagnostics.contains { $0.type == "error" })
    #expect(result.diagnostics.contains { $0.type == "warning" && $0.path == "builtin:replaceable-tool" })
    await result.session.hookRunner?.emitToExtensions(SessionStartEvent(reason: .reload))
    #expect(events.withLock { $0 } == 0)
}

@Test func hostRegistrationReservesOnlyCreatedBuiltins() {
    let names = availableBuiltInToolNames(bash: nil, includesSubagent: false)
    #expect(!names.contains(.subagent))
    #expect(availableBuiltInToolNames(bash: nil, includesSubagent: true).contains(.subagent))
    #expect(availableBuiltInToolNames(bash: BashToolOptions(operations: nil), includesSubagent: false).contains(.bash)
        == shouldIncludeBashTool(BashToolOptions(operations: nil)))
    let registry = ToolRegistrationRegistry(collisionPolicy: .reject)
    for name in names {
        _ = registry.register(name: name.rawValue, ownerPath: BUILTIN_PATH_PREFIX + name.rawValue, kind: .fixed)
    }
    #expect(registry.register(name: "subagent", ownerPath: "<inline:host>", kind: .extension) == nil)
}

@Test func hostRegistrationDefaultOrderFollowsCurrentTools() throws {
    let path = "/tmp/late-tools.swift"
    let api = HookAPI(hookPath: path)
    let hook = LoadedHook(path: path, resolvedPath: path, handlers: [:], tools: api.tools,
                          currentTools: { api.tools }, isExtension: true)
    try api.registerTool(registrationTool("late", "late")).get()
    #expect(hook.currentToolOrder() == ["late"])
    let runner = HookRunner([hook], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    #expect(runner.getExtensionToolDefinitions().map(\.tool.name) == ["late"])
}

private struct RegistrationFactoryError: Error, LocalizedError {
    var errorDescription: String? { "factory failed" }
}

@Test(arguments: [ToolNameCollisionPolicy.overwrite, .reject])
func hostRegistrationReportsLoadErrorsWithEachPolicy(policy: ToolNameCollisionPolicy) async throws {
    let result = try await registrationSession(policy: policy, extensions: [InlineExtension(name: "broken") { _ in
        throw RegistrationFactoryError()
    }])
    defer { result.session.dispose() }
    #expect(result.diagnostics.contains { $0.type == "error" && $0.message.contains("factory failed") })
}

@Test(arguments: [ToolNameCollisionPolicy.overwrite, .reject])
func hostRegistrationFailedFactoryRestoresPriorReservations(policy: ToolNameCollisionPolicy) throws {
    let registry = ToolRegistrationRegistry(collisionPolicy: policy)
    let bus = createEventBus()
    let original = ExtensionLoader.load(InlineExtension(name: "original", builtin: true, replaceable: true) { api in
        try api.registerTool(registrationTool("foo-bar", "original")).get()
        try api.registerTool(registrationTool("second", "original second")).get()
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    #expect(original.hook != nil)
    let failed = ExtensionLoader.load(InlineExtension(name: "failed") { api in
        var replacement = registrationTool("foo-bar", "replacement")
        replacement.exposure = .hidden
        try api.registerTool(replacement).get()
        try api.registerTool(registrationTool("temporary", "temporary")).get()
        try api.registerTool(registrationTool("second", "replacement second")).get()
        throw RegistrationFactoryError()
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    #expect(failed.hook == nil)
    let error = registry.register(name: "foo_bar", ownerPath: "probe", kind: .fixed)
    if policy == .reject {
        if case .toolIdentifierCollision(_, _, let ownerName, let ownerPath, _) = error {
            #expect(ownerName == "foo-bar")
            #expect(ownerPath == "builtin:original")
        } else {
            Issue.record("Expected the original identifier owner")
        }
        for name in ["foo-bar", "second"] {
            if case .toolNameCollision(_, let ownerPath, _) = registry.register(name: name, ownerPath: "probe", kind: .fixed) {
                #expect(ownerPath == "builtin:original")
            } else {
                Issue.record("Expected the original name owner")
            }
        }
    } else {
        #expect(error == nil)
    }
    #expect(registry.register(name: "temporary", ownerPath: "next", kind: .fixed) == nil)
}

@Test(arguments: [false, true])
func hostRegistrationFailedReplacementKeepsBuiltinAndIdentifierOwner(replacementFirst: Bool) async throws {
    let events = LockedState(0)
    let rejected = LockedState(false)
    let original = InlineExtension(name: "original", builtin: true, replaceable: true) { api in
        try api.registerTool(registrationTool("foo-bar", "original")).get()
        api.onAny("session_start") { _, _ in
            events.withLock { $0 += 1 }
            return nil
        }
    }
    let failed = InlineExtension(name: "failed") { api in
        try api.registerTool(registrationTool("foo-bar", "replacement")).get()
        throw RegistrationFactoryError()
    }
    let next = InlineExtension(name: "next") { api in
        if case .failure(.toolIdentifierCollision(_, _, _, let ownerPath, _)) = api.registerTool(registrationTool("foo_bar", "next")) {
            rejected.withLock { $0 = ownerPath == "builtin:original" }
        }
    }
    let extensions = replacementFirst ? [failed, original, next] : [original, failed, next]
    let result = try await registrationSession(policy: .reject, extensions: extensions)
    defer { result.session.dispose() }
    #expect(rejected.withLock { $0 })
    #expect(result.session.getAllTools().first { $0.name == "foo-bar" }?.ownerPath == "builtin:original")
    #expect(!result.session.getAllTools().contains { $0.name == "foo_bar" })
    #expect(result.session.hookRunner?.getExtensionHookPaths().contains("builtin:original") == true)
    await result.session.hookRunner?.emitToExtensions(SessionStartEvent(reason: .reload))
    #expect(events.withLock { $0 } >= 1)
}

@Test func hostRegistrationFactoryRemovalRestoresPriorReservation() throws {
    let registry = ToolRegistrationRegistry(collisionPolicy: .reject)
    let bus = createEventBus()
    let original = ExtensionLoader.load(InlineExtension(name: "original", builtin: true, replaceable: true) { api in
        try api.registerTool(registrationTool("foo-bar", "original")).get()
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    #expect(original.hook != nil)
    let replacement = ExtensionLoader.load(InlineExtension(name: "removed") { api in
        try api.registerTool(registrationTool("foo-bar", "replacement")).get()
        #expect(api.unregisterTool("foo-bar"))
        if case .failure(.toolIdentifierCollision(_, _, _, let ownerPath, _)) = api.registerTool(registrationTool("foo_bar", "next")) {
            #expect(ownerPath == "builtin:original")
        } else {
            Issue.record("Expected the original owner after factory removal")
        }
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    #expect(replacement.hook != nil)
    if case .toolNameCollision(_, let ownerPath, _) = registry.register(name: "foo-bar", ownerPath: "probe", kind: .fixed) {
        #expect(ownerPath == "builtin:original")
    } else {
        Issue.record("Expected the original owner after factory commit")
    }
}

@Test(arguments: [ToolNameCollisionPolicy.overwrite, .reject])
func hostRegistrationCommittedReplacementRemovalDoesNotRestoreBuiltin(policy: ToolNameCollisionPolicy) throws {
    let registry = ToolRegistrationRegistry(collisionPolicy: policy)
    let bus = createEventBus()
    let original = ExtensionLoader.load(InlineExtension(name: "original", builtin: true, replaceable: true) { api in
        try api.registerTool(registrationTool("foo-bar", "original")).get()
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    let saved = LockedState<HookAPI?>(nil)
    let replacement = ExtensionLoader.load(InlineExtension(name: "replacement") { api in
        saved.withLock { $0 = api }
        try api.registerTool(registrationTool("foo-bar", "replacement")).get()
    }, cwd: "/tmp", eventBus: bus, toolRegistrationRegistry: registry)
    let originalHook = try #require(original.hook)
    let replacementHook = try #require(replacement.hook)
    let kept = omitReplacedExtensions([originalHook, replacementHook])
    #expect(kept.hooks.map(\.path) == ["<inline:replacement>"])
    let api = try #require(saved.withLock { $0 })
    #expect(api.unregisterTool("foo-bar"))
    #expect(registry.register(name: "foo_bar", ownerPath: "next", kind: .fixed) == nil)
}

@Test func hostRegistrationPreparedCallSkipsPrepareButValidates() async throws {
    let prepared = LockedState(0)
    let tool = AgentTool(label: "read", name: "read", description: "Read",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]]),
                     "required": AnyCodable(["path"])],
        execute: { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "read"))]) },
        prepareArguments: { _ in
            prepared.withLock { $0 += 1 }
            return nil
        })
    let model = try #require(getModel(provider: .openai, modelId: "gpt-4o-mini"))
    let assistant = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let run: @Sendable (AgentToolCall, Bool) async -> AgentToolCallOutcome = { call, argumentsPrepared in
        await runToolCall(call, options: RunToolCallOptions(tools: [tool], assistantMessage: assistant,
            context: AgentContext(messages: [], tools: [tool]), argumentsPrepared: argumentsPrepared))
    }
    let used = LockedState<[Bool]>([])
    let runner = NestedToolCallRunner(host: NestedToolCallHost(getTools: { [tool] }, isSequential: { false },
        runToolCall: { call, _, _, _ in
            used.withLock { $0.append(false) }
            return await run(call, false)
        },
        emit: { _ in },
        runPreparedToolCall: { call, _, _, _ in
            used.withLock { $0.append(true) }
            return await run(call, true)
        }))
    let valid = await runner.execute(callerId: "outer", name: "read", args: ["path": AnyCodable("a")],
                                     options: ExecuteToolOptions(argumentsPrepared: true))
    #expect(!valid.isError)
    #expect(prepared.withLock { $0 } == 0)
    let invalid = await runner.execute(callerId: "outer", name: "read", args: [:],
                                       options: ExecuteToolOptions(argumentsPrepared: true))
    #expect(invalid.isError)
    _ = await runner.execute(callerId: "outer", name: "read", args: ["path": AnyCodable("a")])
    #expect(prepared.withLock { $0 } == 1)
    #expect(used.withLock { $0 } == [true, true, false])
}
