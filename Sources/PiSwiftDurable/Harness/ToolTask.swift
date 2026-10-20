import Foundation
import PiSwiftAI
import PiSwiftChord
import Synchronization

/// A model-issued call, read from its assistant entry, or a nested call a running tool made through `executeTool()`,
/// whose call the input carries because no entry holds it. JSON uses the upstream `kind` tag.
public enum ToolTaskInput: Sendable, Equatable, Codable {
    /// A call the model issued: tool call `callId` of the assistant entry.
    case model(assistant: EntryID, callId: String)
    /// A call a running tool made through `executeTool()`.
    case nested(NestedToolTaskInput)
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let kind: String = try recordRequired(object, "kind")
        switch kind {
        case "model": self = .model(assistant: try recordRequired(object, "assistant"), callId: try recordRequired(object, "callId"))
        case "nested": self = .nested(try JSONValue.object(object).decode(NestedToolTaskInput.self))
        default: throw recordUnknown("kind", kind)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = ["kind": .string(kind)]
        switch self {
        case let .model(assistant, callId): try recordSet(&object, "assistant", assistant); object["callId"] = .string(callId)
        case .nested(let nested):
            guard case .object(let fields) = try JSONValue(encoding: nested) else { preconditionFailure("A nested input is an object") }
            for (key, value) in fields { object[key] = value }
        }
        try object.encode(to: encoder)
    }
    /// The upstream `kind` tag.
    public var kind: String { if case .model = self { "model" } else { "nested" } }
}
/// The input of a nested call.
public struct NestedToolTaskInput: Sendable, Equatable, Codable {
    /// The calling tool task.
    public var parent: TaskID
    /// The calling tool call's ID.
    public var parentCallId: String
    /// The call's key within its caller.
    public var key: String
    /// The call, which no entry holds.
    public var call: NestedToolCall
    /// `false`: commit no running output, details, or diagnostics to the slot; the result still gets them. Only `false`
    /// is stored.
    public var progress: Bool?
    /// Creates a nested call input.
    public init(parent: TaskID, parentCallId: String, key: String, call: NestedToolCall, progress: Bool? = nil) {
        self.parent = parent; self.parentCallId = parentCallId; self.key = key; self.call = call; self.progress = progress
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        parent = try recordRequired(object, "parent"); parentCallId = try recordRequired(object, "parentCallId")
        key = try recordRequired(object, "key"); call = try recordRequired(object, "call")
        progress = try recordOptional(object, "progress")
    }
    /// Encodes this value in the upstream key order.
    public func encode(to encoder: any Encoder) throws {
        var object = JSONObject()
        try recordSet(&object, "parent", parent); try recordSet(&object, "parentCallId", parentCallId)
        try recordSet(&object, "key", key); try recordSet(&object, "call", call)
        try recordSetOptional(&object, "progress", progress)
        try object.encode(to: encoder)
    }
}
/// A nested call, stored as the pi-ai tool call JSON.
public struct NestedToolCall: Sendable, Equatable, Codable {
    /// `<parentCallId>/<key>`.
    public var id: String
    /// The called tool's name.
    public var name: String
    /// The arguments the call was made with.
    public var arguments: JSONObject
    /// Creates a nested call.
    public init(id: String, name: String, arguments: JSONObject) { self.id = id; self.name = name; self.arguments = arguments }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        id = try recordRequired(object, "id"); name = try recordRequired(object, "name")
        arguments = try recordRequired(object, "arguments")
    }
    /// Encodes this value as a pi-ai tool call.
    public func encode(to encoder: any Encoder) throws {
        try JSONObject([("type", .string("toolCall")), ("id", .string(id)), ("name", .string(name)),
                        ("arguments", .object(arguments))]).encode(to: encoder)
    }
    /// The pi-ai tool call.
    public func toolCall() throws -> ToolCall {
        let object = try foundationJSON(from: .object(arguments)) as! [String: Any]
        return ToolCall(id: id, name: name, arguments: object.mapValues(AnyCodable.init))
    }
}
/// The persisted prepare or execute phase of a tool task.
public struct ToolTaskCheckpoint: TaskCheckpoint {
    /// The persisted phase used to resume this built-in task.
    public enum Phase: String, Codable, Sendable {
        /// Executes the prepared tool or model request.
        case call
        /// Runs the prepared tool call.
        case execute
    }
    /// The saved prepare or execute phase.
    public var phase: Phase
    /// Replacement JSON arguments for the tool call.
    public var arguments: JSONObject?
    /// Whether this tool can execute again after a restart.
    public var replay: ToolReplay?
    /// Selects the saved tool phase, prepared arguments, and replay policy.
    public init(phase: Phase, arguments: JSONObject? = nil, replay: ToolReplay? = nil) {
        self.phase = phase; self.arguments = arguments; self.replay = replay
    }
}
/// A model-issued call's result is its transcript entry; a nested call's result is in its caller's `NestedCallDoc`,
/// so the receipt stays small and the result retires with the caller. A version 1 task that was already holding its
/// outcome as `completing` when the Harness upgraded finishes with a version 1 result, `{ entryId, control? }` without
/// `kind`; a result without `kind` decodes as a model-issued call's.
public enum ToolTaskResult: Sendable, Equatable, Codable {
    /// The result entry of a model-issued call and its optional run control.
    case model(entryId: EntryID, control: ToolControl? = nil)
    /// A nested call's receipt.
    case nested
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let kind: String? = try recordOptional(object, "kind")
        switch kind {
        case nil, "model": self = .model(entryId: try recordRequired(object, "entryId"), control: try recordOptional(object, "control"))
        case "nested": self = .nested
        case let kind?: throw recordUnknown("kind", kind)
        }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var object = JSONObject()
        switch self {
        case let .model(entryId, control):
            object["kind"] = .string("model"); try recordSet(&object, "entryId", entryId); try recordSetOptional(&object, "control", control)
        case .nested: object["kind"] = .string("nested")
        }
        try object.encode(to: encoder)
    }
    /// The result entry of a model-issued call.
    public var entryId: EntryID? { if case .model(let id, _) = self { id } else { nil } }
    /// The run control of a model-issued call.
    public var control: ToolControl? { if case .model(_, let control) = self { control } else { nil } }
}

/// Memo of a tool task that made a nested call, in any attempt, committed before the first admission of each attempt:
/// only then can `pi.live` hold slots below it, which settling removes. A crash between the two only costs a scan.
internal let madeNestedCallsMemo = "pi.tool.madeNestedCalls"

/// One nested call of a running tool: its task, and once it ended, its result.
public struct NestedCallState: Sendable, Equatable, Codable {
    /// Absent only inside the commit that creates the call; a creation that fails leaves no member.
    public var taskId: TaskID?
    /// Exactly what `executeTool()` returns; absent while running, and for a call the scheduler faulted or orphaned.
    public var result: NestedToolExecutionResult?
    /// Stores a nested call's task and result.
    public init(taskId: TaskID? = nil, result: NestedToolExecutionResult? = nil) { self.taskId = taskId; self.result = result }
}
/// The nested calls of a tool call, a task-scoped family of the calling task keyed by the nested call's key: so a rerun
/// finds the calls it already made, and the caller reads each result. Created with the nested task; the nested call's
/// terminal commit adds its result. One document per call, so no commit rewrites the others. Retires with the caller.
/// Upstream's seed is `null`; acquire a member with `seed: .null`.
public let NestedCallDoc = try! TaskDocFamilyToken<NestedCallState, JSONValue>(
    kind: "pi.tool.nested-call", version: 1, initial: { _ in NestedCallState() })

/// Built-in tool task: resolves the called tool among its phase agent's tools, validates, runs `beforeTool`, records
/// intent, executes, runs `afterTool`, and settles the result, all in one `call` handler so nothing separates resolution
/// from settlement. `execute` is reached only by recovery and applies the replay rule. A model-issued call settles by
/// appending its result entry; a nested call by writing its result to its caller's `NestedCallDoc`.
public let toolTask = TaskDefinition<ToolTaskInput, ToolTaskCheckpoint, ToolTaskResult, ToolHooks>(
    name: "pi.tool", version: 2, initial: { _ in ToolTaskCheckpoint(phase: .call) },
    phase: { task, runtime, context in try await runToolTask(task, runtime, context) },
    abort: { task, runtime, context in
        let call = try await readToolCall(runtime, task.input, context)
        // Abandoned after a restart (`TaskOptions.abandonOnRestart`): say whether the call may have run.
        let (code, message) = task.record.abortReason != .restart
            ? ("aborted", "Tool \(call.name) was aborted")
            : task.checkpoint.phase == .execute
                ? ("interrupted", "Tool \(call.name) was interrupted by a restart and may have partially run")
                : ("abandoned", "Tool \(call.name) was not started: its caller ended with a restart")
        try await settleTool(runtime, task.input, call, .aborted, context: context) { slot in
            toolResultFromSlot(slot, code: code, message: message)
        }
    },
    // Version 1 had only model-issued calls.
    migrate: { input, checkpoint, _ in
        guard let object = input.objectValue else { throw TaskDefinitionError("Tool task input must be an object") }
        let model = ToolTaskInput.model(assistant: try recordRequired(object, "assistant"), callId: try recordRequired(object, "callId"))
        return (model, try checkpoint.decode(ToolTaskCheckpoint.self))
    }
)
internal enum ToolEnding { case completed, failed(String), aborted }
/// The call: from the input for a nested call, which hooks see with its parent, else from the assistant entry.
private func readToolCall(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ context: ChordContext) async throws -> ToolHookCall {
    switch input {
    case .nested(let nested):
        context.telemetry.setAttributes(["tool.name": .string(nested.call.name), "tool.call_id": .string(nested.call.id)])
        return ToolHookCall(call: try nested.call.toolCall(), parent: .init(taskId: nested.parent, callId: nested.parentCallId))
    case let .model(assistant, callId):
        if let entry = try await runtime.entry(assistantEntry, id: assistant, context: context),
           case .assistant(let message) = try entry.record.messages()?.first {
            for block in message.content {
                if case .toolCall(let call) = block, harnessNamesEqual(call.id, callId) {
                    context.telemetry.setAttributes(["tool.name": .string(call.name), "tool.call_id": .string(call.id)])
                    return ToolHookCall(call: call)
                }
            }
        }
        throw TaskDefinitionError("Entry \(assistant.rawValue) has no tool call \(callId)")
    }
}
/// The called tool: among the tools the model is offered for a model-issued call, else among those tools may call.
private func resolveTool(_ runtime: TaskRuntime, _ input: ToolTaskInput, name: String,
                         context: ChordContext) async throws -> ToolRegistration? {
    let agent = try await runtime.agent(context: context)
    let tools: [ToolRegistration]
    if case .model = input { tools = agent.tools } else { tools = agent.callable }
    return tools.first { harnessNamesEqual($0.name, name) }
}
private func checkedToolArguments(_ tool: ToolRegistration, _ call: ToolCall, _ value: JSONValue) throws -> JSONObject {
    guard let object = try foundationJSON(from: value) as? [String: Any] else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    var candidate = call
    candidate.arguments = object.mapValues(AnyCodable.init); candidate.argumentsJSON = nil
    let checked = try validateToolArguments(tool: tool.declaration, toolCall: candidate)
    guard case .object(let arguments) = try durableJSON(fromFoundation: checked.mapValues(\.value)) else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    return arguments
}
private func runToolTask(_ task: RunningTask<ToolTaskInput, ToolTaskCheckpoint>, _ runtime: TaskRuntime,
                         _ context: ChordContext) async throws {
    let input = task.input
    let call = try await readToolCall(runtime, input, context)
    let tool = try await resolveTool(runtime, input, name: call.name, context: context)
    if task.checkpoint.phase == .execute {
        /// Recovery after intent: rerun only when the stored and the current policy both say `safe`.
        guard let args = task.checkpoint.arguments, let replay = task.checkpoint.replay else {
            throw TaskDefinitionError("Tool checkpoint is missing arguments or replay")
        }
        if replay == .safe, let tool, tool.replay == .safe {
            // The rerun reports from scratch; clear what the interrupted attempt published.
            try await runtime.commit({ tx, _ in
                if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
                    try clearProgress(slot: slot)
                }
                return nil
            }, context: context)
            return try await runTool(runtime, input, call, tool, args, context)
        }
        let message = "Tool \(call.name) was interrupted and may have partially run"
        // `failed` records cancellation intent, so the call's owned conversations, left unsupervised, are aborted.
        return try await settleTool(runtime, input, call, .failed(message), context: context) { toolResultFromSlot($0, code: "interrupted", message: message) }
    }
    guard let tool else {
        return try await settleTool(runtime, input, call, .completed, context: context) { _ in
            harnessToolError(code: "tool_unavailable", message: "Tool \(call.name) is not available")
        }
    }
    var args: JSONObject
    do {
        let original: JSONValue
        if case .nested(let nested) = input { original = .object(nested.call.arguments) }
        else { original = try durableJSON(fromFoundation: call.arguments.mapValues(\.value)) }
        args = try checkedToolArguments(tool, call.call, tool.prepareArguments?(original) ?? original)
    } catch {
        return try await settleTool(runtime, input, call, .completed, context: context) { _ in harnessToolError(code: "invalid_arguments", message: toolErrorText(error)) }
    }
    var block: String?
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        guard block == nil, let hook = hooks.beforeTool else { return }
        var candidate = call
        candidate.call.arguments = (try foundationJSON(from: .object(args)) as! [String: Any]).mapValues(AnyCodable.init)
        candidate.call.argumentsJSON = nil
        do {
            if let decision = try await hook(candidate, runtime.hookApi, context) {
                if let reason = decision.block { block = reason }
                else if let replacement = decision.arguments { args = replacement }
            }
        } catch {
            if runtime.signal.aborted || context.abortSignal?.aborted == true { throw error }
            block = toolErrorText(error)
        }
    }
    if let block {
        return try await settleTool(runtime, input, call, .completed, context: context) { _ in harnessToolError(code: "blocked", message: "Tool call blocked: \(block)") }
    }
    do { args = try checkedToolArguments(tool, call.call, .object(args)) }
    catch {
        return try await settleTool(runtime, input, call, .completed, context: context) { _ in harnessToolError(code: "invalid_arguments", message: toolErrorText(error)) }
    }
    let final = args
    try await runtime.commit({ tx, _ in
        if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
            try slot.set("status", .string("running"))
            // A nested slot shows the arguments the call runs with, which repair, hooks, and coercion may have changed.
            // Compared with the input, which the slot got at admission.
            if case .nested(let nested) = input, try isNestedSlot(slot),
               !jsonStructurallyEqual(.object(nested.call.arguments), .object(final)) {
                try slot.set("arguments", .object(final))
            }
        }
        return try toolTask.running(ToolTaskCheckpoint(phase: .execute, arguments: final, replay: tool.replay ?? .unsafe))
    }, context: context)
    try await runTool(runtime, input, call, tool, final, context)
}
internal func harnessToolError(code: String, message: String) -> ToolExecutionResult {
    ToolExecutionResult(output: [], isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: message, code: code)])
}
internal func toolTruncated(_ bytes: Int, _ lines: Int, retain: OutputRetention? = nil) -> ToolDiagnostic {
    let kept = retain.map { " to its \($0 == .head ? "beginning" : "end")" } ?? ""
    return ToolDiagnostic(severity: .warn, message: "Output truncated\(kept): \(lines) lines, \(bytes) bytes dropped", code: "truncated")
}
/// What a running tool call published, shared by model-issued and nested slots.
internal struct ToolSlotProgress: Sendable, Decodable {
    var output: String?
    var droppedBytes: Int?
    var droppedLines: Int?
    var details: JSONValue?
    var diagnostics: [ToolDiagnostic]?
    init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        output = try recordOptional(object, "output"); droppedBytes = try recordOptional(object, "droppedBytes")
        droppedLines = try recordOptional(object, "droppedLines"); details = object["details"]
        diagnostics = try recordOptional(object, "diagnostics")
    }
}
/// An error result from the slot's durable partial output, details, and diagnostics.
internal func toolResultFromSlot(_ slot: ToolSlotProgress?, code: String, message: String) -> ToolExecutionResult {
    var diagnostics = slot?.diagnostics ?? []
    if let bytes = slot?.droppedBytes, bytes > 0 { diagnostics.append(toolTruncated(bytes, slot?.droppedLines ?? 0)) }
    diagnostics.append(ToolDiagnostic(severity: .error, message: message, code: code))
    return ToolExecutionResult(output: slot?.output.flatMap { $0.isEmpty ? nil : [.text(TextContent(text: $0))] } ?? [],
                               isError: true, details: slot?.details, diagnostics: diagnostics)
}
/// Commit the tool's terminal state and mark its slot done. A model-issued call appends its result entry and ends with
/// the entry ID; a nested call writes its result to the caller's `NestedCallDoc`, records its usage, and ends with a
/// small receipt. Nested calls this call left running are aborted first, so they report into their slots before the
/// slots below the call leave `pi.live`. `build` receives the slot so interruption and abort can report the durable
/// partial output.
internal func settleTool(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall, _ ending: ToolEnding,
                         durationMs: Int? = nil, context: ChordContext,
                         build: (ToolSlotProgress?) throws -> ToolExecutionResult) async throws {
    // A crash in between leaves the call in `execute`: a safe rerun reattaches to the calls, an interruption ends here.
    // Every live nested call the task owns, also those an earlier attempt made and this one never called again.
    let nestedIds = try await runtime.ownedTasks(context: context).filter { record in
        guard record.kind == toolTask.name, case .nested? = try? record.input.decode(ToolTaskInput.self) else { return false }
        return true
    }.map(\.id)
    // Read before the settling commit: no admission starts after the lifetime ends, and those underway were awaited.
    let madeNested = try await runtime.memo(madeNestedCallsMemo, context: context) == .bool(true)
    // Mark them all before waiting for any: one may run until a sibling is cancelled.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for id in nestedIds { group.addTask { try await runtime.abortOwned(id, context: context) } }
        try await group.waitForAll()
    }
    try await runtime.commit({ tx, _ in
        let conversationId = runtime.conversationId
        let live = try await tx.doc(LiveDoc, conversationId: conversationId)
        let slot = try toolSlot(live: live, taskId: runtime.taskId)
        let result = try build(slot.map { try $0.snapshot().decode(ToolSlotProgress.self) })
        let settled: ToolTaskResult
        switch input {
        case .nested(let nested):
            let value = nestedToolResult(taskId: runtime.taskId, result: result, durationMs: durationMs)
            if let usage = value.usage {
                try await recordUsage(tx: tx, conversationId: conversationId, bucket: .tools, key: call.name, usage: usage)
            }
            // The caller is never terminal before its owned nested calls, so its document is open; another task in it is a
            // bug, not a race.
            let state = try await tx.doc(NestedCallDoc, taskId: nested.parent, key: nested.key, seed: .null)
            guard try state.get("taskId")?.decode(TaskID.self) == runtime.taskId else {
                throw TaskDefinitionError("Nested call \(call.id) is not in its caller's index")
            }
            try state.set("result", JSONValue(encoding: value))
            if let slot, try isNestedSlot(slot) {
                try finishSlot(slot: slot)
                try slot.set("summary", JSONValue(encoding: nestedToolSummary(value, output: result.output ?? [])))
            }
            settled = .nested
        case .model:
            let entry = try await appendToolResult(tx: tx, conversationId: conversationId, call: call.call,
                                                   result: result, timestamp: runtime.now(), durationMs: durationMs)
            if let slot, try !isNestedSlot(slot) {
                try finishSlot(slot: slot)
                try slot.set("entry", JSONValue(encoding: entry.id))
            }
            let control: ToolControl? = if case .completed = ending { result.control } else { nil }
            settled = .model(entryId: entry.id, control: control)
        }
        // A call that made no nested calls, in any attempt, has no slots below it; skipping the scan keeps many leaves
        // linear. Committed before the read: no nested call is admitted after the lifetime ends.
        if madeNested { try removeNestedSlots(live: live, taskId: runtime.taskId) }
        let value = try JSONValue(encoding: settled)
        switch ending {
        case .completed: return .terminal(outcome: .completed(result: value))
        case .aborted: return .terminal(outcome: .aborted(result: value))
        case .failed(let message): return .terminal(outcome: .failed(error: TaskOutcomeError(message: message), result: value))
        }
    }, context: context)
}
/// A nested call's result, as stored and returned: without `output`, which only the model reads, and without
/// `control`, which only model-issued calls apply.
private func nestedToolResult(taskId: TaskID, result: ToolExecutionResult, durationMs: Int?) -> NestedToolExecutionResult {
    NestedToolExecutionResult(taskId: taskId, structuredOutput: result.structuredOutput, isError: result.isError ?? false,
                              details: result.details, diagnostics: result.diagnostics ?? [], usage: result.usage,
                              durationMs: durationMs)
}
/// Create nested call `key` of the call `parentCallId` in one commit: its tool task, owned by the calling task, its slot,
/// and its `NestedCallDoc`. A key already made returns that call's task when it names the same tool and arguments.
internal func startNestedCall(_ runtime: TaskRuntime, parentCallId: String, name: String, arguments: JSONObject,
                              key: String, progress: Bool?, abandonOnRestart: Bool,
                              context: ChordContext) async throws -> TaskID {
    let call = NestedToolCall(id: "\(parentCallId)/\(key)", name: name, arguments: arguments)
    let replayed = Mutex(false)
    let id = try await withTaskCancellationContext(context) { context in
        try await runtime.scheduler.gated(runtime.invocation, context: context) { tx, _ in
            // Opened, or created empty for a key not made yet.
            let state = try await tx.doc(NestedCallDoc, taskId: runtime.taskId, key: key, seed: .null)
            if let existing = try state.get("taskId")?.decode(TaskID.self) {
                let input = try await tx.task(existing).map { try $0.input.decode(ToolTaskInput.self) }
                guard case .nested(let found)? = input, harnessNamesEqual(found.call.name, name),
                      jsonStructurallyEqual(.object(found.call.arguments), .object(call.arguments)) else {
                    throw TaskDefinitionError("Nested call \(call.id) was already made with another tool or other arguments")
                }
                let answered = try state.get("result") != nil
                replayed.withLock { $0 = answered }
                return existing
            }
            let input = ToolTaskInput.nested(NestedToolTaskInput(parent: runtime.taskId, parentCallId: parentCallId,
                                                                 key: key, call: call, progress: progress == false ? false : nil))
            let created = try await tx.createTask(toolTask, input: input, options: TaskOptions(
                ownership: .task(taskId: runtime.taskId), abandonOnRestart: abandonOnRestart))
            try state.set("taskId", JSONValue(encoding: created))
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            if try live.child("nestedTools") == nil { try live.set("nestedTools", .array([])) }
            try live.child("nestedTools")!.append(JSONValue(encoding: NestedToolSlot(
                callId: call.id, parentCallId: parentCallId, parentTaskId: runtime.taskId, name: name,
                taskId: created, arguments: call.arguments)))
            return created
        }
    }
    // Answered from its stored result, once committed.
    if replayed.withLock({ $0 }) { context.telemetry.addEvent("pi.durable.replay", attributes: ["tool.name": .string(name)]) }
    return id
}
/// What programs get of a tool's output when it declares no schema: one text item as its string, one image as itself,
/// nothing as `""`, and anything else as the content list.
internal func nestedOutputValue(_ output: [ContentBlock]) throws -> JSONValue {
    if output.isEmpty { return .string("") }
    if output.count == 1, case .text(let text) = output[0] { return .string(text.text) }
    let values = try output.map { try durableJSON(fromOrdered: contentBlockToOrderedJSON($0)) }
    return values.count == 1 ? values[0] : .array(values)
}
/// What the caller gets for a nested call without a stored result: one the scheduler faulted or orphaned.
internal func fallbackNestedResult(_ taskId: TaskID, name: String, outcome: TaskOutcome) -> NestedToolExecutionResult {
    let message: String
    switch outcome {
    case .faulted(let error, _): message = "Tool \(name) failed: \(error.message)"
    case .orphaned(let reason, _): message = "Tool \(name) could not resume: \(reason)"
    default: message = "Tool \(name) ended without a result"
    }
    let error = harnessToolError(code: outcome.status, message: message)
    return NestedToolExecutionResult(taskId: taskId, isError: true, diagnostics: error.diagnostics ?? [])
}
/// Explicit nested call keys are path segments of the call ID, so IDs of different nested calls never collide, and are
/// never plain positive integers, which default keys use. `__proto__` stays reserved, as it was when keys indexed a JSON
/// object.
internal func checkNestedKey(_ key: String) throws {
    let digits = key.utf8
    let positiveInteger = !digits.isEmpty && digits.first! >= 0x31 && digits.first! <= 0x39 && digits.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    if key.isEmpty || key.contains("/") || key == "__proto__" || positiveInteger {
        throw TaskDefinitionError("Nested call key \(try JSONValue.string(key).jsonText()) must be non-empty, without \"/\", not \"__proto__\", and not a positive integer")
    }
}
/// Error text a nested call's summary keeps.
private let maxSummaryErrorCharacters = 500
/// How a nested call ended, for its slot: error text, from its diagnostics or else its `output`, bounded to 500 UTF-16
/// code units.
private func nestedToolSummary(_ result: NestedToolExecutionResult, output: [ContentBlock]) -> NestedToolSummary {
    let text = result.isError ? nestedErrorText(result, output: output) : ""
    let error = String(decoding: Array(text.utf16.prefix(maxSummaryErrorCharacters)), as: UTF16.self)
    return NestedToolSummary(isError: result.isError, durationMs: result.durationMs, usage: result.usage,
                             error: error.isEmpty ? nil : error)
}
/// The error messages of a nested result, else the text items of its output, joined with newlines.
private func nestedErrorText(_ result: NestedToolExecutionResult, output: [ContentBlock]) -> String {
    let errors = result.diagnostics.filter { $0.severity == .error }
    if !errors.isEmpty { return errors.map(\.message).joined(separator: "\n") }
    return output.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined(separator: "\n")
}
/// Append a `pi.tool-result` entry. The content ends with the rendered diagnostics, so the stored message is exactly
/// what the model sees; `data` keeps the structured list. A result's usage is added to `pi.usage` in the same commit.
internal func appendToolResult(tx: Transaction, conversationId: ConversationID, call: ToolCall,
                             result: ToolExecutionResult, timestamp: Int64, durationMs: Int? = nil) async throws -> EntryRecord {
    let diagnostics = result.diagnostics ?? []
    var content = result.output ?? []
    if !diagnostics.isEmpty {
        content.append(.text(TextContent(text: "<harness>\n" + diagnostics.map { "[\($0.severity.rawValue)] \($0.message)" }.joined(separator: "\n") + "\n</harness>")))
    }
    let message = ToolResultMessage(toolCallId: call.id, toolName: call.name, content: content,
        details: try result.details.map { AnyCodable(try foundationJSON(from: $0)) }, usage: result.usage,
        isError: result.isError ?? false, timestamp: timestamp, durationMs: durationMs)
    if let usage = result.usage { try await recordUsage(tx: tx, conversationId: conversationId, bucket: .tools, key: call.name, usage: usage) }
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: toolResultEntry.kind,
        model: EntryRecord.encodeMessages([.toolResult(message)]), data: JSONValue(encoding: ToolResultEntryData(diagnostics: diagnostics))))
}

/// Use the Swift error's message without Foundation error bridging.
internal func toolErrorText(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError, let message = localized.errorDescription { return message }
    return String(describing: error)
}
