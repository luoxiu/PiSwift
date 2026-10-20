import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Runs until aborted; its abort handler records the reason and ends it `aborted`.
private func worker(_ name: String, phases: SessionTestLog<String>? = nil, aborts: SessionTestLog<String?>? = nil,
                    started: HarnessChatSignal) -> HarnessTestTask {
    harnessOneStep(name, run: { _, runtime, _ in
        phases?.append("work")
        started.signal()
        try await harnessToolAwaitAbort(runtime.context)
    }, abort: { task, runtime, context in
        aborts?.append(task.abortReason?.rawValue)
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}
/// A tool that creates `task` as its child and waits for it.
private func spawn(_ task: HarnessTestTask, created: SessionTestLog<TaskID>) throws -> ToolRegistration {
    try nestedTool("spawn") { _, api, context in
        let id = try await api.createTask(task, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
        created.append(id)
        _ = try await api.waitForTask(id: id, context: context)
        return .init()
    }
}
/// A tool that calls `name` as a nested call.
private func batch(_ name: String) throws -> ToolRegistration {
    try nestedTool("batch") { _, api, context in _ = try await api.executeTool(name, context: context); return .init() }
}
private func submissionStatus(_ opened: OpenChatResult, _ id: SubmissionID) async throws -> String {
    try await #require(try await opened.harness.submission(id: id, context: .background)).wait(context: .background).status
}

/// Port of upstream `test/harness-nested-tools-restart.test.ts`.
@Suite struct HarnessNestedToolsRestartTests {
    @Test func abandonsAReplayUnsafeCallersUnfinishedNestedCallsBeforeTheyRunAgain() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), gated = HarnessChatSignal()
        let startedRuns = RunCount(), gatedRuns = RunCount()
        // Replay-safe, so only the abandonment keeps it from rerunning.
        try installHarnessTool(try nestedTool("started", replay: .safe) { _, api, context in
            startedRuns.increment()
            try api.output(.text("partial\n"), nil)
            try await api.details(["step": 1], context)
            running.signal()
            return try await nestedAborted(context)
        }, setup: setup)
        try installHarnessTool(try nestedTool("gated") { _, _, _ in gatedRuns.increment(); return .init() }, setup: setup)
        // Holds `gated` in its `call` phase, before intent, until the Harness closes.
        try installToolHooks(setup, ToolHooks(beforeTool: { call, _, context in
            guard call.name == "gated" else { return nil }
            gated.signal()
            try await harnessToolAwaitAbort(context)
            return nil
        }))
        try installHarnessTool(try nestedTool("batch") { _, api, context in
            async let first = api.executeTool("started", context: context)
            async let second = api.executeTool("gated", context: context)
            _ = try await (first, second)
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await running.wait(); await gated.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        let (watch, events) = try await nestedEvents(opened.harness, opened.root.id)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        try await opened.harness.waitForIdle(context: .background)
        await watch.waitUntilIdle(); _ = await watch.stop()
        #expect(startedRuns.value == 1 && gatedRuns.value == 0)
        let nested = try await nestedOnlyTasks(opened.harness)
        #expect(nested.count == 2)
        for task in nested {
            #expect(task.abandonOnRestart && task.abortRequested && task.abortReason == .restart)
            #expect(nestedOutcome(task)?.status == "aborted")
        }
        // Concurrent calls start in no fixed order in Swift, so their default keys do not either: find them by tool.
        let end = { (name: String) in events.values.lazy.compactMap { event -> NestedToolExecutionResult? in
            if case .toolExecutionEnd(let call, _, let result) = event, call.toolName == name { return result }
            return nil
        }.first }
        let first = try #require(end("started"))
        #expect(nestedCodes(first) == ["interrupted"])
        #expect(first.isError && first.details == ["step": 1] && first.structuredOutput == nil)
        #expect(nestedCodes(end("gated")) == ["abandoned"])
        // The caller reports the interruption.
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(result.toolCallId == "c1" && result.isError)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func abandonsTheWorkAnAbandonedNestedCallOwnsWhichNeverRunsAPhaseAgain() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), phases = SessionTestLog<String>(), aborts = SessionTestLog<String?>(), started = HarnessChatSignal()
        let task = worker("test.worker", phases: phases, aborts: aborts, started: started), created = SessionTestLog<TaskID>()
        try setup.registry.install(Extension(name: "worker", tasks: [AnyTaskDefinition(task)]))
        try installHarnessTool(try spawn(task, created: created), setup: setup)
        try installHarnessTool(try batch("spawn"), setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        try await opened.harness.waitForIdle(context: .background)
        #expect(phases.values == ["work"])
        // The cascade passed the restart reason on.
        #expect(aborts.values == ["restart"])
        let workerID = try #require(created.values.first)
        #expect(nestedOutcome(try await opened.harness.getTask(id: workerID, context: .background))?.status == "aborted")
        try await opened.harness.close(context: .background)
    }

    @Test func keepsAnAbandonedTaskWhoseDefinitionIsMissingWaitingUntilItIsInstalledThenRunsItsAbort() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), aborts = SessionTestLog<String?>(), started = HarnessChatSignal()
        let task = worker("test.late", aborts: aborts, started: started), created = SessionTestLog<TaskID>()
        let late = Extension(name: "late", tasks: [AnyTaskDefinition(task)])
        try setup.registry.install(late)
        try installHarnessTool(try spawn(task, created: created), setup: setup)
        try installHarnessTool(try batch("spawn"), setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await opened.harness.close(context: .background)

        setup.registry.uninstall(name: "late")
        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        let workerID = try #require(created.values.first)
        let harness = opened.harness
        try await eventually {
            let inspected = try await harness.inspect(context: .background).tasks.first { $0.record.id == workerID }
            if case .blocked? = inspected?.state { return true }
            return false
        }
        #expect(try await opened.harness.getTask(id: workerID, context: .background)?.state.status != "terminal")
        #expect(aborts.values.isEmpty)
        try setup.registry.install(late)
        #expect(try await submissionStatus(opened, id) == "done")
        #expect(aborts.values == ["restart"])
        #expect(nestedOutcome(try await opened.harness.getTask(id: workerID, context: .background))?.status == "aborted")
        try await opened.harness.close(context: .background)
    }

    @Test func orphansAnAbandonedTaskWhoseDefinitionIsMissingOnceAnAbortIsRequested() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), started = HarnessChatSignal()
        let task = worker("test.gone", started: started), created = SessionTestLog<TaskID>()
        try setup.registry.install(Extension(name: "gone", tasks: [AnyTaskDefinition(task)]))
        try installHarnessTool(try spawn(task, created: created), setup: setup)
        try installHarnessTool(try batch("spawn"), setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await opened.harness.close(context: .background)

        setup.registry.uninstall(name: "gone")
        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        let workerID = try #require(created.values.first)
        let harness = opened.harness
        try await eventually { try await harness.getTask(id: workerID, context: .background)?.abortReason == .restart }
        try await opened.root.abort(context: .background)
        #expect(nestedOutcome(try await opened.harness.getTask(id: workerID, context: .background)) == TaskOutcome.orphaned(reason: "missing_task"))
        #expect(try await submissionStatus(opened, id) == "unanswered")
        try await opened.harness.close(context: .background)
    }

    @Test func marksNothingWhenTheReopenedHarnessNeverStartsScheduling() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(try nestedTool("hang") { _, _, context in running.signal(); return try await nestedAborted(context) }, setup: setup)
        try installHarnessTool(try batch("hang"), setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await running.wait()
        try await opened.harness.close(context: .background)

        // An inspection-only open: no resume, no submission.
        opened = try await nestedOpenSqlite(path, setup)
        #expect(try await opened.harness.inspect(context: .background).scheduling == .paused)
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        let nested = try #require(try await nestedOnlyTasks(opened.harness).first)
        #expect(nested.abandonOnRestart && !nested.abortRequested)
        #expect(nested.state.status == "pending")
        try await opened.harness.close(context: .background)
    }

    @Test func letsAReplaySafeCallersUnfinishedNestedCallsRecoverAndReattachesToThemByKey() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), safeRuns = RunCount(), unsafeRuns = RunCount(), callerRuns = RunCount()
        let runningSafe = HarnessChatSignal(), runningUnsafe = HarnessChatSignal()
        try installHarnessTool(try nestedTool("safe", replay: .safe) { _, _, context in
            let run = safeRuns.increment()
            if run == 1 { runningSafe.signal(); _ = try await nestedAborted(context) }
            return .init(output: [.text(TextContent(text: "safe run \(run)"))])
        }, setup: setup)
        try installHarnessTool(try nestedTool("unsafe") { _, _, context in
            unsafeRuns.increment(); runningUnsafe.signal(); return try await nestedAborted(context)
        }, setup: setup)
        let results = Mutex<[NestedToolExecutionResult]>([])
        try installHarnessTool(try nestedTool("batch", replay: .safe) { _, api, context in
            callerRuns.increment()
            // Concurrent calls start in no fixed order in Swift, so a rerun finds them by explicit keys; upstream relies
            // on default keys, which `Promise.all` assigns in call order.
            async let safe = api.executeTool("safe", options: .init(key: "safe"), context: context)
            async let unsafe = api.executeTool("unsafe", options: .init(key: "unsafe"), context: context)
            let values = try await [safe, unsafe]
            results.withLock { $0 = values }
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await runningSafe.wait(); await runningUnsafe.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        #expect([safeRuns.value, unsafeRuns.value, callerRuns.value] == [Int]([2, 1, 2]))
        // The keys named both calls, so the rerun found them.
        let nested = try await nestedOnlyTasks(opened.harness)
        #expect(nested.count == 2)
        for task in nested { #expect(!task.abandonOnRestart && task.abortReason == nil) }
        let values = results.withLock { $0 }
        let byName = Dictionary(uniqueKeysWithValues: try zip(values, values.map { value in
            try nested.first { $0.id == value.taskId }.map { record -> String in
                if case .nested(let input) = try nestedInput(record) { return input.call.name }
                return ""
            } ?? ""
        }).map { ($1, $0) })
        #expect(byName["safe"]?.structuredOutput == "safe run 2")
        #expect(nestedCodes(byName["unsafe"]) == ["interrupted"])
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: ["same", "swapped"])
    func reattachesAReplaySafeCallerByDefaultAndExplicitKeysAndRejectsARerunThatCallsDifferently(order: String) async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), runs = SessionTestLog<String>(), blocked = HarnessChatSignal(), callerRuns = RunCount()
        let seen = Mutex<[String]>([])
        try installHarnessTool(try nestedTool("echo") { args, _, _ in
            let text = args["text"]?.stringValue ?? ""
            runs.append(text)
            return .init(output: [.text(TextContent(text: "echo \(text)"))])
        }, setup: setup)
        try installHarnessTool(try nestedTool("batch", replay: .safe) { _, api, context in
            let run = callerRuns.increment()
            let first = run == 2 && order == "swapped" ? "b" : "a"
            let one = try await api.executeTool("echo", arguments: ["text": .string(first)], context: context)
            let named = try await api.executeTool("echo", arguments: ["text": "named"], options: .init(key: "named"), context: context)
            if run == 1 { blocked.signal(); _ = try await nestedAborted(context) }
            seen.withLock { $0 = [nestedText(one), nestedText(named)] }
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await blocked.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(runs.values == ["a", "named"])
        if order == "same" {
            #expect(seen.withLock { $0 } == ["echo a", "echo named"])
            #expect(!result.isError)
        } else {
            // Key 1 was made with other arguments: the rerun throws instead of reusing a different call's result.
            #expect(result.isError)
            #expect(harnessToolText(result).contains("Nested call c1/1 was already made with another tool"))
        }
        try await opened.harness.close(context: .background)
    }

    @Test func abandonsTheChildTasksAReplayUnsafeToolCreatedAndAwaitedInMemory() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), phases = SessionTestLog<String>(), started = HarnessChatSignal()
        let task = harnessOneStep("test.direct-worker", run: { _, runtime, _ in
            phases.append("work"); started.signal()
            try await harnessToolAwaitAbort(runtime.context)
        }, abort: { task, runtime, context in
            phases.append("abort \(task.abortReason?.rawValue ?? "nil")")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        try setup.registry.install(Extension(name: "direct-worker", tasks: [AnyTaskDefinition(task)]))
        try installHarnessTool(try nestedTool("work") { _, api, context in
            let id = try await api.createTask(task, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            _ = try await api.waitForTask(id: id, context: context)
            return .init()
        }, setup: setup)
        setup.models.setResponses([.message(try nestedCall("work")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        #expect(phases.values == ["work", "abort restart"])
        try await opened.harness.close(context: .background)
    }

    @Test func leavesBackgroundWorkUnderAnAbandonedNestedCallRunningAndSettlesWithoutIt() async throws {
        let (path, directory) = try nestedSqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(), started = HarnessChatSignal()
        let background = worker("test.background", started: started), created = SessionTestLog<TaskID>()
        try setup.registry.install(Extension(name: "background", tasks: [AnyTaskDefinition(background)]))
        try installHarnessTool(try nestedTool("spawn") { _, api, context in
            // A conversation the call owns, with background work in it, as a persistent subagent has.
            let id = try await api.commit({ tx in
                let child = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                return try await tx.createTask(background, input: 0, options: .init(ownership: .conversation(), conversationId: child.id, background: true))
            }, context: context)
            created.append(id)
            return try await nestedAborted(context)
        }, setup: setup)
        try installHarnessTool(try batch("spawn"), setup: setup)
        setup.models.setResponses([.message(try nestedCall("batch")), .message(nestedDone)])
        var opened = try await nestedOpenSqlite(path, setup)
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await opened.harness.close(context: .background)

        opened = try await nestedOpenSqlite(path, setup)
        try opened.harness.resume()
        #expect(try await submissionStatus(opened, id) == "done")
        let spawned = try #require(try await nestedOnlyTasks(opened.harness).first)
        #expect(spawned.abortReason == .restart && spawned.state.status == "terminal")
        let backgroundID = try #require(created.values.first)
        let record = try #require(try await opened.harness.getTask(id: backgroundID, context: .background))
        #expect(!record.abortRequested && record.state.status == "running")
        _ = try await opened.harness.abortTask(id: backgroundID, context: .background)
        try await opened.harness.close(context: .background)
    }
}
