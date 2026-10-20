import PiSwiftAI
import PiSwiftChord

/// The reserved prompt section key for agent instructions.
public let instructionsKey = "instructions"

/// Stored extension names, either an exact selection or edits to the default selection.
public enum ExtensionSelection: Sendable, Equatable, Codable {
    /// Replaces the selection with precisely these names or definitions.
    case exact([String])
    /// Adds and removes names relative to the host defaults.
    case edit(add: [String]? = nil, remove: [String]? = nil)
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let names = try? single.decode([String].self) { self = .exact(names); return }
        let object = try decoder.container(keyedBy: Keys.self)
        self = .edit(add: try object.decodeIfPresent([String].self, forKey: .add),
                     remove: try object.decodeIfPresent([String].self, forKey: .remove))
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .exact(names): var c = encoder.singleValueContainer(); try c.encode(names)
        case let .edit(add, remove):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(add, forKey: .add); try c.encodeIfPresent(remove, forKey: .remove)
        }
    }
    private enum Keys: String, CodingKey { case add, remove }
}
/// Stored tool names, either an exact offer list or removals from extension tools.
public enum ToolSelection: Sendable, Equatable, Codable {
    /// Replaces the selection with precisely these names or definitions.
    case exact([String])
    /// Excludes these names or definitions from the default selection.
    case remove([String])
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let names = try? single.decode([String].self) { self = .exact(names); return }
        let object = try decoder.container(keyedBy: Keys.self)
        self = .remove(try object.decode([String].self, forKey: .remove))
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .exact(names): var c = encoder.singleValueContainer(); try c.encode(names)
        case let .remove(names): var c = encoder.container(keyedBy: Keys.self); try c.encode(names, forKey: .remove)
        }
    }
    private enum Keys: String, CodingKey { case remove }
}
/// Stored names of the tools the model is offered, either an exact offer list or edits to the enabled tools it may call.
public enum ModelToolSelection: Sendable, Equatable, Codable {
    /// Offers precisely these names, in order, deferred ones too.
    case exact([String])
    /// Offers every enabled tool the model may call except deferred ones and those in `remove`, in registry order,
    /// followed by the deferred tools in `add` that are not in `remove`, in `add` order.
    case edit(remove: [String]? = nil, add: [String]? = nil)
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let names = try? single.decode([String].self) { self = .exact(names); return }
        let object = try decoder.container(keyedBy: Keys.self)
        self = .edit(remove: try object.decodeIfPresent([String].self, forKey: .remove),
                     add: try object.decodeIfPresent([String].self, forKey: .add))
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .exact(names): var c = encoder.singleValueContainer(); try c.encode(names)
        case let .edit(remove, add):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(remove, forKey: .remove); try c.encodeIfPresent(add, forKey: .add)
        }
    }
    private enum Keys: String, CodingKey { case remove, add }
}

/// The pi.agent document value.
public struct AgentState: Sendable, Equatable, Codable {
    /// The stored provider and model reference or entry model contribution.
    public var model: ModelRef?
    /// The reasoning effort selected for the model.
    public var thinkingLevel: ModelThinkingLevel?
    /// The selected extensions or extension-selection change.
    public var extensions: ExtensionSelection?
    /// Filters the selected extensions' tools: the enabled tools. An exact list enables exactly these, in order.
    public var tools: ToolSelection?
    /// Filters the enabled tools the model may call (`callers` includes `model`): the tools offered to it. Never widens:
    /// other tools can still call the ones it leaves out.
    /// - Unset: every such tool except deferred ones.
    /// - An exact list: exactly these, in order, deferred ones too.
    /// - An edit: every such tool except deferred ones and those in `remove`, in registry order, followed by the
    ///   deferred tools in `add` that are not in `remove`, in `add` order. Names of tools that are not deferred or not
    ///   registered have no effect in `add`.
    public var modelTools: ModelToolSelection?
    /// Additional agent or compaction instructions.
    public var instructions: String?
    /// The working directory used by this conversation or command.
    public var cwd: String?
    /// Creates stored agent overrides. Absent fields use host defaults.
    public init(model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel? = nil,
                extensions: ExtensionSelection? = nil, tools: ToolSelection? = nil,
                modelTools: ModelToolSelection? = nil, instructions: String? = nil, cwd: String? = nil) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.modelTools = modelTools; self.instructions = instructions; self.cwd = cwd
    }
}

/// A fork uses the agent at its fork entry.
public let AgentDoc = try! RewindableConversationDocToken<AgentState>(
    kind: "pi.agent", version: 1, fork: .asOf, initial: { AgentState() },
    checkpointWhen: { _, _, _ in true }
)

/// Writes partial agent changes within the conversation transaction.
public func configure(tx: Transaction, conversationId: ConversationID, change: AgentChange) async throws {
    let draft = try await tx.doc(AgentDoc, conversationId: conversationId)
    var state = AgentState()
    applyAgentChange(&state, change)
    let value = try documentObject(state)
    try applyAgentField(draft, key: "model", change: change.model, value: value)
    try applyAgentField(draft, key: "thinkingLevel", change: change.thinkingLevel, value: value)
    try applyAgentField(draft, key: "extensions", change: change.extensions, value: value)
    try applyAgentField(draft, key: "tools", change: change.tools, value: value)
    try applyAgentField(draft, key: "modelTools", change: change.modelTools, value: value)
    try applyAgentField(draft, key: "instructions", change: change.instructions, value: value)
    try applyAgentField(draft, key: "cwd", change: change.cwd, value: value)
}

private func applyAgentField<Value>(_ draft: JSONDraft, key: String, change: AgentFieldChange<Value>, value: JSONObject) throws {
    switch change {
    case .unchanged: return
    case .clear: try draft.remove(key)
    case .set: if let next = value[key] { try draft.set(key, next) }
    }
}

/// A new task-owned conversation starts with its owner's stored agent.
public func createAgent(tx: Transaction, conversation: ConversationRecord) async throws {
    guard conversation.parent == nil else { return }
    let draft = try await tx.doc(AgentDoc, conversationId: conversation.id)
    guard let owner = conversation.owner else { return }
    let source = try await tx.doc(AgentDoc, conversationId: owner.conversationId)
    try assignAgentDocument(draft, value: source.snapshot().objectValue!)
}

func assignAgentDocument(_ draft: JSONDraft, value: JSONObject) throws {
    for key in try draft.keys() where value[key] == nil { try draft.remove(key) }
    for (key, item) in value { try draft.set(key, item) }
}

/// Source undefined leaves a field alone; null clears it; a value replaces it.
public enum AgentFieldChange<Value: Sendable>: Sendable {
    /// Leaves the stored value unchanged.
    case unchanged
    /// Removes the stored override so the default applies.
    case clear
    /// Replaces the stored field with the supplied value.
    case set(Value)
}
/// Replace the selected extensions or add and remove selected extension names.
public enum ExtensionChange: Sendable {
    /// Replaces the selection with precisely these names or definitions.
    case exact([Extension])
    /// Adds and removes names relative to the host defaults.
    case edit(add: [Extension]? = nil, remove: [Extension]? = nil)
}
/// Replace the enabled or offered tool list, or remove tools from it.
public enum ToolChange: Sendable {
    /// Replaces the selection with precisely these names or definitions.
    case exact([ToolRegistration])
    /// Excludes these names or definitions from the default selection.
    case remove([ToolRegistration])
}
/// Replace the offered tool list, or remove tools from it and load deferred ones.
public enum ModelToolChange: Sendable {
    /// Offers precisely these tools, in order, deferred ones too.
    case exact([ToolRegistration])
    /// Removes these tools from the offer and loads these deferred tools.
    case edit(remove: [ToolRegistration]? = nil, add: [ToolRegistration]? = nil)
}
/// A partial change to stored agent configuration. Clear restores the default for a field.
public struct AgentChange: Sendable {
    /// Whether to keep, clear, or replace the saved model reference.
    public var model: AgentFieldChange<ModelRef>
    /// Whether to keep, clear, or replace the saved model reasoning effort.
    public var thinkingLevel: AgentFieldChange<ModelThinkingLevel>
    /// Whether to keep, clear, replace, or edit the saved extension selection.
    public var extensions: AgentFieldChange<ExtensionChange>
    /// Whether to keep, clear, or replace the saved filter of enabled tools.
    public var tools: AgentFieldChange<ToolChange>
    /// Whether to keep, clear, or replace the saved filter of the enabled tools the model is offered. Replaces the stored
    /// filter as a whole; tools loaded with `control.addTools` are in its `add`.
    public var modelTools: AgentFieldChange<ModelToolChange>
    /// Whether to keep, clear, or replace the saved agent instructions.
    public var instructions: AgentFieldChange<String>
    /// Whether to keep, clear, or replace the saved working directory.
    public var cwd: AgentFieldChange<String>
    /// Selects the fields to keep, clear, or replace in stored agent configuration.
    public init(model: AgentFieldChange<ModelRef> = .unchanged, thinkingLevel: AgentFieldChange<ModelThinkingLevel> = .unchanged,
                extensions: AgentFieldChange<ExtensionChange> = .unchanged, tools: AgentFieldChange<ToolChange> = .unchanged,
                modelTools: AgentFieldChange<ModelToolChange> = .unchanged,
                instructions: AgentFieldChange<String> = .unchanged, cwd: AgentFieldChange<String> = .unchanged) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.modelTools = modelTools; self.instructions = instructions; self.cwd = cwd
    }
}

/// Applies only the changed fields to a stored agent value.
public func applyAgentChange(_ state: inout AgentState, _ change: AgentChange) {
    apply(&state.model, change.model); apply(&state.thinkingLevel, change.thinkingLevel)
    switch change.extensions {
    case .unchanged: break
    case .clear: state.extensions = nil
    case .set(.exact(let items)): state.extensions = .exact(items.map(\.name))
    case .set(.edit(let add, let remove)): state.extensions = .edit(add: add?.map(\.name), remove: remove?.map(\.name))
    }
    switch change.tools {
    case .unchanged: break
    case .clear: state.tools = nil
    case .set(.exact(let items)): state.tools = .exact(items.map(\.name))
    case .set(.remove(let items)): state.tools = .remove(items.map(\.name))
    }
    switch change.modelTools {
    case .unchanged: break
    case .clear: state.modelTools = nil
    case .set(.exact(let items)): state.modelTools = .exact(items.map(\.name))
    case .set(.edit(let remove, let add)): state.modelTools = .edit(remove: remove?.map(\.name), add: add?.map(\.name))
    }
    apply(&state.instructions, change.instructions); apply(&state.cwd, change.cwd)
}
private func apply<Value>(_ value: inout Value?, _ change: AgentFieldChange<Value>) {
    switch change { case .unchanged: break; case .clear: value = nil; case .set(let next): value = next }
}
/// `addTools` of a tool round, applied to `tools` and `modelTools`, so the next request offers the tools: an exact list
/// gets each name it lacks appended, and `remove` loses the names. An unset `tools` already enables every tool, so it
/// stays unset. An unset or edit `modelTools` also gets each name appended to its `add`, which loads deferred tools and
/// has no effect for others. By name, without the registry: a tool that is not registered now, such as one of an MCP
/// server that is reconnecting, is offered once it is again.
public func addAgentTools(_ state: inout AgentState, _ added: [String]) {
    switch state.tools {
    case nil: break
    case .exact(var names):
        for name in added where !names.contains(where: { harnessNamesEqual($0, name) }) { names.append(name) }
        state.tools = .exact(names)
    case .remove(let names):
        let removed = names.filter { name in !added.contains { harnessNamesEqual($0, name) } }
        if removed.count != names.count { state.tools = .remove(removed) }
    }
    if case .exact(var names) = state.modelTools {
        for name in added where !names.contains(where: { harnessNamesEqual($0, name) }) { names.append(name) }
        state.modelTools = .exact(names)
        return
    }
    let edit = loadedModelTools(state.modelTools, added)
    state.modelTools = .edit(remove: edit.remove, add: edit.add)
}
/// An unset or edit `modelTools` after loading `added`: the names leave `remove`, which is dropped once empty, and join
/// `add`, each once.
func loadedModelTools(_ filter: ModelToolSelection?, _ added: [String]) -> (remove: [String]?, add: [String]) {
    var remove: [String] = [], add: [String] = []
    if case .edit(let removed, let loaded) = filter { remove = removed ?? []; add = loaded ?? [] }
    remove = remove.filter { name in !added.contains { harnessNamesEqual($0, name) } }
    for name in added where !add.contains(where: { harnessNamesEqual($0, name) }) { add.append(name) }
    return (remove.isEmpty ? nil : remove, add)
}

/// Returns the hooks supplied by the selected extensions for this task, in extension order, with each one's extension.
public func agentHooks(_ agent: Agent, taskName: String) -> [(extension: String, hook: HookRegistration)] {
    agent.extensions.flatMap { item in
        item.hooks.filter { harnessNamesEqual($0.task, taskName) }.map { (extension: item.name, hook: $0) }
    }
}
/// Returns the hooks supplied by the selected extensions for this task.
public func agentHooks<Handlers: Sendable>(_ agent: Agent, taskName: String, as type: Handlers.Type) -> [Handlers] {
    agentHooks(agent, taskName: taskName).compactMap { $0.hook.handlers(as: type) }
}
/// The extension whose code a section of `agent` runs: the last selected one that provides or wraps it.
func sectionExtension(_ agent: Agent, key: String) -> String? {
    var found: String?
    for item in agent.extensions {
        let provides = item.sections.contains { harnessNamesEqual($0.key, key) }
        let wraps = item.wraps.contains { if case .section(let target, _) = $0 { return harnessNamesEqual(target, key) }; return false }
        if provides || wraps { found = item.name }
    }
    return found
}
/// The extension whose code a tool of `agent` runs: the last selected one that provides or wraps it.
func toolExtension(_ agent: Agent, name: String) -> String? {
    var found: String?
    for item in agent.extensions {
        let provides = item.tools.contains { harnessNamesEqual($0.name, name) }
        let wraps = item.wraps.contains { if case .tool(let target, _) = $0 { return harnessNamesEqual(target, name) }; return false }
        if provides || wraps { found = item.name }
    }
    return found
}

/// Resolves stored agent names against the current registry and host defaults. A wrapper that throws or renames drops
/// its target and is reported, with the name of the wrapper's extension.
public func resolveAgent(state: AgentState? = nil, snapshot: RegistrySnapshot, settings: Settings = resolveSettings(),
                         report: (any Error, String) -> Void = { _, _ in }) -> Agent {
    let selected: [String]
    switch state?.extensions {
    case .exact(let names): selected = names
    case .edit(let add, let remove):
        selected = ((settings.extensions ?? snapshot.installed()).map(\.name) + (add ?? [])).filter { name in
            !(remove ?? []).contains { harnessNamesEqual($0, name) }
        }
    case nil: selected = (settings.extensions ?? snapshot.installed()).map(\.name)
    }
    let extensions = uniqueHarnessNames(selected).compactMap { snapshot.extension(name: $0) }
    var tools: [ToolRegistration] = []
    var sections: [PromptSection] = []
    for extensionValue in extensions {
        for tool in extensionValue.tools {
            if let index = tools.firstIndex(where: { harnessNamesEqual($0.name, tool.name) }) { tools[index] = tool }
            else { tools.append(tool) }
        }
        for section in extensionValue.sections {
            if let index = sections.firstIndex(where: { harnessNamesEqual($0.key, section.key) }) { sections[index] = section }
            else { sections.append(section) }
        }
    }
    for extensionValue in extensions {
        for wrap in extensionValue.wraps {
            let wrapReport = { (error: any Error) in report(error, extensionValue.name) }
            switch wrap {
            case let .tool(name, transform):
                applyWrap(&tools, name: name, nameOf: { $0.name }, transform: transform, report: wrapReport)
            case let .section(key, transform):
                applyWrap(&sections, name: key, nameOf: { $0.key }, transform: transform, report: wrapReport)
            }
        }
    }
    let enabled = filterTools(tools, state?.tools)
    let callableBy = { (caller: ToolCaller) in { (tool: ToolRegistration) in tool.callers?.contains(caller) ?? true } }
    let modelCallable = enabled.filter(callableBy(.model))
    let offered = offeredTools(modelCallable, state?.modelTools)
    let deferred = modelCallable.filter { tool in
        tool.deferred == true && !offered.contains { harnessNamesEqual($0.name, tool.name) }
    }
    let callable = enabled.filter(callableBy(.tools))
    if let instructions = state?.instructions { sections.append(section(instructionsKey) { _, _ in instructions }) }
    return Agent(model: state?.model, thinkingLevel: state?.thinkingLevel ?? .off, extensions: extensions,
                 tools: offered, callable: callable, deferred: deferred, sections: sections,
                 instructions: state?.instructions, cwd: state?.cwd)
}

/// The tools offered to the model, as `AgentState.modelTools` describes.
private func offeredTools(_ tools: [ToolRegistration], _ filter: ModelToolSelection?) -> [ToolRegistration] {
    var remove: [String] = [], add: [String] = []
    switch filter {
    case .exact(let names): return filterTools(tools, .exact(names))
    case .edit(let removed, let loaded): remove = removed ?? []; add = loaded ?? []
    case nil: break
    }
    let removed = { (name: String) in remove.contains { harnessNamesEqual($0, name) } }
    let kept = tools.filter { tool in tool.deferred != true && !removed(tool.name) }
    // Loaded deferred tools follow in load order, so loading one appends to the declared tools.
    let loaded = uniqueHarnessNames(add).compactMap { name -> ToolRegistration? in
        guard let tool = tools.first(where: { harnessNamesEqual($0.name, name) }), tool.deferred == true, !removed(name) else { return nil }
        return tool
    }
    return kept + loaded
}

/// `tools` through a stored filter: an exact list selects exactly its names, in its order; `remove` drops names.
private func filterTools(_ tools: [ToolRegistration], _ filter: ToolSelection?) -> [ToolRegistration] {
    switch filter {
    case nil: tools
    case .exact(let names): uniqueHarnessNames(names).compactMap { name in tools.first { harnessNamesEqual($0.name, name) } }
    case .remove(let names): tools.filter { tool in !names.contains { harnessNamesEqual($0, tool.name) } }
    }
}

private func applyWrap<Value>(_ values: inout [Value], name: String, nameOf: (Value) -> String,
                              transform: (Value) throws -> Value, report: (any Error) -> Void) {
    guard let index = values.firstIndex(where: { harnessNamesEqual(nameOf($0), name) }) else { return }
    do {
        let changed = try transform(values[index])
        guard harnessNamesEqual(nameOf(changed), name) else { throw HarnessDefinitionError.renamedWrapper(target: name, name: nameOf(changed)) }
        values[index] = changed
    } catch { values.remove(at: index); report(error) }
}
func harnessNamesEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
private func uniqueHarnessNames(_ values: [String]) -> [String] {
    var seen = Set<[UInt16]>()
    return values.filter { seen.insert(Array($0.utf16)).inserted }
}
