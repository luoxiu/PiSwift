import PiSwiftAI
import PiSwiftChord

/// The active generation task and its admitted input submissions.
public struct LiveRun: Sendable, Equatable, Codable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The input submission IDs admitted to this generation.
    public var inputs: [SubmissionID]
    /// Records the active generation task and its admitted input submissions.
    public init(taskId: TaskID, inputs: [SubmissionID]) { self.taskId = taskId; self.inputs = inputs }
}
/// The scheduled retry time and last request error.
public struct LiveRetry: Sendable, Equatable, Codable {
    /// The inclusive history boundary or scheduled time for this value.
    public var at: Int64
    /// The saved error message or structured task failure.
    public var error: String
    /// Records the next retry time and last request error.
    public init(at: Int64, error: String) { self.at = at; self.error = error }
}
/// The next poll time for a deferred model request.
public struct LiveDeferred: Sendable, Equatable, Codable {
    /// The next deferred request poll time, in milliseconds.
    public var pollAt: Int64
    /// Records the next deferred-request poll time.
    public init(pollAt: Int64) { self.pollAt = pollAt }
}
/// The current attempt, partial response, and pending retry or deferred request.
public struct LiveGeneration: Sendable, Equatable, Codable {
    /// The current request attempt number.
    public var attempt: Int
    /// Text that describes the error, diagnostic, or model response.
    public var message: JSONObject?
    /// The current scheduled request retry, when present.
    public var retry: LiveRetry?
    /// The pending deferred response state, when present.
    public var deferred: LiveDeferred?
    /// Records the current request attempt and optional partial or retry state.
    public init(attempt: Int, message: JSONObject? = nil, retry: LiveRetry? = nil, deferred: LiveDeferred? = nil) {
        self.attempt = attempt; self.message = message; self.retry = retry; self.deferred = deferred
    }
}
/// The execution state and visible progress of one tool call.
public struct ToolSlot: Sendable, Equatable, Codable {
    /// The current execution state of a tool slot.
    public enum Status: String, Sendable, Codable {
        /// The tool call waits for execution.
        case pending
        /// The tool call is executing.
        case running
        /// The tool call has finished.
        case done
    }
    /// The model-supplied identifier of the tool call.
    public var callId: String
    /// The stable name used to resolve this definition in the registry.
    public var name: String
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID?
    /// The stored execution or submission state tag.
    public var status: Status
    /// The retained text output visible for this tool call.
    public var output: String?
    /// The number of UTF-8 bytes removed from the full output.
    public var droppedBytes: Int?
    /// The number of lines removed from the full output.
    public var droppedLines: Int?
    /// Application-defined JSON details reported by a tool.
    public var details: JSONValue?
    /// The diagnostics reported by this tool call.
    public var diagnostics: [ToolDiagnostic]?
    /// The entry created or selected by this operation.
    public var entry: EntryID?
    /// Records a tool call and its initial execution status.
    public init(callId: String, name: String, taskId: TaskID? = nil, status: Status = .pending, entry: EntryID? = nil) {
        self.callId = callId; self.name = name; self.taskId = taskId; self.status = status; self.entry = entry
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        callId = try recordRequired(object, "callId"); name = try recordRequired(object, "name")
        taskId = try recordOptional(object, "taskId"); status = try recordRequired(object, "status")
        output = try recordOptional(object, "output"); droppedBytes = try recordOptional(object, "droppedBytes")
        droppedLines = try recordOptional(object, "droppedLines")
        // An explicit null is a reported value. Absence means no details were reported.
        details = object["details"]
        diagnostics = try recordOptional(object, "diagnostics"); entry = try recordOptional(object, "entry")
    }
}
/// Presentation of one nested call: a call a running tool made through `executeTool()`. `callId` is
/// `<parentCallId>/<key>`, the call's ID in tool events and unique because keys contain no `/`. The Harness relates
/// slots by task ID: `taskId` is the call's tool task, `parentTaskId` the calling one, model-issued or nested.
public struct NestedToolSlot: Sendable, Equatable, Codable {
    /// `<parentCallId>/<key>`: the call's ID in tool events.
    public var callId: String
    /// The call ID of the calling tool call.
    public var parentCallId: String
    /// The calling tool task, model-issued or nested.
    public var parentTaskId: TaskID
    /// The stable name used to resolve this definition in the registry.
    public var name: String
    /// The nested call's tool task.
    public var taskId: TaskID
    /// What the call was made with, replaced by the arguments it runs with, after repair, `beforeTool`, and coercion,
    /// once it starts executing. A model-issued call's arguments are in its assistant entry instead.
    public var arguments: JSONObject
    /// The stored execution or submission state tag.
    public var status: ToolSlot.Status
    /// The retained text output visible for this tool call.
    public var output: String?
    /// The number of UTF-8 bytes removed from the full output.
    public var droppedBytes: Int?
    /// The number of lines removed from the full output.
    public var droppedLines: Int?
    /// Application-defined JSON details reported by a tool.
    public var details: JSONValue?
    /// The diagnostics reported by this tool call.
    public var diagnostics: [ToolDiagnostic]?
    /// Once done: how the call ended, for a status line. The result itself is in the caller's `NestedCallDoc`.
    public var summary: NestedToolSummary?
    /// Records a nested call and its initial execution status.
    public init(callId: String, parentCallId: String, parentTaskId: TaskID, name: String, taskId: TaskID,
                arguments: JSONObject, status: ToolSlot.Status = .pending, summary: NestedToolSummary? = nil) {
        self.callId = callId; self.parentCallId = parentCallId; self.parentTaskId = parentTaskId; self.name = name
        self.taskId = taskId; self.arguments = arguments; self.status = status; self.summary = summary
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        callId = try recordRequired(object, "callId"); parentCallId = try recordRequired(object, "parentCallId")
        parentTaskId = try recordRequired(object, "parentTaskId"); name = try recordRequired(object, "name")
        taskId = try recordRequired(object, "taskId"); arguments = try recordRequired(object, "arguments")
        status = try recordRequired(object, "status")
        output = try recordOptional(object, "output"); droppedBytes = try recordOptional(object, "droppedBytes")
        droppedLines = try recordOptional(object, "droppedLines")
        // An explicit null is a reported value. Absence means no details were reported.
        details = object["details"]
        diagnostics = try recordOptional(object, "diagnostics"); summary = try recordOptional(object, "summary")
    }
    /// Encodes this value in the upstream key order.
    public func encode(to encoder: any Encoder) throws {
        var object = JSONObject()
        try recordSet(&object, "callId", callId); try recordSet(&object, "parentCallId", parentCallId)
        try recordSet(&object, "parentTaskId", parentTaskId); try recordSet(&object, "name", name)
        try recordSet(&object, "taskId", taskId); object["arguments"] = .object(arguments)
        try recordSet(&object, "status", status)
        try recordSetOptional(&object, "output", output); try recordSetOptional(&object, "droppedBytes", droppedBytes)
        try recordSetOptional(&object, "droppedLines", droppedLines)
        if let details { object["details"] = details }
        try recordSetOptional(&object, "diagnostics", diagnostics); try recordSetOptional(&object, "summary", summary)
        try object.encode(to: encoder)
    }
}
/// How a nested call ended: an error flag, its execution time, its spend, and up to 500 characters of error text.
public struct NestedToolSummary: Sendable, Equatable, Codable {
    /// Whether the call ended with an error result.
    public var isError: Bool
    /// Execution time of the attempt that produced the result.
    public var durationMs: Int?
    /// The call's spend.
    public var usage: Usage?
    /// Up to 500 characters of error text.
    public var error: String?
    /// Records how a nested call ended.
    public init(isError: Bool, durationMs: Int? = nil, usage: Usage? = nil, error: String? = nil) {
        self.isError = isError; self.durationMs = durationMs; self.usage = usage; self.error = error
    }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        isError = try recordRequired(object, "isError"); durationMs = try recordOptional(object, "durationMs")
        usage = try object["usage"].map(durableUsage); error = try recordOptional(object, "error")
    }
    /// Encodes this value in the upstream key order.
    public func encode(to encoder: any Encoder) throws {
        var object = JSONObject()
        try recordSet(&object, "isError", isError); try recordSetOptional(&object, "durationMs", durationMs)
        if let usage { object["usage"] = usageValue(usage) }
        try recordSetOptional(&object, "error", error)
        try object.encode(to: encoder)
    }
    /// Compares every field; usage compares its counters and costs.
    public static func == (lhs: NestedToolSummary, rhs: NestedToolSummary) -> Bool {
        lhs.isError == rhs.isError && lhs.durationMs == rhs.durationMs && lhs.error == rhs.error
            && lhs.usage.map(usageValue) == rhs.usage.map(usageValue)
    }
}
/// Progress and retry state for one active compaction.
public struct CompactionStatus: Sendable, Equatable, Codable {
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The saved cause of cancellation, unanswered input, or compaction.
    public var reason: CompactionReason
    /// Whether the generation must wait for this compaction.
    public var blocking: Bool
    /// The current request attempt number.
    public var attempt: Int
    /// The current scheduled request retry, when present.
    public var retry: LiveRetry?
    /// Records an active compaction task, attempt, and optional retry.
    public init(taskId: TaskID, reason: CompactionReason, blocking: Bool, attempt: Int, retry: LiveRetry? = nil) {
        self.taskId = taskId; self.reason = reason; self.blocking = blocking; self.attempt = attempt; self.retry = retry
    }
}
/// The newest compaction that failed since a compaction last produced a summary.
public struct CompactionFailure: Sendable, Equatable, Codable {
    /// The failed compaction task.
    public var taskId: TaskID
    /// The saved cause of the compaction.
    public var reason: CompactionReason
    /// The failed or faulted outcome's error message, or why the scheduler orphaned the task.
    public var error: String
    /// Records a failed compaction task, its trigger, and its error.
    public init(taskId: TaskID, reason: CompactionReason, error: String) {
        self.taskId = taskId; self.reason = reason; self.error = error
    }
}
/// The active generation, tools, and compactions of one conversation.
public struct LiveState: Sendable, Equatable, Codable {
    /// The active generation task and the input submissions it admitted.
    public var run: LiveRun?
    /// The current partial model response and retry state.
    public var generation: LiveGeneration?
    /// The current tool round in call order, from the tool-calling answer until the generation's `tools` phase ends it.
    public var tools: [ToolSlot]?
    /// Nested calls of running tool calls, in creation order, so a parent precedes its children and task IDs ascend. A
    /// call's nested slots are removed when the call settles.
    public var nestedTools: [NestedToolSlot]?
    /// The active compaction tasks and their progress.
    public var compactions: [CompactionStatus]?
    /// The newest compaction failure, so a client can show it after the task ended. A compaction that produces a summary
    /// removes it; one that is aborted or finds nothing to compact leaves it.
    public var compactionFailure: CompactionFailure?
    /// Creates the visible state of active generation, tools, and compactions.
    public init(run: LiveRun? = nil, generation: LiveGeneration? = nil, tools: [ToolSlot]? = nil,
                nestedTools: [NestedToolSlot]? = nil, compactions: [CompactionStatus]? = nil,
                compactionFailure: CompactionFailure? = nil) {
        self.run = run; self.generation = generation; self.tools = tools; self.nestedTools = nestedTools
        self.compactions = compactions; self.compactionFailure = compactionFailure
    }
}
/// The typed token for the built-in live conversation document.
/// A complete base whenever nothing runs (spec section 8.2): no generation and no running tool or nested slot. A slot
/// holds output only while running, so every base is small; a nested call's result lives in its caller's task
/// documents, never here.
public let LiveDoc = try! ConversationDocToken<LiveState>(kind: "pi.live", version: 1, fork: .initial,
    initial: { LiveState() }, checkpointWhen: { value, _, _ in
        let running = { (key: String) in (value[key]?.arrayValue ?? []).contains { $0.objectValue?["status"] == .string("running") } }
        return value["generation"] == nil && !running("tools") && !running("nestedTools")
    })

/// End the run owned by `taskId`: settle each of its inputs and remove `run`. Always removes `generation`, `tools`, and
/// `nestedTools`, whose presentation belongs to the ending run.
internal func endRun(tx: Transaction, live: JSONDraft, taskId: TaskID, settlement: SubmissionSettlement) throws {
    if let run = try live.get("run")?.decode(LiveRun.self), run.taskId == taskId {
        for id in run.inputs { try tx.settleSubmission(id, settlement: settlement) }
        try live.remove("run")
    }
    try live.remove("generation"); try live.remove("tools"); try live.remove("nestedTools")
}
internal func startRun(tx: Transaction, conversationId: ConversationID, live: JSONDraft, inputs: [SubmissionID]) async throws {
    let id = try await createGeneration(tx: tx, conversationId: conversationId)
    try live.set("run", JSONValue(encoding: LiveRun(taskId: id, inputs: inputs)))
}
internal func handOver(live: JSONDraft, from: TaskID, to: TaskID) throws {
    guard let run = try live.child("run"), try run.get("taskId")?.decode(TaskID.self) == from else { return }
    try run.set("taskId", JSONValue(encoding: to))
}
/// The slot of tool task `taskId`, model-issued or nested, if `pi.live` still lists it. Nested slots are found by binary
/// search: a tool may make thousands of nested calls, each of which looks up its slot in several commits. Their task IDs
/// ascend: each slot is appended in the commit that creates its task, task IDs ascend in commit order, and removal keeps
/// the order.
internal func toolSlot(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    if let slots = try live.child("tools") {
        for index in 0..<(try slots.count()) {
            if let slot = try slots.child(index), try slot.get("taskId")?.decode(TaskID.self) == taskId { return slot }
        }
    }
    guard let nested = try live.child("nestedTools") else { return nil }
    var low = 0, high = try nested.count() - 1
    while low <= high {
        let middle = (low + high) / 2
        guard let candidate = try nested.child(middle), let id = try candidate.get("taskId")?.decode(TaskID.self) else { return nil }
        if id == taskId { return candidate }
        if id < taskId { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}
/// Whether a slot draft is a nested call's.
internal func isNestedSlot(_ slot: JSONDraft) throws -> Bool { try slot.get("parentTaskId") != nil }
/// Remove what a tool published while running; its result or a rerun replaces it.
internal func clearProgress(slot: JSONDraft) throws {
    for key in ["output", "droppedBytes", "droppedLines", "details", "diagnostics"] { try slot.remove(key) }
}
/// Mark a slot done and clear its running output; the caller sets a model-issued call's result `entry`, or a nested
/// call's `summary`. Neither is set when the task faulted or was orphaned.
internal func finishSlot(slot: JSONDraft) throws {
    try slot.set("status", .string("done"))
    try clearProgress(slot: slot)
}
/// Remove the nested slots below tool task `taskId`, transitively; the list holds parents before their children.
internal func removeNestedSlots(live: JSONDraft, taskId: TaskID) throws {
    guard let nested = try live.child("nestedTools") else { return }
    var removed: Set<TaskID> = [taskId]
    var parents: [TaskID?] = []
    for index in 0..<(try nested.count()) {
        let slot = try nested.get(index)?.objectValue
        let parent = try slot?["parentTaskId"]?.decode(TaskID.self)
        parents.append(parent)
        if let parent, removed.contains(parent), let id = try slot?["taskId"]?.decode(TaskID.self) { removed.insert(id) }
    }
    for index in parents.indices.reversed() where parents[index].map(removed.contains) == true {
        try nested.splice(index, deleteCount: 1)
    }
    if try nested.count() == 0 { try live.remove("nestedTools") }
}
internal func addCompactionStatus(live: JSONDraft, status: CompactionStatus) throws {
    if try live.child("compactions") == nil { try live.set("compactions", .array([])) }
    try live.child("compactions")!.append(JSONValue(encoding: status))
}
internal func compactionStatus(live: JSONDraft, taskId: TaskID) throws -> JSONDraft? {
    guard let statuses = try live.child("compactions") else { return nil }
    for index in 0..<(try statuses.count()) {
        if let status = try statuses.child(index), try status.get("taskId")?.decode(TaskID.self) == taskId { return status }
    }
    return nil
}
internal func removeCompactionStatus(live: JSONDraft, taskId: TaskID) throws {
    guard let statuses = try live.child("compactions") else { return }
    for index in 0..<(try statuses.count()) where try statuses.get(index)?.objectValue?["taskId"]?.decode(TaskID.self) == taskId {
        try statuses.splice(index, deleteCount: 1); break
    }
    if try statuses.count() == 0 { try live.remove("compactions") }
}
/// Remove the status of compaction task `taskId` and record that it failed with `error`.
internal func failCompactionStatus(live: JSONDraft, taskId: TaskID, error: String) throws {
    if let status = try compactionStatus(live: live, taskId: taskId)?.snapshot().decode(CompactionStatus.self) {
        try live.set("compactionFailure", JSONValue(encoding: CompactionFailure(taskId: status.taskId, reason: status.reason, error: error)))
    }
    try removeCompactionStatus(live: live, taskId: taskId)
}
/// Harness cleanup for a terminal outcome the scheduler writes itself (`faulted` or `orphaned`). A run task ends its
/// run; a tool task's slot is marked done without an entry; a compaction task's status is removed and its failure
/// recorded.
internal func settleSchedulerOutcome(tx: Transaction, record: TaskRecord, outcome: TaskOutcome) async throws {
    guard ["pi.generation", "pi.tool", "pi.compaction"].contains(record.kind) else { return }
    let live = try await tx.doc(LiveDoc, conversationId: record.conversationId)
    if record.kind == "pi.tool" {
        if let slot = try toolSlot(live: live, taskId: record.id) { try finishSlot(slot: slot) }
        try removeNestedSlots(live: live, taskId: record.id)
        return
    }
    if record.kind == "pi.compaction" {
        switch outcome {
        case .faulted(let error, _): try failCompactionStatus(live: live, taskId: record.id, error: error.message)
        case .orphaned(let reason, _): try failCompactionStatus(live: live, taskId: record.id, error: reason)
        default: try removeCompactionStatus(live: live, taskId: record.id)
        }
        return
    }
    guard try live.get("run")?.decode(LiveRun.self).taskId == record.id else { return }
    try await convertPartial(tx: tx, live: live, conversationId: record.conversationId)
    let settlement: SubmissionSettlement
    switch outcome {
    case .faulted(let error, _): settlement = .unanswered(reason: "faulted", detail: .string(error.message))
    case .orphaned(let reason, _): settlement = .unanswered(reason: reason)
    default: return
    }
    try endRun(tx: tx, live: live, taskId: record.id, settlement: settlement)
}
