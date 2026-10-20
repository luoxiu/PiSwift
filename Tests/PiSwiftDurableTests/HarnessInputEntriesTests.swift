import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Inputs placed as application entries, and data-only writes appended at once (#10407).
// Source: harness-input-entries.test.ts at e6b9a6af5.

/// Register a `hold` tool whose calls wait for `gate`.
private func holdTool(_ setup: HarnessChatSetup, _ gate: HarnessChatSignal) throws {
    try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in
        await gate.wait()
        return .init(output: [.text(TextContent(text: "held"))])
    }), setup: setup)
}
private func hold() throws -> AssistantMessage { try toolCalls([("hold", [:], "c1")]) }

/// Role and text of each request message, as the provider receives them.
private func requestLog(_ requests: SessionTestLog<[String]>, _ reply: AssistantMessage) -> FakeDurableResponseStep {
    .factory { request, _, _, _ in
        requests.append(request.messages.map { "\($0.role):\(textOf($0) ?? "")" })
        return reply
    }
}

/// Kind, application data, and model text of each entry, skipping system entries.
private func transcript(_ entries: [EntryRecord]) throws -> [[JSONValue]] {
    try entries.filter { $0.kind != "pi.system" }.map { entry in
        let message = try entry.messages()?.first
        var text: String?
        if let message, case .toolResult = message {} else { text = textOf(message) }
        let data = entry.data == nil || entry.kind.hasPrefix("pi.") ? [] : [entry.data!]
        return [.string(entry.kind)] + data + (text.map { [.string($0)] } ?? [])
    }
}

private func inboxItems(_ chat: OpenChatResult) async throws -> [InboxItem] {
    try #require(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)).items
}

private func toolRunning(_ chat: OpenChatResult) async throws {
    try await eventually {
        try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.tools?.first?.status == .running
    }
}

private func placedEntry(_ record: SubmissionRecord) -> EntryID? {
    switch record {
    case .input(_, _, _, .placed(let entry, _)), .input(_, _, _, .done(let entry, _, _)), .write(_, _, _, .done(let entry, _)): entry
    default: nil
    }
}

private func mention(_ text: String) -> InputEntry {
    InputEntry(kind: "chat.mention", data: ["author": "ann", "text": .string(text)])
}

private func userMessages(_ text: String, timestamp: Int64 = 0) throws -> [JSONValue] {
    try EntryRecord.encodeMessages([.user(UserMessage(content: .text(text), timestamp: timestamp))])
}

@Suite struct HarnessInputEntriesTests {
    @Test func placesIdleInputAsItsEntryWithTheContentAsItsUserMessage() async throws {
        let setup = HarnessChatSetup()
        let requests = SessionTestLog<[String]>()
        setup.models.setResponses([requestLog(requests, chatAssistant("hi ann"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: HarnessOptions(models: setup.models,
            registry: setup.registry, settings: setup.settingsProvider, now: { 42 }), context: .background)
        let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
        let submission = try await root.submit(.input(content: .text("ann: hi"), entry: mention("hi")), context: .background)
        let settled = try await submission.wait(context: .background)
        let entries = try await allEntries(root)
        #expect(try transcript(entries) == [
            ["chat.mention", ["author": "ann", "text": "hi"], "ann: hi"],
            ["pi.assistant", "hi ann"]
        ])
        let placed = try #require(entries.first { $0.kind == "chat.mention" })
        #expect(placed.model == (try userMessages("ann: hi", timestamp: 42)))
        #expect(settled.status == "done")
        #expect(placedEntry(settled.record) == placed.id)
        #expect(settled.answer == entries.last?.id)
        #expect(requests.values == [["user:ann: hi"]])
        // The context of a fork at the input is the same as for a pi.user entry.
        let view = try await root.context(at: placed.id, context: .background)
        #expect(try EntryRecord.encodeMessages(view.messages.filter { $0.role != "system" }) == placed.model)
        try await harness.close(context: .background)
    }

    // Swift's kind is a String, so upstream's 123 has no counterpart.
    @Test func rejectsAnInputEntryWhoseKindIsEmptyOrStartsWithPiWritingNothing() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let before = try await allEntries(chat.root).count
        for kind in ["", "pi.user", "pi.compaction"] {
            do {
                _ = try await chat.root.submit(.input(content: .text("x"), entry: InputEntry(kind: kind)), context: .background)
                Issue.record("An input entry of kind \(kind) must be rejected")
            } catch {
                #expect(String(describing: error).contains("An input entry's kind must be"))
            }
        }
        #expect(try await allEntries(chat.root).count == before)
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background) == LiveState())
        // Writes keep their kinds: reset() writes pi.reset.
        try await chat.root.reset(context: .background)
        #expect(try await allEntries(chat.root).last?.kind == "pi.reset")
        try await chat.harness.close(context: .background)
    }

    // Upstream passes an untyped entry with extra fields. Swift's InputEntry has only kind and data, so the same
    // fields reach the Harness only through a stored inbox item, such as one another implementation wrote.
    @Test func takesOnlyKindAndDataFromAStoredInputEntry() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("queued"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        let queued = try await chat.root.submit(.input(content: .text("later"), entry: InputEntry(kind: "chat.mention")), context: .background)
        let forged = try userMessages("forged")
        let extra: JSONValue = [
            "kind": "chat.mention",
            "model": .array(forged),
            "head": "self",
            "edits": [["target": 1, "action": "omit"]]
        ]
        try await chat.root.commit({ tx in
            let items = try #require(try await tx.doc(InboxDoc, conversationId: chat.root.id).child("items"))
            try #require(try items.child(0)).set("entry", extra)
        }, context: .background)
        #expect(try await inboxItems(chat).last == InboxItem(id: queued.id, mode: .followUp, content: "later", inputEntry: InputEntry(kind: "chat.mention")))
        first.release()
        _ = try await queued.wait(context: .background)
        let mentions = try await allEntries(chat.root).filter { $0.kind == "chat.mention" }
        #expect(mentions.count == 1)
        #expect(mentions.first?.head == nil && mentions.first?.edits == nil)
        #expect(try textOf(mentions.first?.messages()?.first) == "later")
        #expect(mentions.first?.model?.count == 1)
        try await chat.harness.close(context: .background)
    }

    @Test func queuesBusyInputsWithTheirEntriesAndPlacesThemAsThoseEntriesAtBoundaries() async throws {
        let setup = HarnessChatSetup(), gate = HarnessChatSignal()
        defer { gate.signal() }
        try holdTool(setup, gate)
        setup.models.setResponses([.message(try hold()), .message(chatAssistant("after tools")), .message(chatAssistant("follow-up"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        try await toolRunning(chat)
        let steer = try await chat.root.submit(.input(content: .text("s"), whenBusy: .steer, entry: mention("s"), requestId: "r-s"), context: .background)
        let followUp = try await chat.root.submit(.input(content: .text("f"), whenBusy: .followUp, entry: InputEntry(kind: "p2.input")), context: .background)
        #expect(try await inboxItems(chat) == [
            InboxItem(id: steer.id, mode: .steer, content: "s", inputEntry: mention("s")),
            InboxItem(id: followUp.id, mode: .followUp, content: "f", inputEntry: InputEntry(kind: "p2.input"))
        ])
        // The request ID deduplicates a queued input with an entry as any other.
        let again = try await chat.root.submit(.input(content: .text("other"), whenBusy: .steer, entry: mention("other"), requestId: "r-s"), context: .background)
        #expect(again.id == steer.id)
        await #expect(throws: ConversationBusy.self) {
            try await chat.root.submit(.input(content: .text("x"), whenBusy: .reject, entry: mention("x")), context: .background)
        }
        #expect(try await inboxItems(chat).count == 2)

        gate.signal()
        _ = try await followUp.wait(context: .background)
        let entries = try await allEntries(chat.root)
        #expect(try transcript(entries) == [
            ["pi.user", "a"],
            ["pi.assistant"],
            ["pi.tool-result"],
            ["chat.mention", ["author": "ann", "text": "s"], "s"],
            ["pi.assistant", "after tools"],
            ["p2.input", "f"],
            ["pi.assistant", "follow-up"]
        ])
        let answers = entries.filter { $0.kind == "pi.assistant" }
        let placed = { (kind: String) in entries.first { $0.kind == kind }?.id }
        let inputStatus = try await input.status(context: .background)
        #expect(inputStatus.status == "done" && SettledSubmission(inputStatus).answer == answers[1].id)
        let steerStatus = try await steer.status(context: .background)
        #expect(steerStatus.status == "done" && placedEntry(steerStatus) == placed("chat.mention"))
        #expect(SettledSubmission(steerStatus).answer == answers[1].id)
        let followUpStatus = try await followUp.status(context: .background)
        #expect(followUpStatus.status == "done" && placedEntry(followUpStatus) == placed("p2.input"))
        #expect(SettledSubmission(followUpStatus).answer == answers[2].id)
        try await chat.harness.close(context: .background)
    }

    @Test func withdrawsQueuedInputsWithEntriesOneByOneAndByConversationAbort() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        let withdrawn = try await chat.root.submit(.input(content: .text("w"), entry: mention("w")), context: .background)
        let aborted = try await chat.root.submit(.input(content: .text("x"), entry: mention("x")), context: .background)
        #expect(try await withdrawn.abort(context: .background) == .aborted)
        #expect(try await inboxItems(chat).map(\.id) == [aborted.id])
        try await chat.root.abort(context: .background)
        for submission in [withdrawn, aborted] {
            let settled = try await submission.wait(context: .background)
            #expect(settled.status == "unanswered" && settled.reason == "aborted")
        }
        let settled = try await input.wait(context: .background)
        #expect(settled.status == "unanswered" && settled.reason == "aborted")
        #expect(try await inboxItems(chat).isEmpty)
        #expect(try await !allEntries(chat.root).contains { $0.kind == "chat.mention" })
        try await chat.harness.close(context: .background)
    }

    // Swift addition: the inbox item's entry has the JSON shape upstream stores, so TypeScript and Swift read
    // each other's queued inputs from SQLite and JSONL.
    @Test func storesAQueuedInputEntryInTheUpstreamInboxShape() throws {
        let id = try SubmissionID(5)
        let item = InboxItem(id: id, mode: .steer, content: "s", inputEntry: mention("s"))
        let upstream: JSONValue = ["id": 5, "mode": "steer", "content": "s", "entry": ["kind": "chat.mention", "data": ["author": "ann", "text": "s"]]]
        #expect(try JSONValue(encoding: item) == upstream)
        #expect(try upstream.decode(InboxItem.self) == item)
        // Without an entry the item has no `entry` member, as before; `data: null` stays distinct from no data.
        #expect(try JSONValue(encoding: InboxItem(id: id, mode: .followUp, content: "f")) == ["id": 5, "mode": "followUp", "content": "f"])
        let null: JSONValue = ["id": 5, "mode": "followUp", "content": "f", "entry": ["kind": "app.input", "data": nil]]
        #expect(try null.decode(InboxItem.self).inputEntry == InputEntry(kind: "app.input", data: .null))
        #expect(try JSONValue(encoding: null.decode(InboxItem.self)) == null)
    }
}

@Suite struct HarnessDataOnlyWritesTests {
    @Test func appendsADataOnlyWriteMidRunInTimeOrderLeavingTheModelsMessagesUnchanged() async throws {
        let setup = HarnessChatSetup(), gate = HarnessChatSignal()
        defer { gate.signal() }
        try holdTool(setup, gate)
        let requests = SessionTestLog<[String]>()
        setup.models.setResponses([requestLog(requests, try hold()), requestLog(requests, chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        let (stream, events) = try await eventListen(chat)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        try await toolRunning(chat)
        let note = EntryDraft(kind: "chat.message", data: ["author": "bob", "text": "lunch?"])
        let write = try await chat.root.submit(.write(entry: note, requestId: "bob:1"), context: .background)
        // Settled and appended in its own commit, between the call and its still-running tool's result.
        let settled = try await write.status(context: .background)
        #expect(settled.status == "done")
        #expect(try await inboxItems(chat).isEmpty)
        #expect(try transcript(await allEntries(chat.root)) == [
            ["pi.user", "a"],
            ["pi.assistant"],
            ["chat.message", ["author": "bob", "text": "lunch?"]]
        ])
        try await events.waitForType("entry_appended")
        let appended = try #require(events.events.first { $0["type"] == "entry_appended" })
        #expect(appended["entry"]?["kind"] == "chat.message")
        #expect(appended["entry"]?["id"] == placedEntry(settled).map { .number(Double($0.rawValue)) })
        #expect(!events.types.contains("run_end"))
        // A repeated request ID returns the same write without a second entry.
        #expect(try await chat.root.submit(.write(entry: note, requestId: "bob:1"), context: .background).id == write.id)

        gate.signal()
        _ = try await input.wait(context: .background)
        #expect(try transcript(await allEntries(chat.root)) == [
            ["pi.user", "a"],
            ["pi.assistant"],
            ["chat.message", ["author": "bob", "text": "lunch?"]],
            ["pi.tool-result"],
            ["pi.assistant", "done"]
        ])
        #expect(requests.values == [
            ["system:", "user:a"],
            ["system:", "user:a", "assistant:", "toolResult:held"]
        ])
        await stream.stop()
        try await chat.harness.close(context: .background)
    }

    @Test func queuesADataOnlyWriteBehindAQueuedResetSoItLandsAfterTheResetAndStaysVisible() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        try await chat.root.reset(context: .background)
        let message = try await chat.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "hi")), context: .background)
        #expect(try await message.status(context: .background).status == "queued")
        first.release()
        _ = try await input.wait(context: .background)
        let settled = try await message.wait(context: .background)
        let reset = try #require(try await allEntries(chat.root).first { $0.kind == "pi.reset" })
        #expect(settled.status == "done")
        #expect(try #require(placedEntry(settled.record)) > reset.id)
        #expect(try await chat.root.context(context: .background).entries.map(\.kind) == ["pi.reset", "chat.message"])
        // Once the reset is placed, display-only writes go in at once again.
        let later = try await chat.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "again")), context: .background)
        #expect(try await later.status(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test func leavesTheRequestUnchangedByADataOnlyWriteThatLandsWhileTheGenerationPrepares() async throws {
        let setup = HarnessChatSetup()
        let rendering = HarnessChatSignal(), render = HarnessChatSignal(), renders = Mutex(0)
        defer { render.signal() }
        try setup.registry.install(Extension(name: "section:slow", sections: [section("slow") { _, _ in
            if renders.withLock({ count in defer { count += 1 }; return count }) == 1 {
                rendering.signal()
                await render.wait()
            }
            return "SLOW"
        }]))
        let requests = SessionTestLog<[String]>()
        setup.models.setResponses([requestLog(requests, chatAssistant("one")), requestLog(requests, chatAssistant("two"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("a")), context: .background).wait(context: .background)
        let second = try await chat.root.submit(.input(content: .text("b")), context: .background)
        await rendering.wait()
        _ = try await chat.root.submit(.write(entry: EntryDraft(kind: "chat.message", data: "hi")), context: .background)
        render.signal()
        _ = try await second.wait(context: .background)
        #expect(requests.values.dropFirst().first == ["system:", "user:a", "assistant:one", "user:b"])
        // The unchanged prompt adds no second pi.system entry.
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.user", "chat.message", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }

    @Test func appendsADataOnlyWriteWhileIdleAfterAFailedRunWithoutPlacingTheQueuedItems() async throws {
        let setup = HarnessChatSetup()
        let failing = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "invalid request"))
        setup.models.setResponses([failing.step, .message(chatAssistant("for f"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await failing.reached.wait()
        let f = try await chat.root.submit(.input(content: .text("f"), entry: mention("f")), context: .background)
        failing.release()
        let failed = try await input.wait(context: .background)
        #expect(failed.status == "unanswered" && failed.reason == "model_error")
        try await chat.harness.waitForIdle(context: .background)
        let note = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", data: "n")), context: .background)
        #expect(try await note.status(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await f.status(context: .background).status == "queued")
        #expect(try await inboxItems(chat).map(\.id) == [f.id])
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background) == LiveState())
        #expect(setup.models.state().callCount == 1)
        // The next input places the waiting mention first.
        let g = try await chat.root.submit(.input(content: .text("g")), context: .background)
        _ = try await g.wait(context: .background)
        #expect(try transcript(await allEntries(chat.root)).filter { $0.first != "pi.assistant" } == [
            ["pi.user", "a"],
            ["note", "n"],
            ["chat.mention", ["author": "ann", "text": "f"], "f"],
            ["pi.user", "g"]
        ])
        try await chat.harness.close(context: .background)
    }

    @Test func keepsAQueuedInputsEntryAcrossReopenAndPlacesItAsThatEntry() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("first again")), .message(chatAssistant("for f"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        _ = try await opened.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        let f = try await opened.root.submit(.input(content: .text("f"), entry: mention("f")), context: .background).id
        try await opened.harness.close(context: .background)

        opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await inboxItems(opened).first { $0.id == f }?.inputEntry == mention("f"))
        let settled = try await #require(try await opened.harness.submission(id: f, context: .background)).wait(context: .background)
        let placed = try #require(try await allEntries(opened.root).first { $0.kind == "chat.mention" })
        #expect(settled.status == "done" && placedEntry(settled.record) == placed.id)
        #expect(placed.data == mention("f").data)
        let message = try #require(try placed.messages()?.first)
        #expect(message.role == "user" && textOf(message) == "f" && placed.model?.count == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func appendsADataOnlyWriteAtOnceBehindANonEmptyInboxAndStillQueuesWritesWithModelOrEdits() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step, .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        let followUp = try await chat.root.submit(.input(content: .text("f")), context: .background)
        let model = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", model: userMessages("m"))), context: .background)
        let target = try #require(try await allEntries(chat.root).first { $0.kind == "pi.user" })
        let edit = try await chat.root.submit(.write(entry: EntryDraft(kind: "redact", edits: [.omit(target: target.id)])), context: .background)
        let note = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", data: "n")), context: .background)
        #expect(try await note.status(context: .background).status == "done")
        let items = try await inboxItems(chat)
        #expect(items.map(\.id) == [followUp.id, model.id, edit.id])
        #expect(items.map(\.mode) == [.followUp, .write, .write])
        first.release()
        _ = try await followUp.wait(context: .background)
        #expect(try transcript(await allEntries(chat.root)) == [
            ["pi.user", "a"],
            ["note", "n"],
            ["pi.assistant", "first"],
            ["note", "m"],
            ["redact"],
            ["pi.user", "f"],
            ["pi.assistant", "second"]
        ])
        #expect(try await input.status(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    // Swift addition: present counts even when empty, so a write with an empty `model` or `edits` still queues.
    @Test func queuesAWriteWhoseModelOrEditsArePresentButEmpty() async throws {
        let setup = HarnessChatSetup()
        let first = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([first.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background)
        await first.reached.wait()
        let model = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", model: [])), context: .background)
        let edits = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", edits: [])), context: .background)
        #expect(try await inboxItems(chat).map(\.id) == [model.id, edits.id])
        first.release()
        _ = try await input.wait(context: .background)
        #expect(try await model.wait(context: .background).status == "done")
        #expect(try await edits.wait(context: .background).status == "done")
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.assistant", "note", "note"])
        try await chat.harness.close(context: .background)
    }
}
