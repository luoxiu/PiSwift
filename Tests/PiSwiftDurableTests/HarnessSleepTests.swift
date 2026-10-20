// Sleeping tasks: a durable `sleeping` state woken by the Harness clock, a host timer, or a host wakeup (upstream
// harness-sleep.test.ts).
import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct NapState: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case start, after }
    var phase: Phase = .start
    var slept: Int64?
}
private typealias NapTask = TaskDefinition<JSONValue, NapState, Int64, NoTaskHooks>

/// Sleeps `delay` ms on the Harness clock, then completes with the time it resumed at.
private func napTask(_ delay: Int64, runs: SessionTestLog<Int>? = nil, name: String = "test.nap") -> NapTask {
    NapTask(name: name, version: 1, initial: { _ in NapState() }, phase: { task, runtime, context in
        switch task.checkpoint.phase {
        case .start:
            try await runtime.sleepUntil(try runtime.now() + delay, checkpoint: NapState(phase: .after, slept: delay), context: context)
        case .after:
            runs?.append(1)
            let resumed = try runtime.now()
            try await runtime.commit({ _, _ in try completed(resumed) }, context: context)
        }
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in abortedWith("test") }, context: context)
    })
}

private func startNap(_ harness: Harness, _ task: NapTask) async throws -> TaskID {
    let root = try await harness.root(context: .background)
    return try await root.commit({ tx in try await tx.createTask(task, input: .null, options: .init(ownership: .conversation())) },
                                 context: .background)
}

private func stateOf(_ harness: Harness, _ id: TaskID) async throws -> TaskState? {
    try await harness.getTask(id: id, context: .background)?.state
}

/// Let queued work and a few timer turns run.
private func settle() async throws {
    for _ in 0..<100 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    for _ in 0..<100 { await Task.yield() }
}

private func sqlitePath() throws -> (URL, String) {
    let directory = try sqliteTestDirectory()
    return (directory, directory.appendingPathComponent("session.sqlite").path)
}

private func napped(_ until: Int64, slept: Int64) throws -> TaskState {
    .sleeping(checkpoint: try JSONValue(encoding: NapState(phase: .after, slept: slept)), until: until)
}

@Suite struct HarnessSleepTests {
    @Test func sleepsWithoutAnInvocationAndResumesAtItsCheckpointOnceDue() async throws {
        let clock = TestClock(now: 1_000), wakes = SessionTestLog<Wake>(), runs = SessionTestLog<Int>()
        let nap = napTask(1_000, runs: runs)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction,
                                          onWake: { wakes.append($0) }).harness
        let graph = try await harness.taskGraph(context: .background)
        // Swift: the first wake is delivered by a task, so the test waits for it before creating work.
        try await eventually { wakes.count > 0 }
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        #expect(try await stateOf(harness, id) == napped(2_000, slept: 1_000))
        let inspection = try await harness.inspect(context: .background)
        guard case .sleeping(let until)? = inspection.tasks.first(where: { $0.record.id == id })?.state else {
            Issue.record("The task must inspect as sleeping"); return
        }
        #expect(until == 2_000)
        try await eventually { graph.value.tasks[String(id.rawValue)]?.state == .sleeping(phase: "after", until: 2_000) }
        #expect(try harness.wake() == Wake(active: false, at: 2_000))
        try await settle()
        #expect(wakes.values.last == Wake(active: false, at: 2_000))

        // Early and repeated wakes run nothing.
        clock.advance(by: 999)
        try harness.resume()
        try harness.resume()
        try await settle()
        #expect(runs.count == 0)
        #expect(try await stateOf(harness, id)?.status == "sleeping")

        clock.advance(by: 1)
        try harness.resume()
        try harness.resume()
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: 2_000))
        #expect(runs.count == 1)
        try await settle()
        #expect(try harness.wake() == Wake(active: false))
        #expect(wakes.values.last == Wake(active: false))
        // Only changes: idle at open, running, asleep until 2000, running again, idle.
        let values = wakes.values
        for index in values.indices.dropFirst() { #expect(values[index] != values[index - 1]) }
        #expect(values.first == Wake(active: false))
        #expect(values.contains(Wake(active: true)))
        #expect(values.contains(Wake(active: false, at: 2_000)))
        graph.dispose()
        try await harness.close(context: .background)
    }

    @Test func keepsASleepAcrossReopen() async throws {
        let (directory, path) = try sqlitePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(now: 1_000)
        let nap = napTask(60_000)
        func open() async throws -> Harness {
            try await openTasks(storage: SqliteStorage.open(path: path), tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction,
                                onWake: { _ in }).harness
        }
        var harness = try await open()
        let id = try await startNap(harness, nap)
        try harness.resume()
        let first = harness
        try await eventually { try await stateOf(first, id)?.status == "sleeping" }
        try await harness.close(context: .background)

        harness = try await open()
        // Known from storage before scheduling starts.
        #expect(try harness.wake() == Wake(active: false, at: 61_000))
        try harness.resume()
        try await settle()
        #expect(try await stateOf(harness, id)?.status == "sleeping")
        try await harness.close(context: .background)

        clock.advance(by: 60_000)
        harness = try await open()
        #expect(try harness.wake() == Wake(active: true))
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: 61_000))
        try await harness.close(context: .background)
    }

    @Test func resumesADueSleepWithATimerWhenThereIsNoOnWake() async throws {
        let nap = napTask(30)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)]).harness
        let id = try await startNap(harness, nap)
        let started = ContinuousClock.now
        // Only this call: the timer wakes the task.
        try harness.resume()
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == "completed")
        #expect(ContinuousClock.now - started >= .milliseconds(25))
        try await harness.close(context: .background)
    }

    @Test func armsItsTimersThroughSetTimerASleepsInTheForegroundADeclinedBackgroundOneIsNotNeeded() async throws {
        struct Armed: Sendable { let delayMs: Int64; let background: Bool; let callback: @Sendable () -> Void }
        let clock = TestClock(now: 1_000), armed = SessionTestLog<Armed>()
        let nap = napTask(500)
        let setTimer: SetTimer = { callback, delayMs, options in
            armed.append(Armed(delayMs: delayMs, background: options.background, callback: callback))
            // Declines background timers, as a host that must hibernate would.
            if options.background { return nil }
            return {}
        }
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, setTimer: setTimer).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { armed.values.contains { !$0.background && $0.delayMs == 500 } }
        #expect(try await stateOf(harness, id)?.status == "sleeping")
        clock.advance(by: 500)
        try #require(armed.values.first { !$0.background && $0.delayMs == 500 }).callback()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: 1_500))
        try await harness.close(context: .background)
    }

    @Test func disarmsAnInvocationsTimersWhenItEnds() async throws {
        let disarmed = SessionTestLog<Int>(), fired = SessionTestLog<String>(), armed = SessionTestLog<Int64>()
        let timed = harnessOneStep("test.timed") { _, runtime, context in
            _ = runtime.setTimer({ fired.append("late") }, delayMs: 60_000)
            try await runtime.commit({ _, _ in try completed(0) }, context: context)
        }
        let setTimer: SetTimer = { _, delayMs, _ in
            armed.append(delayMs)
            let id = armed.count - 1
            if delayMs == 60_000 { return { disarmed.append(id) } }
            return {}
        }
        let harness = try await openTasks(tasks: [AnyTaskDefinition(timed)], setTimer: setTimer).harness
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, timed)
        try harness.resume()
        _ = try await harness.waitForTask(id: id, context: .background)
        try await eventually { disarmed.count == 1 }
        #expect(fired.values.isEmpty)
        try await harness.close(context: .background)
    }

    // Swift: on the test clock, not real time. A pass that runs more than 10 ms after the sleep commit, as one can under
    // parallel load, would find the real-time sleep due and run it.
    @Test func keepsNoTimerWithOnWake() async throws {
        let clock = TestClock(now: 1_000)
        let nap = napTask(10)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, onWake: { _ in }).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        try await Task.sleep(for: .milliseconds(60))
        #expect(try await stateOf(harness, id)?.status == "sleeping")
        clock.advance(by: 10)
        #expect(try harness.wake() == Wake(active: true))
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    @Test func runsTheAbortHandlerOfASleepingTaskWithoutWaitingForItsTime() async throws {
        let clock = TestClock(now: 1_000)
        let nap = napTask(60_000)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, onWake: { _ in }).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        _ = try await harness.abortTask(id: id, context: .background)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "test"))
        try await harness.close(context: .background)
    }

    // Swift: `until` is an Int64, so NaN and Infinity cannot be passed; -1 is the time it can reject.
    @Test func rejectsASleepUntilSomethingThatIsNotATimeAndASleepInAnAbortHandler() async throws {
        let errors = SessionTestLog<String>()
        let invalid = harnessOneStep("test.invalid-sleep") { task, runtime, context in
            for until: Int64 in [-1] {
                do { try await runtime.sleepUntil(until, checkpoint: HarnessTaskCheckpoint(phase: .joined), context: context) }
                catch { errors.append(String(describing: error)) }
            }
            try await runtime.commit({ _, _ in try completed(0) }, context: context)
        }
        let aborting = harnessOneStep("test.sleep-in-abort", run: { _, runtime, _ in
            try await aborted(runtime.signal)
        }, abort: { _, runtime, context in
            do { try await runtime.sleepUntil(try runtime.now() + 10, checkpoint: HarnessTaskCheckpoint(), context: context) }
            catch { errors.append(String(describing: error)) }
            try await runtime.commit({ _, _ in abortedWith("test") }, context: context)
        })
        let harness = try await openTasks(tasks: [AnyTaskDefinition(invalid), AnyTaskDefinition(aborting)]).harness
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, invalid)
        let abortingID = try await harnessStart(root, aborting)
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        _ = try await harness.abortTask(id: abortingID, context: .background)
        #expect(try await harness.waitForTask(id: abortingID, context: .background).outcome.status == "aborted")
        #expect(errors.values == [
            "Task \(id.rawValue) cannot sleep until -1: not a time in milliseconds",
            "Abort handler of task \(abortingID.rawValue) cannot sleep",
        ])
        try await harness.close(context: .background)
    }

    @Test func doesNotCountATaskWithoutADefinitionAsActive() async throws {
        let missing = napTask(10)
        let harness = try await openTasks(tasks: []).harness
        let root = try await harness.root(context: .background)
        // Created through a definition the registry does not hold: nothing can run it.
        _ = try await root.commit({ tx in try await tx.createTask(missing, input: .null, options: .init(ownership: .conversation())) },
                                  context: .background)
        #expect(try harness.wake() == Wake(active: false))
        try harness.resume()
        try await settle()
        #expect(try harness.wake() == Wake(active: false))
        try await harness.close(context: .background)
    }

    @Test func reportsAThrowingOnWakeAndKeepsCallingItForLaterChanges() async throws {
        struct AlarmFailed: Error {}
        let clock = TestClock(now: 1_000), wakes = SessionTestLog<Wake>()
        let nap = napTask(1_000)
        let opened = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, onWake: { wake in
            wakes.append(wake)
            if wake.at != nil { throw AlarmFailed() }
        })
        let harness = opened.harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        try await settle()
        #expect(opened.reports.count > 0)
        #expect(opened.reports.values.allSatisfy { $0 is AlarmFailed })
        clock.advance(by: 1_000)
        try harness.resume()
        _ = try await harness.waitForTask(id: id, context: .background)
        try await settle()
        #expect(wakes.values.last == Wake(active: false))
        try await harness.close(context: .background)
    }
}
