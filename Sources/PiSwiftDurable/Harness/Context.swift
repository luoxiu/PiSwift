import PiSwiftAI
import PiSwiftChord

/// Raw active entries and their model contributions. Values do not share mutable state.
public struct ContextView: Sendable {
    /// The visible entry that sets the lower context bound, when present.
    public let head: EntryRecord?
    /// The active entries from the context head through its inclusive upper bound.
    public let entries: [EntryRecord]
    /// The model messages retained for each active entry after edits.
    public let contributions: [[Message]]
    /// The flattened model messages after entry edits and tool-result ordering, led by the first system message when
    /// only user messages precede it or it is the baseline's (see `findContextBaseline(head:entries:)`).
    public let messages: [Message]
    /// Raw contributions retain declaration member order at the AI boundary.
    let rawContributions: [JSONValue]?
    /// Creates a detached view of active entries and their model contributions.
    public init(head: EntryRecord? = nil, entries: [EntryRecord] = [], contributions: [[Message]] = [], messages: [Message] = [], rawContributions: [JSONValue]? = nil) {
        self.head = head; self.entries = entries; self.contributions = contributions; self.messages = messages; self.rawContributions = rawContributions
    }
}

/// Inclusive limits captured before a context scan. A head marker must have a head ID.
public struct ContextBounds: Sendable {
    /// The entry that defines the active model-context lower bound.
    public let head: EntryRecord?
    /// The inclusive upper entry boundary of this context.
    public let tail: EntryID
    /// Records the context head and inclusive upper entry boundary.
    public init(head: EntryRecord?, tail: EntryID) { self.head = head; self.tail = tail }
}

/// Derives context from visible entries in ascending ID order. No Session is required.
/// With `at`, only entries at or before that ID participate.
public func deriveContext(entries: [EntryRecord], at: EntryID? = nil) throws -> ContextView {
    let visible = entries.filter { at == nil || $0.id <= at! }
    guard let tail = visible.last?.id else { return ContextView() }
    let head = visible.last { $0.head != nil }
    return try deriveContext(bounds: ContextBounds(head: head, tail: tail), entries: visible)
}

/// Derives the range from captured bounds. Edits on older head markers still count.
public func deriveContext(bounds: ContextBounds?, entries: [EntryRecord]) throws -> ContextView {
    guard let bounds else { return ContextView() }
    return try deriveContextWithBaseline(bounds: bounds, entries: entries).view
}

/// `deriveContext(bounds:entries:)` with the baseline it found, which an extended read keeps.
internal func deriveContextWithBaseline(bounds: ContextBounds, entries: [EntryRecord]) throws -> (view: ContextView, baseline: ContextBaseline) {
    let range = entries.filter { $0.id <= bounds.tail && (bounds.head?.head == nil || $0.id >= bounds.head!.head!) }
    var edits: [EntryID: ContextEdit] = [:]
    for entry in range {
        for edit in entry.edits ?? [] {
            switch edit {
            case .omit(let target, _), .replace(let target, _, _): edits[target] = edit
            }
        }
    }
    let active = bounds.head.map { [$0] + range.filter { $0.head == nil } } ?? range
    var rawContributions: [JSONValue] = []
    let contributions = try active.map { entry -> [Message] in
        let raw: [JSONValue]?
        switch edits[entry.id] {
        case .omit?: return []
        case .replace(_, let messages, _)?: raw = messages
        case nil: raw = entry.model
        }
        rawContributions.append(contentsOf: raw ?? [])
        let typed = try EntryRecord(id: entry.id, conversationId: entry.conversationId, kind: entry.kind, model: raw).messages() ?? []
        return typed.filter { message in
            guard case .assistant(let answer) = message else { return true }
            return ![StopReason.aborted, .error, .deferred].contains(answer.stopReason)
        }
    }
    let baseline = findContextBaseline(head: bounds.head, entries: active)
    let leads = baselineLeads(baseline, entries: active, contributions: contributions) { edits[$0] != nil }
    let messages = leadContextWithSystem(orderToolResults(contributions.flatMap { $0 }), baselineLeads: leads)
    return (ContextView(head: bounds.head, entries: active, contributions: contributions, messages: messages, rawContributions: rawContributions), baseline)
}

/// The baseline's `pi.system` entry; `none` when the range cannot have one, or `pending` while a later entry may be one.
internal enum ContextBaseline: Sendable, Equatable {
    case entry(EntryID)
    case none
    case pending
}

/// The baseline among `entries`, oldest first: the first `pi.system` entry after the head marker, or of the transcript
/// without one, when generation wrote it with every section and tool in effect. After a head marker it always does, and
/// omits the retained `pi.system` entries. Without one it does when it saw no system message before, which holds unless
/// an earlier entry carries one, even if an edit omits it later. An edit that targets the baseline contributes other
/// messages, or none, so none leads; a later entry does not take its place. A `pi.system` entry without a system
/// message is no baseline.
internal func findContextBaseline(head: EntryRecord?, entries: [EntryRecord]) -> ContextBaseline {
    for entry in entries {
        if let head, entry.id <= head.id { continue }
        if systemEntry.matches(entry) { return entry.model?.contains(where: isSystemMessage) == true ? .entry(entry.id) : .none }
        if head == nil && carriesSystemMessage(entry) { return .none }
    }
    return .pending
}

private func isSystemMessage(_ message: JSONValue) -> Bool { message["role"] == .string("system") }

/// Whether an entry's own messages, or the replacement messages of its edits, include a system message.
private func carriesSystemMessage(_ entry: EntryRecord) -> Bool {
    if entry.model?.contains(where: isSystemMessage) == true { return true }
    return (entry.edits ?? []).contains { edit in
        if case .replace(_, let messages, _) = edit { return messages.contains(where: isSystemMessage) }
        return false
    }
}

/// Whether the first system message of `contributions` is the baseline's: the baseline entry contributes it, unedited.
/// Upstream compares the message object with the baseline entry's; Swift messages are values, so the entry stands in.
/// Tool result ordering keeps the order of the other messages, so the first system message stays the first.
internal func baselineLeads(_ baseline: ContextBaseline, entries: [EntryRecord], contributions: [[Message]],
                            edited: (EntryID) -> Bool) -> Bool {
    guard case .entry(let id) = baseline, !edited(id) else { return false }
    for (entry, messages) in zip(entries, contributions) where messages.contains(where: { $0.role == "system" }) {
        return entry.id == id
    }
    return false
}

/// Move the first system message to the front when only user messages precede it, or when it is the baseline's. A
/// run's input is committed before generation renders the system prompt, so a transcript starts with the input followed
/// by the baseline, and the range after a compaction with the kept history, assistant messages included. Providers
/// treat only a leading system message as the initial prompt and tool set; without it, a later tool change rewrites
/// the request's tool list and invalidates the whole prompt cache. Only the first system message moves, so replaying
/// system messages in order gives the same sections and tools. Any other system message, before an assistant message,
/// stays where it was committed: moving it would change what it means to the model.
internal func leadContextWithSystem(_ messages: [Message], baselineLeads: Bool) -> [Message] {
    guard let index = messages.firstIndex(where: { $0.role == "system" }), index > 0 else { return messages }
    if !baselineLeads && messages[..<index].contains(where: { $0.role != "user" }) { return messages }
    var messages = messages
    messages.insert(messages.remove(at: index), at: 0)
    return messages
}

/// Places results directly after their assistant, in call order. First result wins.
/// Unmatched results are omitted. Missing results are model-visible error messages.
public func orderToolResults(_ messages: [Message]) -> [Message] {
    var ordered: [Message] = []
    for (index, message) in messages.enumerated() {
        if case .toolResult = message { continue }
        ordered.append(message)
        guard case .assistant(let assistant) = message else { continue }
        let calls = assistant.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }; return nil
        }
        guard !calls.isEmpty else { continue }
        var results: [[UInt16]: ToolResultMessage] = [:]
        for candidate in messages.dropFirst(index + 1) {
            if case .assistant = candidate { break }
            if case .toolResult(let result) = candidate, results[Array(result.toolCallId.utf16)] == nil { results[Array(result.toolCallId.utf16)] = result }
        }
        for call in calls {
            ordered.append(.toolResult(results[Array(call.id.utf16)] ?? ToolResultMessage(
                toolCallId: call.id, toolName: call.name,
                content: [.text(TextContent(text: "Tool result unavailable: history ends before this call completed."))],
                details: AnyCodable(["reason": "missing_result"]), isError: true, timestamp: assistant.timestamp)))
        }
    }
    return ordered
}
