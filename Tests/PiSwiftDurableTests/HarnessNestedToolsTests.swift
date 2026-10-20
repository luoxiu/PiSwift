import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Returns `echo <text>` and counts its runs.
/// Counts runs across tasks.
final class RunCount: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    @discardableResult func increment() -> Int { state.withLock { $0 += 1; return $0 } }
}
private func echoTool(replay: ToolReplay? = nil) throws -> (registration: ToolRegistration, runs: RunCount) {
    let runs = RunCount()
    let registration = try nestedTool("echo", replay: replay) { args, _, _ in
        runs.increment()
        return .init(output: [.text(TextContent(text: "echo \(args["text"]?.stringValue ?? "")"))])
    }
    return (registration, runs)
}
private let paidUsage = Usage(input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3,
                              cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0, cacheWrite: 0, total: 0.3))
private func sameUsage(_ lhs: Usage?, _ rhs: Usage?) -> Bool { lhs.map(usageValue) == rhs.map(usageValue) }

/// Port of upstream `test/harness-nested-tools.test.ts`.
@Suite struct HarnessNestedToolsTests {
    @Test func storesOneDocumentPerNestedCallKeyedByItsKeyWrittenOnlyByThatCall() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            async let a = api.executeTool("echo", arguments: ["text": "a"], context: context)
            async let b = api.executeTool("echo", arguments: ["text": "b"], options: .init(key: "named"), context: context)
            _ = try await (a, b)
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: setup)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        // Per document written, the keys of the nested calls it holds.
        let written = await storage.commits.flatMap { $0 }.compactMap { write -> [String?]? in
            guard case .documentCreate(let record, _, _) = write else { return nil }
            return [record.kind, record.key]
        }
        // Concurrent calls commit in no fixed order in Swift; upstream's `Promise.all` admits them in call order.
        let nested = written.filter { $0[0]?.hasPrefix("pi.tool.") == true }.sorted { ($0[1] ?? "") < ($1[1] ?? "") }
        #expect(nested == [[NestedCallDoc.definition.kind, "1"], [NestedCallDoc.definition.kind, "named"]])
        try await opened.harness.close(context: .background)
    }

    @Test func rejectsANestedCallOfAnAbortedCallerAndLeavesNoDocumentForIt() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        let started = HarnessChatSignal(), marked = HarnessChatSignal()
        let rejected = Mutex<(any Error)?>(nil), caller = Mutex<TaskID?>(nil)
        try installHarnessTool(try nestedTool("late") { _, api, _ in
            caller.withLock { $0 = api.taskId }
            started.signal()
            await marked.wait()
            // Its context is aborted too, so pass one that is not: the admission itself must refuse.
            do { _ = try await api.executeTool("echo", arguments: ["text": "a"], context: .background) }
            catch { rejected.withLock { $0 = error } }
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("late")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let id = try #require(caller.withLock { $0 })
        try await opened.harness.commit({ tx in
            let record = try #require(try await tx.task(id))
            try tx.setTask(record.withAbortMark())
        }, context: .background)
        marked.signal()
        _ = try await submission.wait(context: .background)
        let error = String(describing: try #require(rejected.withLock { $0 }))
        #expect(["abort mark", "aborted", "has settled"].contains { error.contains($0) }, "\(error)")
        #expect(try await opened.harness.snapshot(NestedCallDoc, taskId: id, key: "1", context: .background) == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func runsANestedCallAsItsOwnToolTaskAndReturnsItsResultToTheCallerNotTheTranscript() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        let nested = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let result = try await api.executeTool("echo", arguments: ["text": "a"], context: context)
            nested.withLock { $0 = result }
            return .init(output: [.text(TextContent(text: "got \(nestedText(result))"))])
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(run.status == "done")
        let tasks = try await nestedToolTasks(run.harness)
        let parent = tasks[0], child = tasks[1]
        let result = try #require(nested.withLock { $0 })
        #expect(result == NestedToolExecutionResult(taskId: child.id, structuredOutput: "echo a", isError: false, diagnostics: [], durationMs: result.durationMs))
        #expect(result.durationMs != nil)
        // One result entry: the model-issued call's, which records nothing of its nested calls.
        let results = try harnessToolResults(run.entries)
        #expect(results.map { [$0.toolCallId, harnessToolText($0)] } == [["c1", "got echo a"]])
        #expect(try nestedInput(parent) == .model(assistant: try #require(run.entries.first { $0.kind == assistantEntry.kind }?.id), callId: "c1"))
        #expect(child.owner == parent.id)
        #expect(try nestedInput(child) == .nested(.init(parent: parent.id, parentCallId: "c1", key: "1",
            call: .init(id: "c1/1", name: "echo", arguments: ["text": "a"]))))
        // The receipt stays small: the result lived in the caller's documents, which retired with it.
        #expect(child.state == .terminal(outcome: .completed(result: ["kind": "nested"])))
        #expect(try await run.harness.snapshot(NestedCallDoc, taskId: parent.id, key: "1", context: .background) == nil)
        #expect(try await run.harness.snapshot(LiveDoc, conversationId: run.root.id, context: .background) == LiveState())
        try await run.harness.close(context: .background)
    }

    @Test func givesEachNestedCallItsOwnTaskAndCallID() async throws {
        let setup = HarnessChatSetup(), seen = SessionTestLog<(TaskID, String)>()
        try installHarnessTool(try nestedTool("who") { _, api, _ in seen.append((api.taskId, api.callId)); return .init() }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            async let a = api.executeTool("who", options: .init(key: "a"), context: context)
            async let b = api.executeTool("who", options: .init(key: "b"), context: context)
            _ = try await (a, b)
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(seen.values.map(\.1).sorted() == ["c1/a", "c1/b"])
        #expect(Set(seen.values.map(\.0)).count == 2)
        try await run.harness.close(context: .background)
    }

    @Test func runsTheToolHooksOnNestedCallsWhichSeeTheirParent() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        let parents = SessionTestLog<ToolHookCall.Parent?>()
        try installToolHooks(setup, ToolHooks(beforeTool: { call, _, _ in
            parents.append(call.parent)
            return call.parent != nil && call.arguments["text"]?.value as? String == "secret" ? BeforeToolResult(block: "no secrets") : nil
        }, afterTool: { call, result, _, _ in
            guard call.parent != nil else { return nil }
            var next = result; next.output = [.text(TextContent(text: "rewritten"))]; return next
        }))
        let nested = SessionTestLog<NestedToolExecutionResult>()
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            nested.append(try await api.executeTool("echo", arguments: ["text": "secret"], context: context))
            nested.append(try await api.executeTool("echo", arguments: ["text": "public"], context: context))
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        let parent = try await nestedToolTasks(run.harness)[0]
        #expect(parents.values == [nil, .init(taskId: parent.id, callId: "c1"), .init(taskId: parent.id, callId: "c1")])
        #expect(nested.values[0].isError)
        #expect(nested.values[0].diagnostics == [.init(severity: .error, message: "Tool call blocked: no secrets", code: "blocked")])
        #expect(nestedText(nested.values[1]) == "rewritten")
        #expect(echo.runs.value == 1)
        try await run.harness.close(context: .background)
    }

    @Test func returnsAnErrorResultForAnUnavailableToolAndInvalidArguments() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try echoTool().registration, setup: setup)
        let nested = SessionTestLog<NestedToolExecutionResult>()
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            nested.append(try await api.executeTool("missing", context: context))
            nested.append(try await api.executeTool("echo", arguments: ["text": ["not": "a string"]], context: context))
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(nested.values.map { [$0.isError ? "true" : "false", $0.diagnostics.first?.code ?? ""] } == [["true", "tool_unavailable"], ["true", "invalid_arguments"]])
        try await run.harness.close(context: .background)
    }

    @Test func returnsTheCallAKeyAlreadyNamesAndRejectsReusingTheKeyForAnotherCall() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        let reused = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("echo", arguments: ["text": "a"], options: .init(key: "k"), context: context)
            let again = try await api.executeTool("echo", arguments: ["text": "a"], options: .init(key: "k"), context: context)
            reused.withLock { $0 = again }
            _ = try await api.executeTool("echo", arguments: ["text": "b"], options: .init(key: "k"), context: context)
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(echo.runs.value == 1)
        #expect(nestedText(reused.withLock { $0 }) == "echo a")
        #expect(harnessToolText(try #require(try harnessToolResults(run.entries).first)).contains("Nested call c1/k was already made with another tool or other arguments"))
        try await run.harness.close(context: .background)
    }

    @Test func matchesAReusedKeysArgumentsRegardlessOfKeyOrder() async throws {
        let setup = HarnessChatSetup(), runs = Mutex(0)
        try installHarnessTool(try ToolRegistration(name: "pair", description: "pair", parameters: ["type": "object",
            "properties": ["a": ["type": "string"], "b": ["type": "string"]], "required": ["a", "b"]]) { args, _, _ in
                runs.withLock { $0 += 1 }
                return .init(output: [.text(TextContent(text: "\(args["a"]?.stringValue ?? "")\(args["b"]?.stringValue ?? "")"))])
            }, setup: setup)
        let nested = SessionTestLog<NestedToolExecutionResult>()
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            nested.append(try await api.executeTool("pair", arguments: JSONObject([("a", "x"), ("b", "y")]), options: .init(key: "k"), context: context))
            nested.append(try await api.executeTool("pair", arguments: JSONObject([("b", "y"), ("a", "x")]), options: .init(key: "k"), context: context))
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(runs.withLock { $0 } == 1)
        #expect(nested.values.map(nestedText) == ["xy", "xy"])
        try await run.harness.close(context: .background)
    }

    @Test func abortsTheNestedCallsACallerLeftRunningWhenItReturnsKeepingTheirDetails() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("hang") { _, api, context in
            try api.output(.text("partial\n"), nil)
            try await api.details(["step": 1], context)
            running.signal()
            return try await nestedAborted(context)
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            Task { _ = try? await api.executeTool("hang", context: context) }
            await running.wait()
            return .init(output: [.text(TextContent(text: "returned early"))])
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(settled.status == "done")
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(harnessToolText(result) == "returned early")
        let child = try await nestedToolTasks(opened.harness)[1]
        #expect(child.state == .terminal(outcome: .aborted(result: ["kind": "nested"])))
        // The aborted call's result keeps its details; programs get no partial output, which only the model read.
        let childEnd = try #require(nestedEnd(events.values, "c1/1")?.result)
        #expect(childEnd.isError && childEnd.details == ["step": 1])
        #expect(childEnd.structuredOutput == nil)
        // The nested call ends, with its result, before its caller.
        let ends = events.values.compactMap { event -> [String]? in
            if case .toolExecutionEnd(let call, _, let result) = event { return [call.toolCallId, result == nil ? "false" : "true"] }
            return nil
        }
        #expect(ends == [["c1/1", "true"], ["c1", "false"]])
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func recordsANestedCallsUsageUnderItsTool() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try nestedTool("paid") { _, _, _ in .init(usage: paidUsage) }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("paid", context: context); return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        let tools = try await run.harness.snapshot(UsageDoc, conversationId: run.root.id, context: .background)?.tools ?? [:]
        #expect(Array(tools.keys) == ["paid"] && sameUsage(tools["paid"], paidUsage))
        try await run.harness.close(context: .background)
    }

    @Test func reportsNestedCallsInLiveNestedToolsAndAsToolEventsWithTheirParent() async throws {
        let setup = HarnessChatSetup(), release = HarnessChatSignal(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("slow") { _, api, context in
            try api.output(.text("working\n"), nil)
            try await api.details(["step": 1], context)
            running.signal()
            await release.wait()
            return .init(output: [.text(TextContent(text: "slow done"))])
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let result = try await api.executeTool("slow", context: context)
            return .init(output: [.text(TextContent(text: nestedText(result)))])
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        #expect(watch.snapshot.nestedTools.isEmpty)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await running.wait()
        let live = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
        let slot = try #require(live.nestedTools?.first)
        #expect(live.nestedTools?.count == 1)
        #expect(slot.callId == "c1/1" && slot.parentCallId == "c1" && slot.name == "slow" && slot.arguments == [:])
        #expect(slot.status == .running && slot.output == "working\n" && slot.details == ["step": 1] && slot.summary == nil)
        release.signal()
        _ = try await submission.wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        #expect(nestedStartsAndEnds(events.values) == [
            ["tool_execution_start", "c1", nil], ["tool_execution_start", "c1/1", "c1"],
            ["tool_execution_end", "c1/1", "c1"], ["tool_execution_end", "c1", nil],
        ])
        let nestedEndEvent = try #require(nestedEnd(events.values, "c1/1"))
        #expect(nestedEndEvent.result?.structuredOutput == "slow done" && nestedEndEvent.result?.isError == false)
        // Events name the call's task and, for a nested call, the calling one.
        let tasks = try await nestedToolTasks(opened.harness)
        #expect(nestedEndEvent.call.taskId == tasks[1].id && nestedEndEvent.call.parentTaskId == tasks[0].id)
        let parentEnd = try #require(nestedEnd(events.values, "c1"))
        #expect(parentEnd.call.taskId == tasks[0].id && parentEnd.call.parentTaskId == nil)
        #expect(events.values.contains { event in
            if case .toolExecutionUpdate(let call, _, _, _) = event { return call.toolCallId == "c1/1" && call.parentToolCallId == "c1" }
            return false
        })
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func abortsNestedCallsWithTheirCaller() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("hang") { _, _, context in running.signal(); return try await nestedAborted(context) }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("hang", context: context); return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await running.wait()
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        let tasks = try await nestedToolTasks(opened.harness)
        #expect(nestedOutcome(tasks[1])?.status == "aborted")
        #expect(try nestedOutcome(tasks[1]).map { try JSONValue(encoding: $0) }?["result"]?["kind"] == "nested")
        #expect(nestedOutcome(tasks[0])?.status == "aborted")
        #expect(try nestedOutcome(tasks[0]).map { try JSONValue(encoding: $0) }?["result"]?["kind"] == "model")
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func abortsARunningNestedCallWhenItsCallerThrows() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("hang") { _, _, context in running.signal(); return try await nestedAborted(context) }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            Task { _ = try? await api.executeTool("hang", context: context) }
            await running.wait()
            throw TestFailure("caller failed")
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(run.status == "done")
        #expect(harnessToolText(try #require(try harnessToolResults(run.entries).first)).contains("caller failed"))
        #expect(nestedOutcome(try await nestedToolTasks(run.harness)[1])?.status == "aborted")
        try await run.harness.close(context: .background)
    }

    @Test func reattachesAReplaySafeCallerToTheNestedCallsItMadeBeforeARestart() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), echo = try echoTool(), blocked = HarnessChatSignal(), runs = Mutex(0)
        try installHarnessTool(echo.registration, setup: setup)
        try installHarnessTool(try nestedTool("batch", replay: .safe) { _, api, context in
            let run = runs.withLock { $0 += 1; return $0 }
            let first = try await api.executeTool("echo", arguments: ["text": "a"], context: context)
            if run == 1 { blocked.signal(); _ = try await nestedAborted(context) }
            // A call new to the rerun: its slot, after the reattached one's, is found and finishes.
            let second = try await api.executeTool("echo", arguments: ["text": "b"], context: context)
            return .init(output: [.text(TextContent(text: "run \(run): \(nestedText(first)), \(nestedText(second))"))])
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await blocked.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await #require(try await opened.harness.submission(id: id, context: .background)).wait(context: .background).status == "done")
        #expect(runs.withLock { $0 } == 2)
        #expect(echo.runs.value == 2)
        #expect(harnessToolText(try #require(try harnessToolResults(try await allEntries(opened.root)).first)) == "run 2: echo a, echo b")
        let tasks = try await nestedToolTasks(opened.harness)
        #expect(try tasks.filter { try nestedInput($0).kind == "nested" }.count == 2)
        #expect(try nestedOutcome(tasks[1]).map { try JSONValue(encoding: $0) }?["result"]?["kind"] == "nested")
        try await opened.harness.close(context: .background)
    }

    @Test func stopsOnlyTheWaitWhenACallerCancelsItTheCallRunsOnAndItsKeyReturnsItsResult() async throws {
        let setup = HarnessChatSetup(), cancel = AbortController(), release = HarnessChatSignal()
        let attempts = SessionTestLog<String>(), retry = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("slow") { _, _, _ in
            cancel.abort(TestFailure("cancelled"))
            await release.wait()
            return .init(output: [.text(TextContent(text: "slow done"))])
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            do {
                _ = try await api.executeTool("slow", options: .init(key: "same"), context: context.withAbortSignal(cancel.signal))
                attempts.append("first done")
            } catch { attempts.append("first cancelled") }
            release.signal()
            let result = try await api.executeTool("slow", options: .init(key: "same"), context: context)
            retry.withLock { $0 = result }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(attempts.values == ["first cancelled"])
        #expect(retry.withLock { $0 }?.isError == false && retry.withLock { $0 }?.structuredOutput == "slow done")
        #expect(try await nestedToolTasks(run.harness).count == 2)
        try await run.harness.close(context: .background)
    }

    @Test func admitsOneNestedCallForAKeyUsedByConcurrentCalls() async throws {
        let setup = HarnessChatSetup(), echo = try echoTool()
        try installHarnessTool(echo.registration, setup: setup)
        let both = Mutex<[NestedToolExecutionResult]>([])
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            async let first = api.executeTool("echo", arguments: ["text": "a"], options: .init(key: "k"), context: context)
            async let second = api.executeTool("echo", arguments: ["text": "a"], options: .init(key: "k"), context: context)
            let results = try await [first, second]
            both.withLock { $0 = results }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(echo.runs.value == 1)
        #expect(both.withLock { $0 }.map(nestedText) == ["echo a", "echo a"])
        #expect(try await nestedToolTasks(run.harness).count == 2)
        try await run.harness.close(context: .background)
    }

    @Test func abortsLeftRunningNestedCallsOfACallerInterruptedWhileItCleanedThemUp() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), cleaning = HarnessChatSignal(), release = HarnessChatSignal()
        let hangRuns = Mutex(0)
        try installHarnessTool(try nestedTool("hang") { _, api, context in
            hangRuns.withLock { $0 += 1 }
            try api.output(.text("partial\n"), nil)
            try await api.details(["step": 1], context)
            running.signal()
            _ = try? await nestedAborted(context)
            // The caller's cleanup waits for this abort; hold it there until the Harness closes.
            cleaning.signal()
            await release.wait()
            throw TestFailure("aborted")
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            Task { _ = try? await api.executeTool("hang", context: context) }
            await running.wait()
            return .init(output: [.text(TextContent(text: "returned early"))])
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await cleaning.wait()
        let harness = opened.harness
        let closing = Task { try await harness.close(context: .background) }
        release.signal()
        try await closing.value

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await #require(try await opened.harness.submission(id: id, context: .background)).wait(context: .background).status == "done")
        try await opened.harness.waitForIdle(context: .background)
        // The caller is replay-unsafe: it reports the interruption, and its cleanup aborts the nested call.
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(result.toolCallId == "c1" && result.isError)
        #expect(harnessToolText(result).contains("Tool batch was interrupted"))
        #expect(nestedOutcome(try await nestedToolTasks(opened.harness)[1])?.status == "aborted")
        #expect(hangRuns.withLock { $0 } == 1)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func abortsANestedCallWhoseAdmissionWasStillCommittingWhenItsCallerReturned() async throws {
        let setup = HarnessChatSetup(), storage = ControlledStorage()
        try installHarnessTool(try echoTool().registration, setup: setup)
        try installHarnessTool(try nestedTool("hang") { _, _, context in try await nestedAborted(context) }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("echo", arguments: ["text": "warm"], options: .init(key: "warm"), context: context)
            // Hold the late call's admission commit in storage while the caller returns.
            let held = await storage.holdCommits()
            Task { _ = try? await api.executeTool("hang", options: .init(key: "late"), context: context) }
            await held.waitUntilEntered()
            Task { try? await Task.sleep(for: .milliseconds(20)); await held.release() }
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(storage: storage, setup: setup)
        let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(settled.status == "done")
        let late = try await nestedToolTasks(opened.harness).first { record in
            if case .nested(let input) = try nestedInput(record) { return input.call.name == "hang" }
            return false
        }
        #expect(nestedOutcome(try #require(late))?.status == "aborted")
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func abortsEveryLeftRunningNestedCallBeforeWaitingForAny() async throws {
        let setup = HarnessChatSetup(), bAborted = HarnessChatSignal(), startedA = HarnessChatSignal(), startedB = HarnessChatSignal()
        // A only stops once B was told to stop.
        try installHarnessTool(try nestedTool("a") { _, _, _ in startedA.signal(); await bAborted.wait(); return .init() }, setup: setup)
        try installHarnessTool(try nestedTool("b") { _, _, context in
            startedB.signal()
            _ = try? await nestedAborted(context)
            bAborted.signal()
            throw TestFailure("aborted")
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            Task { _ = try? await api.executeTool("a", options: .init(key: "a"), context: context) }
            Task { _ = try? await api.executeTool("b", options: .init(key: "b"), context: context) }
            await startedA.wait(); await startedB.wait()
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(run.status == "done")
        #expect(try await nestedOnlyTasks(run.harness).map(\.state.status) == ["terminal", "terminal"])
        try await run.harness.close(context: .background)
    }

    @Test func rejectsExplicitKeysThatAreEmptyHaveASlashAreProtoOrArePositiveIntegers() async throws {
        let setup = HarnessChatSetup(), errors = SessionTestLog<String>()
        try installHarnessTool(try echoTool().registration, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            for key in ["", "a/b", "__proto__", "7"] {
                do { _ = try await api.executeTool("echo", options: .init(key: key), context: context) }
                catch { errors.append(String(describing: error)) }
            }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        let rule = "must be non-empty, without \"/\", not \"__proto__\", and not a positive integer"
        #expect(errors.values == ["Nested call key \"\" \(rule)", "Nested call key \"a/b\" \(rule)",
                                  "Nested call key \"__proto__\" \(rule)", "Nested call key \"7\" \(rule)"])
        try await run.harness.close(context: .background)
    }

    @Test func runsNestedCallsOfNestedCallsAndEndsThemChildrenFirst() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(try echoTool().registration, setup: setup)
        try installHarnessTool(try nestedTool("inner") { _, api, context in
            let result = try await api.executeTool("echo", arguments: ["text": "deep"], options: .init(key: "x"), context: context)
            return .init(output: [.text(TextContent(text: nestedText(result)))])
        }, setup: setup)
        try installHarnessTool(try nestedTool("outer") { _, api, context in
            let result = try await api.executeTool("inner", context: context)
            return .init(output: [.text(TextContent(text: nestedText(result)))])
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("outer")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        #expect(harnessToolText(try #require(try harnessToolResults(try await allEntries(opened.root)).first)) == "echo deep")
        let tasks = try await nestedToolTasks(opened.harness)
        #expect([tasks[1].owner, tasks[2].owner] == [tasks[0].id, tasks[1].id])
        #expect(nestedStartsAndEnds(events.values) == [
            ["tool_execution_start", "c1", nil], ["tool_execution_start", "c1/1", "c1"], ["tool_execution_start", "c1/1/x", "c1/1"],
            ["tool_execution_end", "c1/1/x", "c1/1"], ["tool_execution_end", "c1/1", "c1"], ["tool_execution_end", "c1", nil],
        ])
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func reportsTheOutputOfSeveralRunningNestedCallsAndShowsThemToALateSubscriber() async throws {
        let setup = HarnessChatSetup(), release = HarnessChatSignal()
        let running = ["one": HarnessChatSignal(), "two": HarnessChatSignal()], wrote = ["one": HarnessChatSignal(), "two": HarnessChatSignal()]
        try installHarnessTool(try nestedTool("slow") { args, api, context in
            let name = args["text"]?.stringValue ?? ""
            running[name]?.signal()
            await wrote[name]?.wait()
            try api.output(.text("\(name)\n"), nil)
            try await api.details(["name": .string(name)], context)
            await release.wait()
            return .init()
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            async let one = api.executeTool("slow", arguments: ["text": "one"], context: context)
            async let two = api.executeTool("slow", arguments: ["text": "two"], context: context)
            _ = try await (one, two)
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await running["one"]!.wait(); await running["two"]!.wait()
        try await eventually {
            try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.nestedTools?.allSatisfy { $0.status == .running } == true
        }
        let watch = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
        #expect(Set(watch.snapshot.nestedTools.map(\.callId)) == ["c1/1", "c1/2"])
        #expect(watch.snapshot.nestedTools.allSatisfy { $0.status == .running })
        let updates = SessionTestLog<(String, DurableToolOutputChange)>()
        try watch.start { batch, _ in
            for event in batch {
                if case .toolExecutionUpdate(let call, let output?, _, _) = event { updates.append((call.toolCallId, output)) }
            }
        }
        let byText = Dictionary(uniqueKeysWithValues: try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)!.nestedTools!.map {
            ($0.arguments["text"]?.stringValue ?? "", $0.callId)
        })
        // The second slot writes first, so a wrong slot index in the update path would show.
        wrote["two"]!.signal()
        try await eventually { updates.count == 1 }
        wrote["one"]!.signal()
        try await eventually { updates.count == 2 }
        release.signal()
        _ = try await submission.wait(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        #expect(updates.values.map(\.0) == [byText["two"]!, byText["one"]!])
        #expect(updates.values.map(\.1) == [.set("two\n"), .set("one\n")])
        try await opened.harness.close(context: .background)
    }

    @Test func commitsOnlyTheStatusOfANestedCallMadeWithProgressFalseAndKeepsItsOutputInTheResult() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), release = HarnessChatSignal()
        let result = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("chatty") { _, api, context in
            try api.output(.text("line\n"), nil)
            try api.diagnostic(.init(severity: .info, message: "note"))
            try await api.details(["step": 1], context)
            running.signal()
            await release.wait()
            return .init()
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let value = try await api.executeTool("chatty", options: .init(progress: false), context: context)
            result.withLock { $0 = value }
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        // `details()` resolved before this, so a progress commit would have landed already.
        await running.wait()
        let slot = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.nestedTools?.first)
        #expect(slot.callId == "c1/1" && slot.status == .running && slot.arguments == [:])
        #expect(slot.output == nil && slot.details == nil && slot.diagnostics == nil && slot.summary == nil)
        release.signal()
        _ = try await submission.wait(context: .background)
        let value = try #require(result.withLock { $0 })
        #expect(value.structuredOutput == "line\n" && value.details == ["step": 1])
        #expect(value.diagnostics == [.init(severity: .info, message: "note")])
        try await opened.harness.close(context: .background)
    }

    @Test func losesTheRunningOutputOfANestedCallMadeWithProgressFalseWhenItIsAborted() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("chatty") { _, api, context in
            try api.output(.text("line\n"), nil)
            try api.diagnostic(.init(severity: .info, message: "note"))
            try await api.details(["step": 1], context)
            running.signal()
            return try await nestedAborted(context)
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            Task { _ = try? await api.executeTool("chatty", options: .init(progress: false), context: context) }
            await running.wait()
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        // The abort's result is built from the slot, which never got the output.
        let result = try #require(nestedEnd(events.values, "c1/1")?.result)
        #expect(result.isError && result.structuredOutput == nil && result.details == nil)
        #expect(nestedCodes(result) == ["aborted"])
        try await opened.harness.close(context: .background)
    }

    @Test func showsANestedCallsArgumentsInItsSlotAsMadeThenUnboundedAsItRunsWithThem() async throws {
        let setup = HarnessChatSetup(), hookEntered = HarnessChatSignal(), hookRelease = HarnessChatSignal()
        let running = HarnessChatSignal(), release = HarnessChatSignal()
        let large = String(repeating: "x", count: 64 * 1024)
        try installHarnessTool(try nestedTool("slow") { _, _, _ in running.signal(); await release.wait(); return .init() }, setup: setup)
        try installToolHooks(setup, ToolHooks(beforeTool: { call, _, _ in
            guard call.parent != nil else { return nil }
            hookEntered.signal(); await hookRelease.wait()
            return BeforeToolResult(arguments: ["text": .string(large)])
        }))
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("slow", arguments: ["text": "asked"], context: context); return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        let slot = { try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.nestedTools?.first) }
        await hookEntered.wait()
        let pending = try await slot()
        #expect(pending.status == .pending && pending.arguments == ["text": "asked"])
        hookRelease.signal()
        await running.wait()
        let runningSlot = try await slot()
        #expect(runningSlot.status == .running && runningSlot.arguments == ["text": .string(large)])
        release.signal()
        _ = try await submission.wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        // The start event carries the arguments the call runs with; the task input keeps the ones it was made with.
        let start = events.values.first { event in
            if case .toolExecutionStart(let call, _) = event { return call.toolCallId == "c1/1" }
            return false
        }
        if case .toolExecutionStart(_, let args)? = start { #expect(args == ["text": .string(large)]) } else { Issue.record("No nested start event") }
        let nested = try #require(try await nestedOnlyTasks(opened.harness).first)
        if case .nested(let input) = try nestedInput(nested) { #expect(input.call.arguments == ["text": "asked"]) }
        try await opened.harness.close(context: .background)
    }

    /// Upstream sets an optional property to undefined; Swift JSON has no undefined, so repair drops the property.
    @Test func runsANestedCallWhoseRepairedArgumentsDropAnOptionalProperty() async throws {
        let setup = HarnessChatSetup(), seen = SessionTestLog<JSONObject>()
        try installHarnessTool(try nestedTool("repaired", prepare: { _ in .object([:]) }) { args, _, _ in seen.append(args); return .init() }, setup: setup)
        let result = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let value = try await api.executeTool("repaired", arguments: ["text": "x"], context: context)
            result.withLock { $0 = value }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        #expect(result.withLock { $0 }?.isError == false)
        #expect(seen.values == [[:]])
        try await run.harness.close(context: .background)
    }

    @Test func findsEachNestedCallsSlotAfterSlotsInTheMiddleWereRemoved() async throws {
        let setup = HarnessChatSetup(), before = HarnessChatSignal(), checked = HarnessChatSignal()
        let slots = Mutex<[NestedToolSlot]>([])
        try installHarnessTool(try echoTool().registration, setup: setup)
        try installHarnessTool(try nestedTool("inner") { _, api, context in
            _ = try await api.executeTool("echo", arguments: ["text": "m1"], context: context)
            _ = try await api.executeTool("echo", arguments: ["text": "m2"], context: context)
            return .init()
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("echo", arguments: ["text": "n1"], context: context)
            // n2 makes m1 and m2 and settles, which removes them from between n2 and n3.
            _ = try await api.executeTool("inner", context: context)
            _ = try await api.executeTool("echo", arguments: ["text": "n3"], context: context)
            _ = try await api.executeTool("echo", arguments: ["text": "n4"], context: context)
            let live = try await api.read.snapshot(LiveDoc, conversationId: api.conversationId, context: context)
            slots.withLock { $0 = live?.nestedTools ?? [] }
            before.signal(); await checked.wait()
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await before.wait()
        let found = slots.withLock { $0 }
        #expect(found.map(\.callId) == ["c1/1", "c1/2", "c1/3", "c1/4"])
        #expect(found.allSatisfy { $0.status == .done && $0.summary?.isError == false && $0.summary?.durationMs != nil })
        checked.signal()
        _ = try await submission.wait(context: .background)
        try await opened.harness.close(context: .background)
    }

    @Test func givesCallersAResultWithItsTaskIDAndOnlyDiagnosticsForANestedCallTheSchedulerFaulted() async throws {
        let setup = HarnessChatSetup()
        // Details that are not strict JSON make the result commit throw, so the task faults and stores no result.
        try installHarnessTool(try nestedTool("echo") { _, _, _ in .init(details: ["count": .number(.nan)]) }, setup: setup)
        let result = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let value = try await api.executeTool("echo", arguments: ["text": "a"], context: context)
            result.withLock { $0 = value }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        let child = try await nestedToolTasks(run.harness)[1]
        #expect(nestedOutcome(child)?.status == "faulted")
        let value = try #require(result.withLock { $0 })
        #expect(value.taskId == child.id && value.isError && value.structuredOutput == nil && value.details == nil)
        #expect(value.diagnostics.count == 1 && value.diagnostics[0].code == "faulted" && value.diagnostics[0].severity == .error)
        #expect(value.diagnostics[0].message.contains("Tool echo failed"))
        try await run.harness.close(context: .background)
    }

    @Test func givesCallersWhatASchemaLessToolStreamedBeforeItThrew() async throws {
        let setup = HarnessChatSetup(), result = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(try nestedTool("fails") { _, api, _ in
            try api.output(.text("half way\n"), nil)
            throw TestFailure("broke")
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            let value = try await api.executeTool("fails", context: context)
            result.withLock { $0 = value }
            return .init()
        }, setup: setup)
        let run = try await runNestedOnce(setup, [try nestedCall("batch"), nestedDone])
        let value = try #require(result.withLock { $0 })
        #expect(value.isError && value.structuredOutput == "half way\n")
        #expect(value.diagnostics.map(\.code) == ["tool_error"] && value.diagnostics.first?.message == "broke")
        try await run.harness.close(context: .background)
    }

    @Test func showsAFinishedNestedCallAsADoneSlotWithItsSummaryUntilItsCallerSettles() async throws {
        let setup = HarnessChatSetup(), release = HarnessChatSignal(), checked = HarnessChatSignal()
        // Diagnostics win over output for the error text, which is cut to 500 characters.
        try installHarnessTool(try nestedTool("verbose") { _, _, _ in
            .init(output: [.text(TextContent(text: "ignored"))], isError: true,
                  diagnostics: [.init(severity: .error, message: String(repeating: "e", count: 600))])
        }, setup: setup)
        try installHarnessTool(try echoTool().registration, setup: setup)
        try installHarnessTool(try nestedTool("paid") { _, _, _ in .init(usage: paidUsage) }, setup: setup)
        // An error with mixed content: programs get the list, the summary its text.
        try installHarnessTool(try nestedTool("broken") { _, _, _ in
            .init(output: [.text(TextContent(text: "bad image")), .image(ImageContent(data: "AAAA", mimeType: "image/png"))], isError: true)
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            _ = try await api.executeTool("echo", arguments: ["text": "a"], context: context)
            _ = try await api.executeTool("missing", context: context)
            _ = try await api.executeTool("paid", context: context)
            _ = try await api.executeTool("broken", context: context)
            _ = try await api.executeTool("verbose", context: context)
            checked.signal(); await release.wait()
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await checked.wait()
        let slots = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.nestedTools)
        #expect(slots.map(\.callId) == ["c1/1", "c1/2", "c1/3", "c1/4", "c1/5"])
        #expect(slots.allSatisfy { $0.status == .done })
        let summaries = slots.map { $0.summary }
        #expect(summaries[0]?.isError == false && summaries[0]?.durationMs != nil && summaries[0]?.error == nil)
        #expect(summaries[1] == NestedToolSummary(isError: true, error: "Tool missing is not available"))
        #expect(summaries[2]?.isError == false && summaries[2]?.durationMs != nil && sameUsage(summaries[2]?.usage, paidUsage))
        #expect(summaries[3]?.isError == true && summaries[3]?.durationMs != nil && summaries[3]?.error == "bad image")
        #expect(summaries[4]?.isError == true && summaries[4]?.error == String(repeating: "e", count: 500))
        release.signal()
        _ = try await submission.wait(context: .background)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func migratesVersion1ToolTaskInputToAModelIssuedCall() throws {
        let migrate = try #require(toolTask.migrate)
        let migrated = try migrate(["assistant": 3, "callId": "c1"], ["phase": "call"], 1)
        #expect(migrated.input == .model(assistant: try EntryID(3), callId: "c1"))
        #expect(migrated.checkpoint.phase == .call)
    }
}

/// Port of upstream `test/harness-nested-tools.test.ts` "tool task version 1 records".
@Suite struct HarnessToolTaskVersion1Tests {
    /// Store a live tool task for call `c1` of an assistant entry, close, and rewrite its record as version 1 stored it:
    /// `{ assistant, callId }` input at version 1, with `checkpoint`.
    private func storeVersion1(_ setup: HarnessChatSetup, path: String, checkpoint: JSONValue) async throws -> TaskID {
        // No submission, so the Harness never starts scheduling and the task stays pending.
        let opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.commit({ tx in
            let entry = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: assistantEntry.kind,
                model: EntryRecord.encodeMessages([.assistant(try nestedCall("echo", ["text": "old"]))])))
            return try await tx.createTask(toolTask, input: .model(assistant: entry.id, callId: "c1"), options: .init(ownership: .conversation()))
        }, context: .background)
        try await opened.harness.close(context: .background)
        let storage = try await SqliteStorage.open(path: path)
        let record = try #require(try await storage.task(id, context: .background))
        guard case .model(let assistant, let callId) = try record.input.decode(ToolTaskInput.self) else { throw TestFailure("Expected a model input") }
        let input: JSONValue = ["assistant": try JSONValue(encoding: assistant), "callId": .string(callId)]
        let rewritten = TaskRecord(id: record.id, conversationId: record.conversationId, kind: record.kind, version: 1,
                                   input: input, state: .pending(checkpoint: checkpoint), owner: record.owner,
                                   background: record.background)
        _ = try await storage.commit([.task(value: rewritten)], context: .background)
        try await storage.close(context: .background)
        return id
    }

    @Test func migratesAPendingVersion1TaskAndRunsItAsAModelIssuedCall() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), runs = Mutex(0)
        try installHarnessTool(try nestedTool("echo") { args, _, _ in
            runs.withLock { $0 += 1 }
            return .init(output: [.text(TextContent(text: "echo \(args["text"]?.stringValue ?? "")"))])
        }, setup: setup)
        let id = try await storeVersion1(setup, path: path, checkpoint: ["phase": "call"])
        let opened = try await nestedOpenSqlite(path, setup)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.version == 1)
        try opened.harness.resume()
        let settled = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(settled.record.version == 2)
        #expect(try settled.record.input.decode(ToolTaskInput.self).kind == "model")
        #expect(settled.outcome.status == "completed")
        #expect(try JSONValue(encoding: settled.outcome)["result"]?["kind"] == "model")
        #expect(runs.withLock { $0 } == 1)
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(result.toolCallId == "c1" && harnessToolText(result) == "echo old")
        try await opened.harness.close(context: .background)
    }

    @Test func migratesAVersion1TaskInterruptedAfterIntentAndSettlesItInterrupted() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), runs = Mutex(0)
        try installHarnessTool(try nestedTool("echo") { _, _, _ in runs.withLock { $0 += 1 }; return .init() }, setup: setup)
        let id = try await storeVersion1(setup, path: path, checkpoint: ["phase": "execute", "arguments": ["text": "old"], "replay": "unsafe"])
        let opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        let settled = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(settled.record.version == 2)
        #expect(settled.outcome.status == "failed")
        #expect(try JSONValue(encoding: settled.outcome)["result"]?["kind"] == "model")
        #expect(runs.withLock { $0 } == 0)
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(result.toolCallId == "c1" && result.isError)
        #expect(harnessToolText(result).contains("Tool echo was interrupted"))
        try await opened.harness.close(context: .background)
    }
}
