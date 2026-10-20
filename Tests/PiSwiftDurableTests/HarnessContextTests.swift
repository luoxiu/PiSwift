import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

private func contextUser(_ text: String) -> Message { .user(UserMessage(content: .text(text), timestamp: 1)) }
private func contextSystem(_ key: String) -> Message { .system(SystemMessage(content: .text(""), sections: .init([(key, key)]), timestamp: 1)) }
private func contextAssistant(_ text: String, reason: StopReason = .stop, calls: [String] = []) -> Message {
    .assistant(AssistantMessage(content: [.text(TextContent(text: text))] + calls.map { .toolCall(ToolCall(id: $0, name: "tool-\($0)", arguments: [:])) }, api: .openAIResponses, provider: "faux", model: "faux", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason, timestamp: 1))
}
private func contextResult(_ id: String) -> Message { .toolResult(ToolResultMessage(toolCallId: id, toolName: "tool-\(id)", content: [.text(TextContent(text: "result \(id)"))], isError: false, timestamp: 1)) }
private func contextDescription(_ message: Message) -> String {
    switch message {
    case .user(let user): if case .text(let text) = user.content { return "user:\(text)" }; return "user"
    case .assistant(let assistant): return "assistant:\(assistant.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined())"
    case .system(let system): return "system:\(system.sections?.entries.map(\.name).joined(separator: ",") ?? "")"
    case .toolResult(let result): return "result:\(result.toolCallId):\(result.isError ? "error" : "result \(result.toolCallId)")"
    }
}
private struct ContextTranscript {
    var entries: [EntryRecord] = []
    mutating func append(_ message: Message? = nil, kind: String = "message", head: Int64? = nil, edits: [ContextEdit]? = nil) throws -> EntryRecord {
        let record = try EntryRecord.withMessages(id: EntryID(Int64(entries.count + 1)), conversationId: rootConversationID,
                                                  kind: kind, messages: message.map { [$0] } ?? [], head: head.map { try EntryID($0) }, edits: edits)
        entries.append(record); return record
    }
    func view(at: EntryID? = nil) throws -> ContextView { try deriveContext(entries: entries, at: at) }
}

@Suite struct HarnessContextTests {
    @Test("returns the whole transcript without a head and excludes model-less entries from messages")
    func whole() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("hi")); _ = try transcript.append(kind: "note"); _ = try transcript.append(contextAssistant("hello"))
        let view = try transcript.view()
        #expect(view.head == nil); #expect(view.entries.count == 3)
        #expect(view.messages.map(contextDescription) == ["user:hi", "assistant:hello"])
    }
    @Test("excludes aborted, error, and deferred assistant messages but keeps their raw entries")
    func excluded() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("q"))
        for reason in [StopReason.aborted, .error, .deferred] { _ = try transcript.append(contextAssistant("partial", reason: reason)) }
        _ = try transcript.append(contextAssistant("done", reason: .length))
        #expect(try transcript.view().entries.count == 5)
        #expect(try transcript.view().messages.map(contextDescription) == ["user:q", "assistant:done"])
    }
    @Test("resolves self heads and uses the newest head marker")
    func heads() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("old"))
        let reset = try transcript.append(contextUser("fresh start"), kind: "pi.reset", head: 2)
        let after = try transcript.append(contextAssistant("after reset"))
        #expect(try transcript.view().entries.map(\.id) == [reset.id, after.id])
        let summary = try transcript.append(contextUser("summary"), kind: "pi.compaction", head: after.id.rawValue)
        let tail = try transcript.append(contextUser("next"))
        let view = try transcript.view()
        #expect(view.head?.id == summary.id)
        #expect(view.entries.map(\.id) == [summary.id, after.id, tail.id])
        #expect(view.messages.map(contextDescription) == ["user:summary", "assistant:after reset", "user:next"])
    }
    @Test("applies the newest edit per target within the active range")
    func edits() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first")), second = try transcript.append(contextUser("second"))
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v2")]))])
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v3")]))])
        _ = try transcript.append(kind: "edit", edits: [.omit(target: second.id)])
        #expect(try transcript.view().messages.map(contextDescription) == ["user:first v3"])
        _ = try transcript.append(kind: "reset", head: second.id.rawValue)
        #expect(try transcript.view().messages.isEmpty)
        _ = try transcript.append(kind: "edit", edits: [.replace(target: second.id, messages: EntryRecord.encodeMessages([contextUser("second v2")]))])
        #expect(try transcript.view().messages.map(contextDescription) == ["user:second v2"])
    }
    @Test("keeps positional system messages and orders tool results by call order")
    func results() throws {
        var transcript = ContextTranscript()
        for message in [contextSystem("preamble"), contextUser("run tools"), contextAssistant("calling", calls: ["b","a"]), contextResult("a"), contextSystem("cwd"), contextResult("b"), contextResult("zz"), contextAssistant("done")] { _ = try transcript.append(message) }
        #expect(try transcript.view().messages.map(contextDescription) == ["system:preamble", "user:run tools", "assistant:calling", "result:b:result b", "result:a:result a", "system:cwd", "assistant:done"])
    }
    @Test("leads with a system message that only user messages precede, and keeps later ones in place")
    func leading() throws {
        var transcript = ContextTranscript()
        for message in [contextUser("first"), contextUser("steered"), contextSystem("preamble"), contextAssistant("answer"), contextUser("next"), contextSystem("cwd")] { _ = try transcript.append(message) }
        let view = try transcript.view()
        #expect(view.messages.map(contextDescription) == ["system:preamble", "user:first", "user:steered", "assistant:answer", "user:next", "system:cwd"])
        #expect(view.contributions.flatMap { $0 }.prefix(3).map(contextDescription) == ["user:first", "user:steered", "system:preamble"])
        _ = try transcript.append(contextUser("handoff"), kind: "reset", head: 7)
        _ = try transcript.append(contextSystem("preamble"))
        #expect(try transcript.view().messages.map(contextDescription) == ["system:preamble", "user:handoff"])
    }
    // #10904
    @Test("leads with the baseline after a compaction that keeps assistant messages")
    func baselineAfterCompaction() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("old"))
        let kept = try transcript.append(contextUser("kept"))
        _ = try transcript.append(contextAssistant("calling", calls: ["a"])); _ = try transcript.append(contextResult("a"))
        _ = try transcript.append(contextAssistant("answer"))
        _ = try transcript.append(contextUser("summary"), kind: "summary", head: kept.id.rawValue)
        _ = try transcript.append(contextUser("next"))
        _ = try transcript.append(contextSystem("preamble"), kind: "pi.system")
        #expect(try transcript.view().messages.map(contextDescription) == [
            "system:preamble", "user:summary", "user:kept", "assistant:calling", "result:a:result a", "assistant:answer", "user:next",
        ])
        // Later system messages stay in place.
        _ = try transcript.append(contextAssistant("done")); _ = try transcript.append(contextSystem("cwd"), kind: "pi.system")
        let messages = try transcript.view().messages.map(contextDescription)
        #expect(Array(messages.prefix(2)) == ["system:preamble", "user:summary"])
        #expect(Array(messages.suffix(2)) == ["assistant:done", "system:cwd"])
    }
    // #10904
    @Test("leads with a baseline written after the first answers, when the agent had no section or tool before")
    func baselineAfterFirstAnswers() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("first"), kind: "pi.user"); _ = try transcript.append(contextAssistant("answer"), kind: "pi.assistant")
        _ = try transcript.append(contextUser("next"), kind: "pi.user"); _ = try transcript.append(contextSystem("plan"), kind: "pi.system")
        #expect(try transcript.view().messages.map(contextDescription) == ["system:plan", "user:first", "assistant:answer", "user:next"])
    }
    // #10904
    @Test("keeps system messages other than the baseline in place once an assistant message precedes them")
    func otherSystemMessagesStay() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("first")); _ = try transcript.append(contextAssistant("answer"))
        // Another kind's system message is positional; the baseline after it is not the first system message.
        _ = try transcript.append(contextSystem("note"), kind: "host.note"); _ = try transcript.append(contextSystem("preamble"), kind: "pi.system")
        #expect(try transcript.view().messages.map(contextDescription) == ["user:first", "assistant:answer", "system:note", "system:preamble"])
        // After a compaction that keeps the other kind's system message, the new baseline does not move ahead of it.
        let kept = try transcript.append(contextUser("kept"))
        _ = try transcript.append(contextAssistant("kept answer")); _ = try transcript.append(contextSystem("mode"), kind: "host.note")
        _ = try transcript.append(contextUser("summary"), kind: "summary", head: kept.id.rawValue)
        _ = try transcript.append(contextUser("next")); _ = try transcript.append(contextSystem("preamble"), kind: "pi.system")
        #expect(try transcript.view().messages.map(contextDescription) == [
            "user:summary", "user:kept", "assistant:kept answer", "system:mode", "user:next", "system:preamble",
        ])
    }
    // #10904
    @Test("does not lead with a first system entry written after another system message, even once that is omitted")
    func earlierSystemMessageRulesOutBaseline() throws {
        var transcript = ContextTranscript()
        let host = try transcript.append(contextSystem("legacy"), kind: "host.system")
        _ = try transcript.append(contextUser("first")); _ = try transcript.append(contextAssistant("answer"))
        // Generation wrote this entry against the host's message: it only removes a section, so it is no baseline.
        _ = try transcript.append(contextSystem("legacy"), kind: "pi.system")
        _ = try transcript.append(kind: "edit", edits: [.omit(target: host.id)])
        #expect(try transcript.view().messages.map(contextDescription) == ["user:first", "assistant:answer", "system:legacy"])
        // The same holds for a system message an edit put before it.
        var other = ContextTranscript()
        let first = try other.append(contextUser("first"))
        _ = try other.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first"), contextSystem("note")]))])
        _ = try other.append(contextAssistant("answer")); _ = try other.append(contextSystem("note"), kind: "pi.system")
        _ = try other.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first")]))])
        #expect(try other.view().messages.map(contextDescription) == ["user:first", "assistant:answer", "system:note"])
    }
    // #10904
    @Test("does not lead with a retained, edited, or later system entry in place of the baseline")
    func retainedEditedOrLaterSystemEntries() throws {
        var transcript = ContextTranscript()
        let kept = try transcript.append(contextUser("kept"))
        _ = try transcript.append(contextAssistant("answer"))
        let retained = try transcript.append(contextSystem("cwd"), kind: "pi.system")
        // Before generation writes the baseline after the head marker, a retained system entry stays in place.
        _ = try transcript.append(contextUser("summary"), kind: "summary", head: kept.id.rawValue)
        _ = try transcript.append(contextUser("next"))
        #expect(try transcript.view().messages.map(contextDescription) == ["user:summary", "user:kept", "assistant:answer", "system:cwd", "user:next"])
        // The baseline omits the retained entry, as generation writes it, and leads.
        let baseline = try transcript.append(contextSystem("preamble"), kind: "pi.system", edits: [.omit(target: retained.id)])
        _ = try transcript.append(contextAssistant("done")); _ = try transcript.append(contextSystem("preamble"), kind: "pi.system")
        #expect(try transcript.view().messages.map(contextDescription) == [
            "system:preamble", "user:summary", "user:kept", "assistant:answer", "user:next", "assistant:done", "system:preamble",
        ])
        // An omitted baseline leaves no message to lead; the delta after it is not a baseline and stays in place.
        _ = try transcript.append(kind: "edit", edits: [.omit(target: baseline.id)])
        #expect(try transcript.view().messages.map(contextDescription) == [
            "user:summary", "user:kept", "assistant:answer", "user:next", "assistant:done", "system:preamble",
        ])
        // A replacement of the baseline is not one either.
        _ = try transcript.append(kind: "edit", edits: [.replace(target: baseline.id, messages: EntryRecord.encodeMessages([contextSystem("other")]))])
        #expect(try transcript.view().messages.map(contextDescription) == [
            "user:summary", "user:kept", "assistant:answer", "user:next", "system:other", "assistant:done", "system:preamble",
        ])
    }
    @Test("synthesizes missing tool results after a fork and drops results cut from their call")
    func missing() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("go"))
        let call = try transcript.append(contextAssistant("calling", calls: ["x","y"]))
        _ = try transcript.append(contextResult("x")); let second = try transcript.append(contextResult("y"))
        let cut = try transcript.view(at: call.id)
        #expect(cut.messages.map(contextDescription) == ["user:go", "assistant:calling", "result:x:error", "result:y:error"])
        if case .toolResult(let result) = cut.messages[2] {
            #expect(result.toolName == "tool-x"); #expect(result.details == AnyCodable(["reason":"missing_result"]))
        } else { Issue.record("Missing error result") }
        _ = try transcript.append(kind: "reset", head: second.id.rawValue)
        #expect(try transcript.view().messages.isEmpty)
        #expect(try transcript.view().entries.map(\.kind) == ["reset", "message"])
    }
    @Test("reads the context as of an earlier entry, as a fork at that entry starts")
    func earlier() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first"))
        let call = try transcript.append(contextAssistant("calling", calls: ["x","y"]))
        _ = try transcript.append(contextResult("x")); _ = try transcript.append(contextResult("y"))
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v2")]))])
        _ = try transcript.append(contextUser("fresh start"), kind: "reset", head: 6)
        let tail = try transcript.append(contextAssistant("after reset"))
        for at in transcript.entries.map(\.id) {
            let fork = try deriveContext(entries: transcript.entries.filter { $0.id <= at })
            #expect(try transcript.view(at: at).messages.map(contextDescription) == fork.messages.map(contextDescription))
        }
        #expect(try transcript.view(at: call.id).messages.map(contextDescription) == ["user:first", "assistant:calling", "result:x:error", "result:y:error"])
        #expect(try transcript.view(at: tail.id).messages.map(contextDescription) == transcript.view().messages.map(contextDescription))
    }
    @Test("edits of discarded older heads affect kept entries")
    func olderHeadEdits() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first"))
        _ = try transcript.append(kind: "old-head", head: first.id.rawValue, edits: [.omit(target: first.id)])
        _ = try transcript.append(contextUser("summary"), kind: "new-head", head: first.id.rawValue)
        #expect(try transcript.view().messages.map(contextDescription) == ["user:summary"])
    }
}
