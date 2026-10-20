import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskBoundaryTests {
    // upstream harness-tasks.test.ts:1285,1386
    @Test(arguments: [false, true])
    func closeJoinsReservationWithoutStartingHandler(marked: Bool) async throws {
        let storage = ControlledStorage()
        let log = SessionTestLog<String>()
        let definition = harnessOneStep("test.reserve-close", run: { _, _, _ in log.append("run") }, abort: { _, _, _ in log.append("abort") })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        if marked {
            try await root.commit({ tx in
                let task = try #require(try await tx.task(id))
                try tx.setTask(task.replacing(abortRequested: true))
            }, context: .background)
        }
        let held = await storage.holdCommits()
        try harness.resume()
        await held.waitUntilEntered()
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        try await closing.value
        #expect(log.count == 0)
        // The reservation landed; close wrote the task back as pending.
        let commits = await storage.commits
        let reserved = commits.dropLast().last?.compactMap { write -> TaskRecord? in
            if case .task(let task, _) = write { return task }; return nil
        }
        #expect(reserved?.map(\.id) == [id])
        #expect(reserved?.first?.state.status == "running" && reserved?.first?.abortRequested == marked)
        guard case .task(let released, _)? = commits.last?.first, commits.last?.count == 1 else {
            Issue.record("Close must write only the stopped task"); return
        }
        #expect(released.id == id && released.state.status == "pending" && released.abortRequested == marked)
    }

    // upstream harness-tasks.test.ts:1309; lifecycle:450
    @Test func closeRejectsRuntimeCommitAlreadyQueuedOnLine() async throws {
        let retained = Mutex<TaskRuntime?>(nil)
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let storage = ControlledStorage()
        let definition = harnessOneStep("test.queue-close") { _, runtime, _ in
            retained.withLock { $0 = runtime }; entered.release(); await runRelease.wait()
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let held = await storage.holdCommits()
        let blocker = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "block")) }, context: .background) }
        await held.waitUntilEntered()
        let runtime = try #require(retained.withLock { $0 })
        let queued = Task { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        _ = try await blocker.value
        await #expect(throws: (any Error).self) { try await queued.value }
        runRelease.release()
        try await closing.value
        let writes = await storage.commits.flatMap { $0 }
        #expect(!writes.contains { if case .task(let task, _) = $0 { return task.id == id && task.state.status == "terminal" }; return false })
        // Created, reserved, and written back as pending by close; the queued outcome never landed.
        #expect(taskStatuses(writes, id) == ["pending", "running", "pending"])
    }

    // upstream harness-tasks.test.ts:1255
    @Test func closeWinsOverFailedPhaseStepQueuedOnLine() async throws {
        let storage = ControlledStorage()
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let definition = harnessOneStep("test.failed-step-close") { _, _, _ in
            entered.release(); await runRelease.wait(); throw TaskDefinitionError("would fault")
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let held = await storage.holdCommits()
        let blocker = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "block")) }, context: .background) }
        await held.waitUntilEntered()
        runRelease.release()
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        _ = try await blocker.value
        try await closing.value
        let writes = await storage.commits.flatMap { $0 }
        #expect(!writes.contains { if case .task(let task, _) = $0 { return task.id == id && task.state.status == "terminal" }; return false })
        // Created, reserved, and written back as pending by close: no fault.
        #expect(taskStatuses(writes, id) == ["pending", "running", "pending"])
    }

    // upstream harness-tasks.test.ts:1175,973
    @Test func closeAfterProgressStartsNoNextPhaseOrAbortHandler() async throws {
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let log = SessionTestLog<String>()
        let definition = harnessOneStep("test.progress-close", run: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                log.append("run")
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
                entered.release(); await runRelease.wait()
            case .joined: log.append("joined")
            }
        }, abort: { _, _, _ in log.append("abort") })
        let storage = ControlledStorage()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        let commits = await storage.commits.count
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        runRelease.release()
        _ = try await aborting.value
        try await closing.value
        #expect(log.values == ["run"])
        // No outcome: close writes only the stopped task back as pending, so a reopen counts no restart.
        let after = await storage.commits
        #expect(after.count == commits + 1)
        guard case .task(let released, _)? = after.last?.first, after.last?.count == 1 else {
            Issue.record("Close must write only the stopped task"); return
        }
        #expect(released.id == id && released.abortRequested)
        #expect(released.state == .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))))
    }
}

private func taskStatuses(_ writes: [StorageWrite], _ id: TaskID) -> [String] {
    writes.compactMap { write -> String? in
        if case .task(let task, _) = write, task.id == id { return task.state.status }; return nil
    }
}
