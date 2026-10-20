// Durable telemetry: submit and phase spans, stored carriers, events, reports, and metrics (upstream
// harness-telemetry.test.ts at 2ec55d808).
//
// Swift: `FakeDurableModels` answers without PiSwiftAI's dispatch, so no `pi.ai.request` span is recorded; the tests
// check instead that each model request gets its phase's span in `options.telemetry` (PiSwiftAI's own tests check the
// spans it records under it).
import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftTelemetry
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func openTracked(_ storage: any DurableStorage = MemoryStorage(), _ setup: HarnessChatSetup,
                         _ telemetry: InMemoryTelemetryContext) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage, options: HarnessOptions(
        models: setup.models, registry: setup.registry, settings: setup.settingsProvider, now: setup.now,
        onReport: { setup.reports.append($0, info: $1) }, telemetry: telemetry), context: .background)
    let root = try await harness.root(options: .init(agent: AgentChange(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))),
                                      context: .background)
    return OpenChatResult(harness: harness, root: root)
}

private func settled(_ telemetry: InMemoryTelemetryContext) async throws {
    try await eventually { telemetry.getSpans().allSatisfy(\.settled) }
}

private func num(_ value: Int64) -> AttributeValue { .number(Double(value)) }

private func phases(_ telemetry: InMemoryTelemetryContext) -> [RecordedTelemetrySpan] {
    telemetry.getSpans().filter { $0.name == "pi.durable.phase" }
}

private func toolReply(_ name: String, _ args: JSONObject = [:]) throws -> AssistantMessage {
    try toolCalls([(name, args, "call-1")])
}

private struct TelemetryCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case hold, call, finish, fail, report, start }
    var phase: Phase
    var count = 0
}
private typealias TelemetryTask = TaskDefinition<JSONValue, TelemetryCheckpoint, JSONValue, NoTaskHooks>

private func telemetryTask(_ name: String, start: TelemetryCheckpoint.Phase = .finish,
                           phases: [TelemetryCheckpoint.Phase: @Sendable (TaskRuntime, ChordContext, TelemetryCheckpoint) async throws -> Void] = [:],
                           abort: (@Sendable (TaskRuntime, ChordContext) async throws -> Void)? = nil) -> TelemetryTask {
    TelemetryTask(name: name, version: 1, initial: { _ in TelemetryCheckpoint(phase: start) }, phase: { task, runtime, context in
        if let handler = phases[task.checkpoint.phase] { return try await handler(runtime, context, task.checkpoint) }
        try await runtime.commit({ _, _ in try completed(JSONValue.null) }, context: context)
    }, abort: { _, runtime, context in
        if let abort { return try await abort(runtime, context) }
        try await runtime.commit({ _, _ in abortedWith("test") }, context: context)
    })
}

private func install(_ setup: HarnessChatSetup, _ task: TelemetryTask) throws {
    try setup.registry.install(Extension(name: "task:\(task.name)", tasks: [AnyTaskDefinition(task)]))
}

/// Records the `telemetry` of each model request.
private final class RequestSpans: Sendable {
    private let state = Mutex<[(any TelemetrySpan)?]>([])
    var values: [(any TelemetrySpan)?] { state.withLock { $0 } }
    func step(_ message: AssistantMessage) -> FakeDurableResponseStep {
        .factory { [self] _, options, _, _ in
            state.withLock { $0.append(options?.telemetry) }
            return message
        }
    }
}

@Suite struct HarnessTelemetryTests {
    @Test func recordsContentFreeSubmitAndPhaseSpansNestedParentsCheckpointsEntryEventsAndMetrics() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), requests = RequestSpans()
        try installHarnessTool(try ToolRegistration(
            name: "inner", description: "inner",
            parameters: ["type": "object", "properties": ["secret": ["type": "string"]], "required": ["secret"]]
        ) { _, _, _ in ToolExecutionResult(output: [.text(TextContent(text: "private-result"))]) }, setup: setup)
        try installHarnessTool(try ToolRegistration(name: "outer", description: "outer", parameters: ["type": "object"]) { _, api, context in
            _ = try await api.executeTool("inner", arguments: ["secret": "private-argument"], context: context)
            return ToolExecutionResult(output: [.text(TextContent(text: "private-output"))])
        }, setup: setup)
        setup.models.setResponses([requests.step(try toolReply("outer")), requests.step(chatAssistant("private-answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let submitted = try await opened.root.submit(.input(content: .text("private-input"), requestId: "dedupe"), context: .background)
        _ = try await submitted.wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        let record = try await submitted.status(context: .background)
        let again = try await opened.root.submit(.input(content: .text("another-private-input"), requestId: "dedupe"), context: .background)
        #expect(try await again.status(context: .background) == record)
        let spans = telemetry.getSpans()
        let submit = try #require(spans.first { $0.name == "pi.durable.submit" })
        #expect(submit.parentId == nil)
        #expect(submit.attributes["submission.id"] == num(submitted.id.rawValue) && submit.attributes["result"] == "placed")
        #expect(record.trace == submit.context)
        let phases = phases(telemetry)
        #expect(phases.count > 4)
        // Each model request gets its request phase's span.
        #expect(requests.values.count == 2)
        for span in requests.values {
            let carrier = try #require(span.flatMap { telemetry.inject($0) })
            #expect(phases.first { $0.context == carrier }?.attributes["phase"] == "request")
        }
        #expect(phases[0].parentContext == submit.context)
        #expect(phases[0].attributes["phase"] == "prepare" && phases[0].attributes["resumed"] == false)
        #expect(phases[0].attributes["outcome"] == "next=request")
        let outer = try #require(phases.first { $0.attributes["tool.name"] == "outer" })
        let inner = try #require(phases.first { $0.attributes["tool.name"] == "inner" })
        #expect(inner.parentContext == outer.context)
        #expect(outer.attributes["phase"] == "call" && outer.attributes["outcome"] == "done")
        #expect(outer.attributes["tool.call_id"] == "call-1")
        #expect(outer.events.contains(RecordedTelemetryEvent(name: "pi.durable.checkpoint", attributes: ["phase": "execute"])))
        #expect(phases.contains { $0.attributes["outcome"] == "waiting" })
        guard case .input(_, _, _, .done(let entry, let answer, _)) = record else { Issue.record("Expected a done input"); return }
        #expect(submit.events.contains(RecordedTelemetryEvent(name: "pi.durable.entry", attributes: [
            "entry.id": num(entry.rawValue), "entry.kind": "pi.user",
        ])))
        #expect(phases.flatMap(\.events).contains(RecordedTelemetryEvent(name: "pi.durable.submission", attributes: [
            "submission.id": num(submitted.id.rawValue), "status": "done", "answer.entry_id": num(answer.rawValue),
        ])))
        let recorded = String(describing: spans.map { ($0.attributes, $0.events) })
        for content in ["private-input", "private-answer", "private-output", "private-result", "private-argument", "secret", "gen_ai"] {
            #expect(!recorded.contains(content), "\(content)")
        }
        try await opened.harness.close(context: .background)
        let metrics = telemetry.getMetrics()
        #expect(metrics.filter { $0.name == "pi.durable.phase.duration" }.count == phases.count)
        #expect(metrics.filter { $0.name == "pi.durable.tasks.active" }.map(\.value).reduce(0, +) == 0)
        for metric in metrics where metric.name.hasPrefix("pi.durable.") {
            #expect(!metric.attributes.keys.contains { $0.contains("id") })
        }
        #expect(setup.reports.values.isEmpty)
    }

    // Swift: upstream also spies on the adapter's `inject` and `extract`, to see that the root adapter is never a link
    // target and no carrier-less extraction happens. A `ChordContext` holds only spans, so the root cannot be one; the
    // scheduler and admission extract only stored carriers. The storage reads and the results are checked.
    @Test func returnsAdmissionResultsWithoutRereadingRecords() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let gate = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([gate.step, .message(chatAssistant("second"))])
        let opened = try await openTracked(storage, setup, telemetry)
        let reads = await storage.submissionReadCount
        let first = try await opened.root.submit(.input(content: .text("first")), context: .background)
        await gate.reached.wait()
        let second = try await opened.root.submit(.input(content: .text("second"), requestId: "queued"), context: .background)
        let duplicate = try await opened.root.submit(.input(content: .text("ignored"), requestId: "queued"), context: .background)
        #expect(duplicate.id == second.id)
        #expect(await storage.submissionReadCount == reads)
        #expect(telemetry.getSpans().filter { $0.name == "pi.durable.submit" }.map { $0.attributes["result"] } == ["placed", "queued", "queued"])
        gate.release()
        _ = try await first.wait(context: .background)
        _ = try await second.wait(context: .background)
        try await opened.harness.close(context: .background)
    }

    @Test func inheritsOmittedTaskTracesAndStoresNoCarrierForAnExplicitRoot() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let task = telemetryTask("test.trace")
        try install(setup, task)
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        // Swift: upstream's omitted and `undefined` traces are both nil.
        let ids = try await telemetry.startSpan(SpanOptions(name: "creator")) { span in
            try await opened.root.commit({ tx in [
                try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())),
                try await tx.createTask(task, input: .null, options: .init(ownership: .conversation(), trace: nil)),
                try await tx.createTask(task, input: .null, options: .init(ownership: .conversation(), trace: .root)),
            ] }, context: ChordContext.background.withTelemetry(span))
        }
        try opened.harness.resume()
        for id in ids { _ = try await opened.harness.waitForTask(id: id, context: .background) }
        try await settled(telemetry)
        let creator = telemetry.getSpans()[0]
        var traces: [TelemetryCarrier?] = []
        for id in ids { traces.append(try await opened.harness.getTask(id: id, context: .background)?.trace) }
        #expect(traces == [creator.context, creator.context, nil])
        let parents = phases(telemetry).sorted { ($0.attributes["task.id"].map(String.init(describing:)) ?? "") < ($1.attributes["task.id"].map(String.init(describing:)) ?? "") }
        #expect(parents.map(\.parentContext) == [creator.context, creator.context, nil])
        try await opened.harness.close(context: .background)
    }

    @Test func recordsCheckpointsOnlyWhenTheRunningPhaseChanges() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let task = telemetryTask("test.checkpoint", start: .call, phases: [.call: { runtime, context, _ in
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: TelemetryCheckpoint(phase: .call, count: 1))) }, context: context)
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: TelemetryCheckpoint(phase: .call, count: 2))) }, context: context)
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: TelemetryCheckpoint(phase: .finish, count: 2))) }, context: context)
        }])
        try install(setup, task)
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let id = try await opened.root.commit({ tx in try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())) },
                                              context: .background)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await settled(telemetry)
        #expect(telemetry.getSpans().flatMap(\.events).filter { $0.name == "pi.durable.checkpoint" }
                == [RecordedTelemetryEvent(name: "pi.durable.checkpoint", attributes: ["phase": "finish"])])
        try await opened.harness.close(context: .background)
    }

    @Test func startsEachQueuedInputsRunInItsAdmissionTraceAndLinksInputRootsToTheirCaller() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let gate = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([gate.step, .message(chatAssistant("second"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        try await telemetry.startSpan(SpanOptions(name: "caller")) { caller in
            let context = ChordContext.background.withTelemetry(caller)
            let first = try await opened.root.submit(.input(content: .text("first")), context: context)
            await gate.reached.wait()
            let second = try await opened.root.submit(.input(content: .text("second")), context: context)
            #expect(try await second.status(context: context).status == "queued")
            gate.release()
            _ = try await first.wait(context: context)
            _ = try await second.wait(context: context)
        }
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        let spans = telemetry.getSpans()
        let caller = try #require(spans.first { $0.name == "caller" })
        let submits = spans.filter { $0.name == "pi.durable.submit" }
        #expect(submits.count == 2)
        for submit in submits {
            #expect(submit.parentId == nil)
            #expect(submit.links == [RecordedTelemetryLink(context: caller.context)])
            #expect(spans.contains { $0.name == "pi.durable.phase" && $0.attributes["phase"] == "prepare" && $0.parentContext == submit.context })
        }
        #expect(submits[0].context != submits[1].context)
        try await opened.harness.close(context: .background)
    }

    @Test func linksTheOtherQueuedInputsToTheFirstInvocationOfTheirSharedRun() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        setup.updateSettings { $0.followUpMode = .all }
        let gate = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([gate.step, .message(chatAssistant("shared"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let first = try await opened.root.submit(.input(content: .text("first")), context: .background)
        await gate.reached.wait()
        let second = try await opened.root.submit(.input(content: .text("second")), context: .background)
        let third = try await opened.root.submit(.input(content: .text("third")), context: .background)
        let secondTrace = try await second.status(context: .background).trace
        let thirdTrace = try #require(try await third.status(context: .background).trace)
        gate.release()
        for submission in [first, second, third] { _ = try await submission.wait(context: .background) }
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.generation"), limit: 10).items },
                                                    context: .background)
        #expect(tasks[1].trace == secondTrace && tasks[1].links == [thirdTrace])
        let shared = phases(telemetry).filter { $0.attributes["task.id"] == num(tasks[1].id.rawValue) }
        #expect(shared.map { $0.attributes["phase"] } == ["prepare", "request"])
        for phase in shared { #expect(phase.links == [RecordedTelemetryLink(context: thirdTrace)]) }
        try await opened.harness.close(context: .background)
    }

    @Test func linksASteerAdmissionToTheCurrentRunWithoutMovingItsWorkIntoTheSteersTrace() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let reached = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(try ToolRegistration(name: "hold", description: "hold", parameters: ["type": "object"]) { _, _, _ in
            reached.signal()
            await release.wait()
            return ToolExecutionResult(output: [])
        }, setup: setup)
        setup.models.setResponses([.message(try toolReply("hold")), .message(chatAssistant("answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let first = try await opened.root.submit(.input(content: .text("first")), context: .background)
        await reached.wait()
        let run = try #require(try await opened.harness.inspect(context: .background).tasks.first { $0.record.kind == "pi.generation" }?.record)
        let steer = try await opened.root.submit(.input(content: .text("steer"), whenBusy: .steer), context: .background)
        let steerTrace = try await steer.status(context: .background).trace
        let steerSpan = try #require(telemetry.getSpans().first { $0.attributes["submission.id"] == num(steer.id.rawValue) })
        #expect(steerSpan.parentId == nil)
        #expect(steerSpan.links == [RecordedTelemetryLink(context: try #require(run.trace))])
        release.signal()
        _ = try await first.wait(context: .background)
        _ = try await steer.wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        #expect(!phases(telemetry).contains { $0.parentContext == steerTrace })
        try await opened.harness.close(context: .background)
    }

    @Test func keepsAPublicWriteAdmissionOpenThroughCommitAsAChildOfItsCaller() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let opened = try await openTracked(storage, setup, telemetry)
        try await telemetry.startSpan(SpanOptions(name: "caller")) { caller in
            let held = await storage.holdCommits()
            let writing = Task {
                try await opened.root.submit(.write(entry: EntryDraft(kind: "app.note", data: "private-note")),
                                             context: ChordContext.background.withTelemetry(caller))
            }
            await held.waitUntilEntered()
            let inFlight = try #require(telemetry.getSpans().first { $0.name == "pi.durable.submit" })
            #expect(!inFlight.settled && inFlight.events.isEmpty)
            await held.release()
            let submission = try await writing.value
            let record = try await submission.status(context: .background)
            let span = try #require(telemetry.getSpans().first { $0.name == "pi.durable.submit" })
            #expect(span.parentContext == telemetry.getSpans()[0].context)
            #expect(span.settled && span.attributes["result"] == "done")
            #expect(record.trace == span.context)
            #expect(span.events.map(\.name) == ["pi.durable.entry", "pi.durable.submission"])
        }
        try await opened.harness.close(context: .background)
    }

    @Test func linksAnInputSubmittedInsideATurnToTheCallingPhaseWithoutParentingIt() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        try installHarnessTool(try ToolRegistration(name: "delegate", description: "delegate", parameters: ["type": "object"]) { _, api, context in
            let child = try await api.commit({ tx in try await tx.createConversation(ownership: .task(taskId: api.taskId)) }, context: context)
            let conversation = try #require(try await api.conversation(id: child.id, context: context))
            _ = try await conversation.submit(.input(content: .text("child")), context: context).wait(context: context)
            return ToolExecutionResult(output: [])
        }, setup: setup)
        setup.models.setResponses([.message(try toolReply("delegate")), .message(chatAssistant("child answer")),
                                   .message(chatAssistant("parent answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        _ = try await opened.root.submit(.input(content: .text("parent")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        let spans = telemetry.getSpans()
        let tool = try #require(spans.first { $0.attributes["tool.name"] == "delegate" })
        let child = spans.filter { $0.name == "pi.durable.submit" }[1]
        #expect(child.parentId == nil)
        #expect(child.links == [RecordedTelemetryLink(context: tool.context)])
        try await opened.harness.close(context: .background)
    }

    @Test func parentsBackgroundCompactionToThePreparePhaseThatCreatesIt() async throws {
        let setup = HarnessChatSetup(options: FauxRegistrationOptions(models: [FauxModelDefinition(id: "faux-1", contextWindow: 1000, maxTokens: 100)]))
        setup.updateSettings { $0.compaction = CompactionSettings(enabled: true, reserveTokens: 300, keepRecentTokens: 150, backgroundTokens: 1000) }
        let telemetry = InMemoryTelemetryContext()
        try setup.registry.install(Extension(name: "decline", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in .decline }))]))
        setup.models.setResponses([.message(chatAssistant("done"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        try await opened.root.commit({ tx in
            _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "pi.user", model: EntryRecord.encodeMessages(
                [.user(UserMessage(content: .text(String(repeating: "x", count: 400)), timestamp: 1))])))
            _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "pi.assistant", model: EntryRecord.encodeMessages(
                [.assistant(chatAssistant(String(repeating: "y", count: 400)))])))
        }, context: .background)
        _ = try await opened.root.submit(.input(content: .text(String(repeating: "z", count: 400))), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await eventually { telemetry.getSpans().contains { $0.attributes["task.name"] == "pi.compaction" && $0.settled } }
        let spans = telemetry.getSpans()
        let prepare = try #require(spans.first { $0.attributes["task.name"] == "pi.generation" && $0.attributes["phase"] == "prepare" })
        let compaction = try #require(spans.first { $0.attributes["task.name"] == "pi.compaction" })
        #expect(compaction.parentContext == prepare.context)
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.compaction"), limit: 10).items },
                                                    context: .background)
        #expect(tasks.first?.background == true && tasks.first?.trace == prepare.context)
        try await opened.harness.close(context: .background)
    }

    @Test func marksOnlyTheFirstInvocationAfterReopenResumedRetainingItsStoredParent() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let recover = Mutex(false), reached = HarnessChatSignal()
        let task = telemetryTask("test.resume", start: .hold, phases: [.hold: { runtime, context, _ in
            if !recover.withLock({ $0 }) {
                reached.signal()
                try await aborted(try #require(context.abortSignal))
            }
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: TelemetryCheckpoint(phase: .finish))) }, context: context)
        }])
        try install(setup, task)
        var opened = try await openTracked(storage, setup, telemetry)
        let root = opened.root
        let id = try await telemetry.startSpan(SpanOptions(name: "creator")) { span in
            try await root.commit({ tx in try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())) },
                                  context: ChordContext.background.withTelemetry(span))
        }
        try opened.harness.resume()
        await reached.wait()
        let before = try #require(try await opened.harness.getTask(id: id, context: .background))
        try await opened.harness.close(context: .background)
        recover.withLock { $0 = true }
        let reopenedTelemetry = InMemoryTelemetryContext()
        opened = try await openTracked(storage.reopen(), setup, reopenedTelemetry)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await settled(reopenedTelemetry)
        let all = phases(telemetry) + phases(reopenedTelemetry)
        #expect(all.map { $0.attributes["resumed"] } == [false, true, false])
        #expect(all[0].attributes["outcome"] == "aborted")
        #expect(all[0].status == .ok)
        for phase in all { #expect(phase.parentContext == before.trace) }
        try await opened.harness.close(context: .background)
        #expect((telemetry.getMetrics() + reopenedTelemetry.getMetrics()).filter { $0.name == "pi.durable.tasks.active" }.map(\.value)
                == [1, -1, 1, -1])
    }

    @Test func emitsEntryAndSettlementEventsOnlyAfterSuccessfulStorageCommits() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let opened = try await openTracked(storage, setup, telemetry)
        let root = opened.root
        try await telemetry.startSpan(SpanOptions(name: "caller")) { span in
            let context = ChordContext.background.withTelemetry(span)
            await #expect(throws: TestFailure.self) {
                try await root.commit({ tx in
                    _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "app.rolled-back", data: "private-rolled-back"))
                    throw TestFailure("rollback")
                }, context: context)
            }
            #expect(telemetry.getSpans()[0].events.isEmpty)
            let held = await storage.holdCommits()
            let writing = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "app.note", data: "private-content")) }, context: context) }
            await held.waitUntilEntered()
            #expect(telemetry.getSpans()[0].events.isEmpty)
            await held.release()
            let entry = try await writing.value
            let submission = try await root.commit({ tx in
                try await tx.createSubmission(.write(conversationId: root.id, state: .done(entry: entry.id)))
            }, context: context)
            #expect(telemetry.getSpans()[0].events == [
                RecordedTelemetryEvent(name: "pi.durable.entry", attributes: ["entry.id": num(entry.id.rawValue), "entry.kind": "app.note"]),
                RecordedTelemetryEvent(name: "pi.durable.submission", attributes: ["submission.id": num(submission.id.rawValue), "status": "done"]),
            ])
        }
        try await opened.harness.close(context: .background)
    }

    @Test func recordsInternalCompactionAdmissionsAsPhaseEventsWithoutASubmitSpan() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        setup.updateSettings { $0.compaction = CompactionSettings(keepRecentTokens: 1) }
        let held = Mutex<ControlledStorage.Gate?>(nil), installed = HarnessChatSignal()
        try setup.registry.install(Extension(name: "summary", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in
            held.withLock { $0 = nil }
            let gate = await storage.holdCommits()
            held.withLock { $0 = gate }
            installed.signal()
            return .summary("private-summary")
        }))]))
        let opened = try await openTracked(storage, setup, telemetry)
        try await opened.root.commit({ tx in
            _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "pi.user", model: EntryRecord.encodeMessages(
                [.user(UserMessage(content: .text("old"), timestamp: 1))])))
            _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "pi.assistant", model: EntryRecord.encodeMessages(
                [.assistant(chatAssistant("answer"))])))
        }, context: .background)
        let id = try await opened.root.compact(context: .background)
        await installed.wait()
        let gate = try #require(held.withLock { $0 })
        await gate.waitUntilEntered()
        #expect(!telemetry.getSpans().contains { $0.name == "pi.durable.submit" })
        let running = try #require(telemetry.getSpans().first { $0.attributes["task.name"] == "pi.compaction" })
        #expect(!running.settled && running.events.isEmpty)
        await gate.release()
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await settled(telemetry)
        let spans = telemetry.getSpans()
        let phase = try #require(spans.first { $0.attributes["task.name"] == "pi.compaction" })
        #expect(!spans.contains { $0.name == "pi.durable.submit" })
        #expect(phase.events.contains { $0.name == "pi.durable.entry" })
        #expect(phase.events.contains { $0.name == "pi.durable.submission" && $0.attributes["status"] == "done" })
        #expect(!String(describing: spans).contains("private-summary"))
        try await opened.harness.close(context: .background)
    }

    // Swift: upstream sets the thrown error's `name` to a private value; a Swift error has its type name, which the
    // span must not hold either. Upstream's `orphaned` case commits an orphaned outcome from the task; the Swift
    // runtime faults a task that commits one ("Only the scheduler can commit orphaned outcomes"), and the scheduler
    // orphans only tasks without an invocation, so no phase span ends orphaned and that case is not ported.
    @Test(arguments: ["faulted", "failed"])
    func recordsAFixedCategoryAndABoundedDiagnostic(status: String) async throws {
        struct PrivateExceptionName: Error, CustomStringConvertible { let description: String }
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let message = String(repeating: "diagnostic ", count: 80)
        let task = telemetryTask("test.fault", start: .fail, phases: [.fail: { runtime, context, _ in
            if status == "faulted" { throw PrivateExceptionName(description: message) }
            try await runtime.commit({ _, _ in
                .terminal(outcome: status == "orphaned" ? .orphaned(reason: message)
                          : .failed(error: TaskOutcomeError(message: message, detail: "private-error-detail")))
            }, context: context)
        }])
        try install(setup, task)
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let id = try await opened.root.commit({ tx in
            try await tx.createTask(task, input: .null, options: .init(ownership: .conversation(), trace: .carrier(["unknown": "carrier"])))
        }, context: .background)
        let record = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(record.outcome.status == status)
        try await settled(telemetry)
        let span = try #require(phases(telemetry).first)
        #expect(span.parentId == nil && span.attributes["outcome"] == "faulted")
        #expect(span.status == .error(name: "task_\(status)", message: String(message.prefix(500))))
        if status == "faulted" {
            try await eventually { setup.reports.count > 0 }
            #expect(span.events.contains(RecordedTelemetryEvent(name: "pi.durable.report", attributes: [
                "type": "task_faulted", "reason": "threw", "extension": "task:test.fault", "task.id": num(id.rawValue),
            ])))
        }
        #expect(!String(describing: span).contains("PrivateExceptionName"))
        #expect(!String(describing: span).contains("private-error-detail"))
        #expect(!String(describing: (span.attributes, span.events)).contains("diagnostic"))
        try await opened.harness.close(context: .background)
    }

    @Test func keepsBothInterruptedRunsAndExplicitAbortHandlersAtStatusOk() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), reached = HarnessChatSignal()
        let task = telemetryTask("test.abort", start: .hold, phases: [.hold: { _, context, _ in
            reached.signal()
            try await aborted(try #require(context.abortSignal))
        }], abort: { runtime, context in
            try await runtime.commit({ _, _ in abortedWith("private-abort-reason") }, context: context)
        })
        try install(setup, task)
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let id = try await opened.root.commit({ tx in try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())) },
                                              context: .background)
        try opened.harness.resume()
        await reached.wait()
        _ = try await opened.harness.abortTask(id: id, context: .background)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await settled(telemetry)
        let all = phases(telemetry)
        #expect(all.map { $0.attributes["kind"] } == ["run", "abort"])
        for span in all {
            #expect(span.attributes["outcome"] == "aborted")
            #expect(span.status == .ok)
        }
        #expect(!String(describing: all).contains("private-abort-reason"))
        try await opened.harness.close(context: .background)
    }

    @Test func mirrorsRuntimeReportsAsFixedFieldPhaseEventsAndTypeOnlyCounters() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let error = TestFailure("private-report-payload")
        let task = telemetryTask("test.report", start: .report, phases: [.report: { runtime, context, _ in
            try runtime.report(error)
            try runtime.report(error, from: .extension("reporting-extension"))
            try runtime.report(error, from: .host(.models))
            try await runtime.commit({ _, _ in try completed(JSONValue.null) }, context: context)
        }])
        try install(setup, task)
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let id = try await opened.root.commit({ tx in try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())) },
                                              context: .background)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        try await settled(telemetry)
        let span = try #require(phases(telemetry).first)
        #expect(span.events == [
            RecordedTelemetryEvent(name: "pi.durable.report", attributes: ["type": "task_error", "extension": "task:test.report", "task.id": num(id.rawValue)]),
            RecordedTelemetryEvent(name: "pi.durable.report", attributes: ["type": "extension_error", "extension": "reporting-extension", "task.id": num(id.rawValue)]),
            RecordedTelemetryEvent(name: "pi.durable.report", attributes: ["type": "host_error", "task.id": num(id.rawValue)]),
        ])
        #expect(setup.reports.values.map { String(describing: $0) } == Array(repeating: "private-report-payload", count: 3))
        #expect(!telemetry.getSpans().contains { $0.name == "pi.durable.report" })
        #expect(telemetry.getMetrics().filter { $0.name == "pi.durable.reports" }.map { [$0.attributes, ["value": .number($0.value)]] } == [
            [["type": "task_error"], ["value": 1]], [["type": "extension_error"], ["value": 1]], [["type": "host_error"], ["value": 1]],
        ])
        #expect(!String(describing: telemetry.getSpans()).contains("private-report-payload"))
        try await opened.harness.close(context: .background)
    }

    // Swift: the second half, a clock failure reported without a phase context, has no counterpart: `HarnessOptions.now`
    // cannot throw.
    @Test func reportsHookFailuresOnThePhase() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let hookError = TestFailure("private-hook-error")
        try setup.registry.install(Extension(name: "reporting-hooks", hooks: [hook(GenerationHooks(beforeRequest: { _, _, _ in throw hookError }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        _ = try await opened.root.submit(.input(content: .text("input")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        let request = try #require(phases(telemetry).first { $0.attributes["phase"] == "request" })
        #expect(request.events.contains(RecordedTelemetryEvent(name: "pi.durable.report", attributes: [
            "type": "extension_error", "extension": "reporting-hooks", "task.id": try #require(request.attributes["task.id"]),
        ])))
        #expect(!telemetry.getSpans().contains { $0.name == "pi.durable.report" })
        #expect(telemetry.getMetrics().filter { $0.name == "pi.durable.reports" }.map(\.attributes) == [["type": "extension_error"]])
        #expect(setup.reports.values.map { String(describing: $0) } == ["private-hook-error"])
        #expect(!String(describing: telemetry.getSpans()).contains("private-hook-error"))
        try await opened.harness.close(context: .background)
    }

    @Test func countsAnOutsideSpanSessionFailureWithoutStartingASpan() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let opened = try await openTracked(storage, setup, telemetry)
        let error = TestFailure("private-storage-error")
        await storage.failNextCommit(error)
        await #expect(throws: TestFailure.self) {
            try await opened.root.commit({ tx in try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "app.failed")) }, context: .background)
        }
        _ = await opened.harness.closed
        try await settled(telemetry)
        #expect(setup.reports.values.map { String(describing: $0) } == ["private-storage-error"])
        #expect(telemetry.getSpans().isEmpty)
        #expect(!String(describing: telemetry.getMetrics()).contains("private-storage-error"))
        #expect(telemetry.getMetrics().filter { $0.name == "pi.durable.reports" }.map(\.attributes) == [["type": "session_failed"]])
    }

    @Test func countsReportsRaisedWithANoopSpanWithoutCreatingARoot() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let error = TestFailure("private-noop-report")
        let subscription = try opened.harness.subscribeCommits { _, _ in throw error }
        _ = try await opened.root.commit({ tx in try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "app.note")) }, context: .background)
        #expect(setup.reports.values.map { String(describing: $0) } == ["private-noop-report"])
        #expect(telemetry.getSpans().isEmpty)
        #expect(telemetry.getMetrics().filter { $0.name == "pi.durable.reports" }.map(\.attributes) == [["type": "listener_error"]])
        subscription.cancel()
        try await opened.harness.close(context: .background)
    }

    @Test func attachesSynchronousCommitListenerReportsToTheActiveSubmissionSpan() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let error = TestFailure("private-listener-error")
        let subscription = try opened.harness.subscribeCommits { publication, _ in
            if publication.changes.contains(where: { if case .entry(let entry) = $0 { entry.kind == "pi.user" } else { false } }) { throw error }
        }
        _ = try await opened.root.submit(.input(content: .text("input")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        #expect(setup.reports.values.map { String(describing: $0) } == ["private-listener-error"])
        let span = try #require(telemetry.getSpans().first { $0.name == "pi.durable.submit" })
        #expect(span.events.contains(RecordedTelemetryEvent(name: "pi.durable.report", attributes: ["type": "listener_error"])))
        #expect(!String(describing: telemetry.getSpans()).contains("private-listener-error"))
        subscription.cancel()
        try await opened.harness.close(context: .background)
    }

    // Upstream's "preserves async listener error containment" has no counterpart: Swift commit listeners are synchronous.

    // Swift addition: the carriers are members of upstream's task and submission JSON. A task record decodes `trace` and
    // `links` as fields, not extension members; a submission keeps `trace` among its state's extension members, read
    // by `SubmissionRecord.trace`, through every state change.
    @Test func storesCarriersInUpstreamsTaskAndSubmissionJSON() async throws {
        let task = try JSONValue(jsonText: #"{"id":7,"conversationId":1,"kind":"test","version":1,"input":null,"#
            + #""state":{"status":"pending","checkpoint":{"phase":"run"}},"background":false,"abortRequested":false,"#
            + #""trace":{"pi-memory-scope":"s","pi-memory-span":"1"},"links":[{"pi-memory-span":"2"}]}"#)
        let record = try task.decode(TaskRecord.self)
        #expect(record.trace == ["pi-memory-scope": "s", "pi-memory-span": "1"])
        #expect(record.links == [["pi-memory-span": "2"]])
        #expect(record.extensionFields.isEmpty)
        let encoded = try JSONValue(encoding: record).objectValue
        #expect(encoded?["trace"] == task.objectValue?["trace"] && encoded?["links"] == task.objectValue?["links"])
        #expect(record.replacing(state: .running(checkpoint: .object(["phase": "run"]))).trace == record.trace)

        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let opened = try await openTracked(MemoryStorage(), setup, telemetry)
        let submission = try await opened.root.submit(.input(content: .text("input")), context: .background)
        _ = try await submission.wait(context: .background)
        let settled = try await submission.status(context: .background)
        #expect(settled.status == "done")
        let json = try #require(try JSONValue(encoding: settled).objectValue)
        #expect(try json["trace"]?.decode(TelemetryCarrier.self) == settled.trace)
        #expect(settled.trace == telemetry.getSpans().first { $0.name == "pi.durable.submit" }?.context)
        try await opened.harness.close(context: .background)
    }

    // Swift: upstream answers the nested call from a code mode journal; code mode is not ported, so a replay-safe tool
    // makes the nested call itself, and its rerun after a reopen finds the stored result.
    @Test func emitsReplayForANestedCallAnsweredFromItsStoredResultWithoutRerunningIt() async throws {
        let setup = HarnessChatSetup(), telemetry = InMemoryTelemetryContext(), storage = ControlledStorage()
        let runs = RunCount(), recover = Mutex(false), reached = HarnessChatSignal()
        try installHarnessTool(try ToolRegistration(name: "once", description: "once", parameters: ["type": "object"]) { _, _, _ in
            runs.increment()
            return ToolExecutionResult(output: [])
        }, setup: setup)
        try installHarnessTool(try ToolRegistration(name: "hold", description: "hold", parameters: ["type": "object"], replay: .safe) { _, api, context in
            _ = try await api.executeTool("once", context: context)
            if !recover.withLock({ $0 }) {
                reached.signal()
                try await harnessToolAwaitAbort(context)
            }
            return ToolExecutionResult(output: [])
        }, setup: setup)
        setup.models.setResponses([.message(try toolReply("hold")), .message(chatAssistant("done"))])
        var opened = try await openTracked(storage, setup, telemetry)
        let submission = try await opened.root.submit(.input(content: .text("run")), context: .background)
        await reached.wait()
        try await opened.harness.close(context: .background)
        recover.withLock { $0 = true }
        opened = try await openTracked(storage.reopen(), setup, telemetry)
        _ = try await try #require(try await opened.harness.submission(id: submission.id, context: .background)).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await settled(telemetry)
        #expect(runs.value == 1)
        #expect(telemetry.getSpans().flatMap(\.events).contains(RecordedTelemetryEvent(name: "pi.durable.replay", attributes: ["tool.name": "once"])))
        try await opened.harness.close(context: .background)
    }
}
