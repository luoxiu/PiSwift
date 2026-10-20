import Foundation
import PiSwiftAI
import PiSwiftChord

/// A tool result can add tools, end the run, or hand off to another agent.
public struct ToolControl: Sendable, Equatable, Codable {
    /// Tool names to add to the conversation offer policy.
    public var addTools: [String]?
    /// Whether the tool requests the current run to end.
    public var terminate: Bool?
    /// Optional text passed to the next agent or conversation boundary.
    public var handoff: String?
    /// Selects tool additions, run termination, or handoff text.
    public init(addTools: [String]? = nil, terminate: Bool? = nil, handoff: String? = nil) {
        self.addTools = addTools; self.terminate = terminate; self.handoff = handoff
    }
}
/// A tool report with a severity, message, and optional stable code.
public struct ToolDiagnostic: Sendable, Equatable, Codable {
    /// The level assigned to a tool diagnostic.
    public enum Severity: String, Sendable, Codable {
        /// Reports information without an execution failure.
        case info
        /// Reports a condition that can require attention.
        case warn
        /// Reports a tool execution error.
        case error
    }
    /// The level assigned to this tool diagnostic.
    public var severity: Severity
    /// Text that describes the error, diagnostic, or model response.
    public var message: String
    /// An optional stable identifier for the diagnostic.
    public var code: String?
    /// Pairs a diagnostic level and message with an optional stable code.
    public init(severity: Severity, message: String, code: String? = nil) {
        self.severity = severity; self.message = message; self.code = code
    }
}
/// What a tool returns, on three channels: `output` for the model, `structuredOutput` for programs that call the tool
/// (`executeTool()` callers, code mode scripts), and `details` for UIs.
public struct ToolExecutionResult: Sendable {
    /// For the model. Nil: the retained `output()` text.
    public var output: [ContentBlock]? { didSet { outputIdentity = UUID() } }
    internal var outputIdentity = UUID()
    /// For programs. Required unless `isError` when the tool declares `structuredOutputSchema`, and validated against it;
    /// not allowed without one, where programs get the output itself (`NestedToolExecutionResult.structuredOutput`).
    /// `.null` is a value; nil means absent.
    public var structuredOutput: JSONValue?
    /// Whether the tool content reports an execution failure.
    public var isError: Bool?
    /// Application-defined JSON details reported by a tool.
    public var details: JSONValue?
    /// The diagnostics reported by this tool call.
    public var diagnostics: [ToolDiagnostic]?
    /// The recorded model or tool token and cost totals.
    public var usage: Usage?
    /// Optional run control returned by the tool.
    public var control: ToolControl?
    /// Creates a tool result with optional output, structured output, details, diagnostics, usage, and control.
    public init(output: [ContentBlock]? = nil, structuredOutput: JSONValue? = nil, isError: Bool? = nil,
                details: JSONValue? = nil, diagnostics: [ToolDiagnostic]? = nil, usage: Usage? = nil,
                control: ToolControl? = nil) {
        self.output = output; self.structuredOutput = structuredOutput; self.isError = isError; self.details = details
        self.diagnostics = diagnostics; self.usage = usage; self.control = control
    }
}

/// Result of a nested call, as `executeTool()` returns it. Programs read `structuredOutput`; the output for the model
/// is not kept, and `control` does not apply.
public struct NestedToolExecutionResult: Sendable, Equatable, Codable {
    /// The nested call's tool task.
    public var taskId: TaskID
    /// The value for programs. A tool with `structuredOutputSchema`: its validated `structuredOutput`. A tool without, and
    /// an error result without `structuredOutput`: its bounded output, as a string for one text item, an `ImageContent`
    /// object for one image, `""` for none, and the content list otherwise. Absent on an error result the Harness wrote
    /// itself (unavailable, invalid, blocked, interrupted, aborted); `diagnostics` say what went wrong.
    public var structuredOutput: JSONValue?
    /// Whether the nested call ended with an error result.
    public var isError: Bool
    /// Application-defined JSON details reported by the nested tool.
    public var details: JSONValue?
    /// The diagnostics of the nested call's result.
    public var diagnostics: [ToolDiagnostic]
    /// The nested call's spend, already counted under its tool.
    public var usage: Usage?
    /// Execution time of the attempt that produced the result; absent when it never executed.
    public var durationMs: Int?
    /// Creates a nested call result.
    public init(taskId: TaskID, structuredOutput: JSONValue? = nil, isError: Bool, details: JSONValue? = nil,
                diagnostics: [ToolDiagnostic] = [], usage: Usage? = nil, durationMs: Int? = nil) {
        self.taskId = taskId; self.structuredOutput = structuredOutput; self.isError = isError; self.details = details
        self.diagnostics = diagnostics; self.usage = usage; self.durationMs = durationMs
    }
    /// Decodes this value from its durable JSON representation. An explicit null is a value.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        taskId = try recordRequired(object, "taskId")
        structuredOutput = object["structuredOutput"]
        isError = try recordRequired(object, "isError")
        details = object["details"]
        diagnostics = try recordRequired(object, "diagnostics")
        usage = try object["usage"].map(durableUsage)
        durationMs = try recordOptional(object, "durationMs")
    }
    /// Encodes this value with the durable JSON representation, in the upstream key order.
    public func encode(to encoder: any Encoder) throws {
        var object = JSONObject()
        try recordSet(&object, "taskId", taskId)
        if let structuredOutput { object["structuredOutput"] = structuredOutput }
        try recordSet(&object, "isError", isError)
        if let details { object["details"] = details }
        try recordSet(&object, "diagnostics", diagnostics)
        if let usage { object["usage"] = usageValue(usage) }
        try recordSetOptional(&object, "durationMs", durationMs)
        try object.encode(to: encoder)
    }
    /// Compares every field; usage compares its counters and costs.
    public static func == (lhs: NestedToolExecutionResult, rhs: NestedToolExecutionResult) -> Bool {
        lhs.taskId == rhs.taskId && lhs.structuredOutput == rhs.structuredOutput && lhs.isError == rhs.isError
            && lhs.details == rhs.details && lhs.diagnostics == rhs.diagnostics && lhs.durationMs == rhs.durationMs
            && lhs.usage.map(usageValue) == rhs.usage.map(usageValue)
    }
}

/// Options of one nested call.
public struct ExecuteToolOptions: Sendable {
    /// Names the call within its caller. Nil: the call's position among this invocation's nested calls, `1`, `2`, ...
    /// An explicit key must be non-empty, without `/`, not `__proto__`, and not a positive integer.
    public var key: String?
    /// `false` commits no running output, details, or diagnostics to the nested call's slot, only its status.
    public var progress: Bool?
    /// Selects an optional key and progress policy.
    public init(key: String? = nil, progress: Bool? = nil) { self.key = key; self.progress = progress }
}

/// The output retained so far, as the model will see it when the result omits `output`.
public struct RetainedToolOutput: Sendable, Equatable {
    /// The retained text.
    public var text: String
    /// Whether earlier output was dropped.
    public var truncated: Bool
    /// Pairs retained text with its truncation flag.
    public init(text: String, truncated: Bool) { self.text = text; self.truncated = truncated }
}

/// Who may call a tool: the model, or other tools through `executeTool()`.
public enum ToolCaller: String, Sendable, Codable {
    /// The model may call the tool.
    case model
    /// Tools may call the tool through `executeTool()`.
    case tools
}

/// Incremental tool output supplied as text or raw bytes.
public enum ToolOutputChunk: Sendable {
    /// Stores text output.
    case text(String)
    /// The byte limit removed output.
    case bytes(Data)
}

/// Tool operations bound to a task invocation.
public struct ToolExecutionApi: Sendable {
    internal var pendingDetailsCount: @Sendable () -> Int = { 0 }
    /// The optional task runtime bound to this tool invocation.
    public var runtime: TaskRuntime?
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The model-supplied identifier of the tool call.
    public var callId: String
    /// The installed extension and task definitions used by this harness.
    public var registry: RegistrySnapshot
    /// The agent configuration used for this conversation.
    public var agent: @Sendable (ChordContext) async throws -> Agent
    /// The model service used by this harness or task.
    public var models: any DurableModels
    /// The optional execution environment for the conversation.
    public var env: (any ExecutionEnv)?
    /// Document snapshot services available to this hook or renderer.
    public var read: HarnessDocumentReader
    /// Publishes incremental output from this tool invocation.
    public var output: @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void
    /// The requested output window passed to the environment.
    public var outputWindow: ShellOutputWindow?
    /// Publishes a tool diagnostic during execution.
    public var diagnostic: @Sendable (ToolDiagnostic) throws -> Void
    /// Application-defined JSON details reported by a tool.
    public var details: @Sendable (JSONValue, ChordContext) async throws -> Void
    /// A nil candidate reads; a supplied candidate installs only when no value exists.
    public var memo: @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?
    /// The output retained so far, as the model will see it when the result omits `output`, and whether earlier output
    /// was dropped; for a tool that also returns that text in its `structuredOutput`.
    public var retainedOutput: @Sendable () throws -> RetainedToolOutput
    /// Runs a nested call; see `executeTool(_:arguments:options:context:)`.
    internal var nestedCall: @Sendable (String, JSONObject, ExecuteToolOptions, ChordContext) async throws -> NestedToolExecutionResult = { _, _, _, _ in
        throw TaskDefinitionError("Tool execution API has no task runtime")
    }
    /// Whether the calling tool is replay-safe, so it reattaches to its child tasks after a restart.
    internal var resumes = true
    /// Binds tool services and publication callbacks to one task invocation.
    public init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime? = nil,
                agent: @escaping @Sendable (ChordContext) async throws -> Agent,
                output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void = { _, _ in },
                diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void = { _ in },
                details: @escaping @Sendable (JSONValue, ChordContext) async throws -> Void = { _, _ in },
                memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue? = { _, _, _ in nil },
                retainedOutput: @escaping @Sendable () throws -> RetainedToolOutput = { RetainedToolOutput(text: "", truncated: false) }) {
        self.runtime = runtime
        self.taskId = taskId; self.conversationId = conversationId; self.callId = callId; self.registry = registry
        self.models = models; self.env = env; self.read = read; self.outputWindow = outputWindow; self.agent = agent
        self.output = output; self.diagnostic = diagnostic; self.details = details; self.memo = memo
        self.retainedOutput = retainedOutput
    }
    internal init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                  models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                  outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime,
                  lifetime: ToolInvocationLifetime,
                  agent: @escaping @Sendable (ChordContext) async throws -> Agent,
                  output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void,
                  diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void,
                  details: @escaping @Sendable (JSONValue, ChordContext) async throws -> Void,
                  memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?,
                  retainedOutput: @escaping @Sendable () throws -> RetainedToolOutput,
                  nestedCall: @escaping @Sendable (String, JSONObject, ExecuteToolOptions, ChordContext) async throws -> NestedToolExecutionResult,
                  resumes: Bool) {
        let check: @Sendable () throws -> Void = {
            try runtime.invocation.check()
        }
        self.init(taskId: taskId, conversationId: conversationId, callId: callId, registry: registry,
                  models: models, env: env, read: toolBoundReader(read, check: check),
                  outputWindow: outputWindow, runtime: runtime,
                  agent: { context in try check(); return try await agent(context) },
                  output: { chunk, skipped in try lifetime.check(); try check(); try output(chunk, skipped) },
                  diagnostic: { value in try lifetime.check(); try check(); try diagnostic(value) },
                  details: { value, context in try lifetime.check(); try check(); try await details(value, context) },
                  memo: { name, candidate, context in try check(); return try await memo(name, candidate, context) },
                  retainedOutput: { try lifetime.check(); try check(); return try retainedOutput() })
        self.nestedCall = { name, arguments, options, context in
            try lifetime.check(); try check(); return try await nestedCall(name, arguments, options, context)
        }
        self.resumes = resumes
    }

}

/// A call as tool hooks see it; `parent` is set for a nested call, one a running tool made through `executeTool()`.
/// Members of the call (`id`, `name`, `arguments`) read through to it.
@dynamicMemberLookup
public struct ToolHookCall: Sendable {
    /// The calling tool task and call of a nested call.
    public struct Parent: Sendable, Equatable {
        /// The calling tool task.
        public var taskId: TaskID
        /// The calling tool call's ID.
        public var callId: String
        /// Names the calling task and call.
        public init(taskId: TaskID, callId: String) { self.taskId = taskId; self.callId = callId }
    }
    /// The tool call.
    public var call: ToolCall
    /// Set for a nested call.
    public var parent: Parent?
    /// Pairs a call with the call that made it, if any.
    public init(call: ToolCall, parent: Parent? = nil) { self.call = call; self.parent = parent }
    /// Reads a member of the tool call.
    public subscript<Value>(dynamicMember keyPath: KeyPath<ToolCall, Value>) -> Value { call[keyPath: keyPath] }
}

/// A tool declaration and execution callback with replay and output policies.
public struct ToolRegistration: Sendable {
    /// The model-facing tool name, description, and argument schema.
    public var declaration: AITool {
        didSet {
            orderedDeclaration["name"] = .string(declaration.name)
            orderedDeclaration["description"] = .string(declaration.description)
        }
    }
    /// Full declaration with the original JSON member order, including nested schema objects.
    public var orderedDeclaration: JSONObject
    /// An optional override of the tool replay policy.
    public var replay: ToolReplay?
    /// An optional per-tool execution policy.
    public var executionMode: ToolExecutionMode?
    /// An optional repair callback applied before tool argument validation.
    public var prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)?
    /// Optional per-tool limits for retained output.
    public var outputLimits: OutputLimitOverrides?
    /// Schema of `structuredOutput`, which programs that call the tool receive. Nil: they receive the result's bounded
    /// output, success or error, as `NestedToolExecutionResult.structuredOutput` describes.
    public var structuredOutputSchema: JSONObject?
    /// Who may call the tool: the model, other tools through `executeTool()`, or both (nil, the default). A code mode
    /// tool is `[.model]`, so scripts cannot start scripts; tools behind code mode, such as MCP tools, can be `[.tools]`,
    /// so the model is never offered them.
    public var callers: [ToolCaller]?
    /// The caller supplies repaired and validated arguments. defineTool also checks at the typed boundary.
    public var execute: @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
    /// The stable name used to resolve this definition in the registry.
    public var name: String { get { declaration.name } set { declaration.name = newValue; orderedDeclaration["name"] = .string(newValue) } }
    /// Text that describes this value or error to the caller.
    public var description: String { get { declaration.description } set { declaration.description = newValue; orderedDeclaration["description"] = .string(newValue) } }
    /// Updates the schema without losing its JSON member order.
    public mutating func setParameters(_ parameters: JSONObject) throws {
        let dictionary = try foundationJSON(from: .object(parameters)) as! [String: Any]
        declaration.parameters = dictionary.mapValues(AnyCodable.init)
        orderedDeclaration["parameters"] = .object(parameters)
    }
    /// Reflects direct AITool edits. Retained schema members keep their prior order.
    /// New members of a dictionary-only edit use the deterministic bridge order.
    public func currentOrderedDeclaration() throws -> JSONObject {
        let encoded = try DurableToolDeclaration(declaration).json
        guard case .object(let object) = mergeDeclarationOrder(old: .object(orderedDeclaration), new: .object(encoded)) else {
            preconditionFailure("The tool declaration is an object")
        }
        return object
    }
    /// Creates a tool declaration and its execution callback, preserving schema member order.
    public init(declaration: AITool, orderedDeclaration: JSONObject? = nil,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil, structuredOutputSchema: JSONObject? = nil,
                callers: [ToolCaller]? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult) throws {
        self.declaration = declaration
        self.orderedDeclaration = try orderedDeclaration ?? JSONObject([
            ("name", .string(declaration.name)), ("description", .string(declaration.description)),
            ("parameters", durableJSON(fromFoundation: declaration.parameters.mapValues(\.value)))])
        self.replay = replay; self.executionMode = executionMode; self.prepareArguments = prepareArguments
        self.outputLimits = outputLimits; self.structuredOutputSchema = structuredOutputSchema; self.callers = callers
        self.execute = execute
    }
    /// Creates a tool declaration and its execution callback, preserving schema member order.
    public init(name: String, description: String, parameters: JSONObject,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil, structuredOutputSchema: JSONObject? = nil,
                callers: [ToolCaller]? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult) throws {
        let dictionary = try foundationJSON(from: .object(parameters)) as! [String: Any]
        try self.init(declaration: AITool(name: name, description: description, parameters: dictionary.mapValues(AnyCodable.init)),
            orderedDeclaration: ["name": .string(name), "description": .string(description), "parameters": .object(parameters)],
            replay: replay, executionMode: executionMode, prepareArguments: prepareArguments,
            outputLimits: outputLimits, structuredOutputSchema: structuredOutputSchema, callers: callers, execute: execute)
    }
}

private func mergeDeclarationOrder(old: JSONValue, new: JSONValue) -> JSONValue {
    switch (old, new) {
    case let (.object(previous), .object(current)):
        var result = JSONObject()
        for (key, value) in previous {
            if let replacement = current[key] { result[key] = mergeDeclarationOrder(old: value, new: replacement) }
        }
        for (key, value) in current where previous[key] == nil { result[key] = value }
        return .object(result)
    case let (.array(previous), .array(current)):
        return .array(current.enumerated().map { index, value in
            index < previous.count ? mergeDeclarationOrder(old: previous[index], new: value) : value
        })
    default: return new
    }
}

/// Per-tool overrides merge with the harness output limits.
public struct OutputLimitOverrides: Sendable, Equatable {
    /// The maximum UTF-8 byte count to retain.
    public var maxBytes: Int?
    /// The maximum number of lines to retain.
    public var maxLines: Int?
    /// Which end of output remains when limits remove content.
    public var retain: OutputRetention?
    /// Selects per-tool byte, line, and retention overrides.
    public init(maxBytes: Int? = nil, maxLines: Int? = nil, retain: OutputRetention? = nil) {
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.retain = retain
    }
}

/// Creates a tool that validates its schema arguments before decoding them for execution.
public func defineTool<Args: Decodable & Sendable>(
    name: String, description: String, parameters: JSONObject, args: Args.Type = Args.self,
    replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
    prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
    outputLimits: OutputLimitOverrides? = nil, structuredOutputSchema: JSONObject? = nil,
    callers: [ToolCaller]? = nil,
    execute: @escaping @Sendable (Args, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    let schema = try foundationJSON(from: .object(parameters)) as! [String: Any]
    let declaration = AITool(name: name, description: description, parameters: schema.mapValues(AnyCodable.init))
    return try ToolRegistration(name: name, description: description, parameters: parameters,
        replay: replay, executionMode: executionMode, prepareArguments: prepareArguments,
        outputLimits: outputLimits, structuredOutputSchema: structuredOutputSchema, callers: callers) { value, api, context in
            guard let object = try foundationJSON(from: value) as? [String: Any] else {
                throw HarnessDefinitionError.argumentsMustBeObject(name)
            }
            let call = ToolCall(id: api.callId, name: name, arguments: object.mapValues(AnyCodable.init))
            let checked = try PiSwiftAI.validateToolArguments(tool: declaration, toolCall: call)
            let decoded = try JSONDecoder().decode(Args.self, from: JSONEncoder().encode(checked))
            return try await execute(decoded, api, context)
        }
}
