import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// A tool over `{ text?: string }`: the upstream nested-tools `tool()` helper.
func nestedTool(_ name: String, replay: ToolReplay? = nil, callers: [ToolCaller]? = nil,
                structuredOutputSchema: JSONObject? = nil, outputLimits: OutputLimitOverrides? = nil,
                prepare: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                execute: @escaping @Sendable (JSONObject, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name,
        parameters: ["type": "object", "properties": ["text": ["type": "string"]]],
        replay: replay, prepareArguments: prepare, outputLimits: outputLimits,
        structuredOutputSchema: structuredOutputSchema, callers: callers) { args, api, context in
            try await execute(args.objectValue ?? [:], api, context)
        }
}
/// Installs tool hooks in an extension of their own.
func installToolHooks(_ setup: HarnessChatSetup, _ hooks: ToolHooks) throws {
    try setup.registry.install(Extension(name: "hooks:\(UUID().uuidString)", hooks: [hook(hooks)]))
}
/// A model response with one tool call.
func nestedCall(_ name: String, _ args: JSONObject = [:], id: String = "c1") throws -> AssistantMessage {
    try toolCalls([(name, args, id)])
}
/// A final model response.
let nestedDone = chatAssistant("done")
/// The value a schema-less nested call gives programs, as text.
func nestedText(_ result: NestedToolExecutionResult?) -> String { result?.structuredOutput?.stringValue ?? "" }
/// The diagnostic codes of a nested result.
func nestedCodes(_ result: NestedToolExecutionResult?) -> [String] { (result?.diagnostics ?? []).compactMap(\.code) }
/// Every `pi.tool` task, in creation order.
func nestedToolTasks(_ harness: Harness) async throws -> [TaskRecord] {
    try await harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items }, context: .background)
}
/// The nested `pi.tool` tasks, in creation order.
func nestedOnlyTasks(_ harness: Harness) async throws -> [TaskRecord] {
    try await nestedToolTasks(harness).filter { try nestedInput($0).kind == "nested" }
}
func nestedInput(_ record: TaskRecord) throws -> ToolTaskInput { try record.input.decode(ToolTaskInput.self) }
func nestedOutcome(_ record: TaskRecord?) -> TaskOutcome? { record?.state.outcome }
/// Runs one input over `responses` on a fresh memory Harness.
func runNestedOnce(_ setup: HarnessChatSetup, _ responses: [AssistantMessage]) async throws
    -> (harness: Harness, root: Conversation, status: String, entries: [EntryRecord]) {
    setup.models.setResponses(responses.map { .message($0) })
    let opened = try await openChat(setup: setup)
    let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
    return (opened.harness, opened.root, settled.status, try await allEntries(opened.root))
}
/// Waits for the context's abort and throws its reason, as the upstream `aborted(signal)`.
func nestedAborted(_ context: ChordContext) async throws -> ToolExecutionResult {
    try await harnessToolAwaitAbort(context)
    return .init()
}
/// Collects the event batches of a conversation from now on.
func nestedEvents(_ harness: Harness, _ conversation: ConversationID) async throws -> (watch: DurableAgentEventWatch, events: SessionTestLog<DurableAgentEvent>) {
    let events = SessionTestLog<DurableAgentEvent>()
    let watch = try await harness.watchEvents(conversationId: conversation, context: .background)
    try watch.start { batch, _ in for event in batch { events.append(event) } }
    return (watch, events)
}
/// The tool start and end events, as `[type, callId, parentCallId]`.
func nestedStartsAndEnds(_ events: [DurableAgentEvent]) -> [[String?]] {
    events.compactMap { event in
        switch event {
        case .toolExecutionStart(let call, _): ["tool_execution_start", call.toolCallId, call.parentToolCallId]
        case .toolExecutionEnd(let call, _, _): ["tool_execution_end", call.toolCallId, call.parentToolCallId]
        default: nil
        }
    }
}
/// The end event of call `callId`.
func nestedEnd(_ events: [DurableAgentEvent], _ callId: String) -> (call: DurableToolEventCall, entry: EntryRecord?, result: NestedToolExecutionResult?)? {
    for event in events {
        if case .toolExecutionEnd(let call, let entry, let result) = event, call.toolCallId == callId { return (call, entry, result) }
    }
    return nil
}
/// A fresh SQLite path in its own temporary directory.
func nestedSqlitePath() throws -> (path: String, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-nested-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory.appendingPathComponent("session.sqlite").path, directory)
}
/// Opens a SQLite-backed chat without starting scheduling.
func nestedOpenSqlite(_ path: String, _ setup: HarnessChatSetup) async throws -> OpenChatResult {
    try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
}

/// Nested results by name, collected by a probing tool.
final class NestedResults: Sendable {
    private let state = Mutex<[String: NestedToolExecutionResult]>([:])
    subscript(name: String) -> NestedToolExecutionResult? { state.withLock { $0[name] } }
    func set(_ name: String, _ result: NestedToolExecutionResult) { state.withLock { $0[name] = result } }
}
