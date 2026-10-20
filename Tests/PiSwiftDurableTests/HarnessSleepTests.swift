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

/// A host `setTimer` that records the timers that pace work and declines background ones.
private final class FakeTimers: Sendable {
    final class Timer: Sendable {
        let delayMs: Int64
        let callback: @Sendable () -> Void
        private let state = Mutex(false)
        init(delayMs: Int64, callback: @escaping @Sendable () -> Void) { self.delayMs = delayMs; self.callback = callback }
        var disarmed: Bool { state.withLock { $0 } }
        func disarm() { state.withLock { $0 = true } }
    }
    private let state = Mutex<[Timer]>([])
    var armed: [Timer] { state.withLock { $0 } }
    func live() -> [Timer] { armed.filter { !$0.disarmed } }
    var setTimer: SetTimer {
        { [self] callback, delayMs, options in
            if options.background { return nil }
            let timer = Timer(delayMs: delayMs, callback: callback)
            state.withLock { $0.append(timer) }
            return { timer.disarm() }
        }
    }
}
private final class Flag: Sendable {
    private let state: Mutex<Bool>
    init(_ value: Bool) { state = Mutex(value) }
    var value: Bool { get { state.withLock { $0 } } set { state.withLock { $0 = newValue } } }
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
        try await eventually { try !harness.wake().active }
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
        try await eventually { try !harness.wake().active }
        #expect(try harness.wake() == Wake(active: false))
        #expect(wakes.values.last == Wake(active: false))
        // Only changes: idle at open, running, asleep until 2000, running again, idle.
        let values = wakes.values
        for index in values.indices.dropFirst() { #expect(values[index] != values[index - 1]) }
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
        // Known from storage before scheduling starts, once open's recovery pass is done.
        let reopened = harness
        try await eventually { try !reopened.wake().active }
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

    @Test func resumesADueSleepWithItsTimerWithoutOnWakeWithBackgroundTimersDeclined() async throws {
        let clock = TestClock(now: 1_000), timers = FakeTimers()
        let nap = napTask(500)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, setTimer: timers.setTimer).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { timers.live().contains { $0.delayMs == 500 } }
        #expect(try await stateOf(harness, id)?.status == "sleeping")
        clock.advance(by: 500)
        try #require(timers.live().first { $0.delayMs == 500 }).callback()
        // Polled: `waitForTask()` would call `resume()`, which wakes due sleeps itself.
        try await eventually { try await stateOf(harness, id)?.status == "terminal" }
        #expect(try await stateOf(harness, id)?.outcome == .completed(result: 1_500))
        try await harness.close(context: .background)
    }

    @Test func runsADueSleepAtAnySchedulingPassBeforeItsTimerFires() async throws {
        let clock = TestClock(now: 1_000), timers = FakeTimers()
        let nap = napTask(500)
        let opened = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, setTimer: timers.setTimer)
        let harness = opened.harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        // Swift: passes run on other threads; wait until one dropped the sleeping task from the candidates, as upstream's
        // microtasks have by now.
        try await eventually { harness.tasks.state.withLock { !$0.runnable.contains(id) && $0.invocations[id] == nil } }
        // The deadline passes, and an unrelated change starts a pass before the timer fires.
        clock.advance(by: 500)
        try opened.registry.install(Extension(name: "unrelated"))
        // Polled: `waitForTask()` would call `resume()`, which wakes due sleeps itself.
        try await eventually { try await stateOf(harness, id)?.status == "terminal" }
        #expect(try await stateOf(harness, id)?.outcome == .completed(result: 1_500))
        try await harness.close(context: .background)
    }

    @Test func disarmsTheSleepTimerWhenTheSleepIsAbortedAndWhenTheHarnessCloses() async throws {
        let clock = TestClock(now: 1_000), timers = FakeTimers()
        let short = napTask(500)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(short)], now: clock.nowFunction, setTimer: timers.setTimer).harness
        let aborted = try await startNap(harness, short)
        try harness.resume()
        try await eventually { timers.live().contains { $0.delayMs == 500 } }
        _ = try await harness.abortTask(id: aborted, context: .background)
        _ = try await harness.waitForTask(id: aborted, context: .background)
        try await eventually { timers.live().isEmpty }
        let kept = try await startNap(harness, short)
        try await eventually { try await stateOf(harness, kept)?.status == "sleeping" }
        try await eventually { !timers.live().isEmpty }
        #expect(timers.live().map(\.delayMs) == [500])
        try await harness.close(context: .background)
        #expect(timers.live().isEmpty)
    }

    @Test func disarmsAnInvocationsTimersWhenItEndsAndALateFireRunsNothing() async throws {
        let fired = SessionTestLog<String>()
        let timed = harnessOneStep("test.timed") { _, runtime, context in
            _ = runtime.setTimer({ fired.append("late") }, delayMs: 60_000)
            try await runtime.commit({ _, _ in try completed(0) }, context: context)
        }
        let timers = FakeTimers()
        let harness = try await openTasks(tasks: [AnyTaskDefinition(timed)], setTimer: timers.setTimer).harness
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, timed)
        try harness.resume()
        _ = try await harness.waitForTask(id: id, context: .background)
        let timer = try #require(timers.armed.first { $0.delayMs == 60_000 })
        try await eventually { timer.disarmed }
        // A host timer that fires anyway: the ended invocation's callback does not run.
        timer.callback()
        #expect(fired.values.isEmpty)
        try await harness.close(context: .background)
    }

    @Test func armsNoTimerForSleepsWithOnWake() async throws {
        let clock = TestClock(now: 1_000), timers = FakeTimers()
        let nap = napTask(500)
        let harness = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, onWake: { _ in },
                                          setTimer: timers.setTimer).harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { try await stateOf(harness, id)?.status == "sleeping" }
        try await settle()
        #expect(timers.armed.isEmpty)
        clock.advance(by: 500)
        #expect(try harness.wake() == Wake(active: true))
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // Swift: the naps sleep on a test clock. Under parallel load the wake could be computed after a sleep on the system
    // clock is already due, and a due sleep needs no timer, so nothing would be declined; 300 ms naps were not enough once
    // the suite grew. The declined timer falls back to the default one, which fires on the system clock and finds the
    // sleeps due once the test clock has advanced.
    @Test func armsAForegroundTimerTheHostDeclinesWithTheDefaultTimerReportingItOnce() async throws {
        let clock = TestClock(now: 1_000)
        let nap = napTask(10)
        let opened = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, setTimer: { _, _, _ in nil })
        let harness = opened.harness
        let first = try await startNap(harness, nap)
        let second = try await startNap(harness, nap)
        try harness.resume()
        let reports = opened.reports
        try await eventually { reports.count > 0 }
        clock.advance(by: 10)
        #expect(try await harness.waitForTask(id: first, context: .background).outcome.status == "completed")
        #expect(try await harness.waitForTask(id: second, context: .background).outcome.status == "completed")
        #expect(opened.reports.values.map { String(describing: $0) } == [
            "HarnessOptions.setTimer declined a timer that paces work; using setTimeout",
        ])
        try await harness.close(context: .background)
    }

    @Test func countsNeitherAWaitOnASleepingTaskNorAnOutcomeHeldOverOneAsActive() async throws {
        struct ParentInput: Codable, Sendable { let hold: Bool }
        struct ParentState: TaskCheckpoint {
            enum Phase: String, Codable, Sendable { case start, joined }
            var phase: Phase = .start
            var child: TaskID?
        }
        let clock = TestClock(now: 1_000)
        let child = napTask(500)
        let parent = TaskDefinition<ParentInput, ParentState, JSONValue, NoTaskHooks>(name: "test.parent", version: 1,
            initial: { _ in ParentState() }, phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .start:
                    try await runtime.commit({ tx, _ in
                        let id = try await tx.createTask(child, input: .null, options: .init(ownership: .task(taskId: task.id)))
                        let joined = try JSONValue(encoding: ParentState(phase: .joined, child: id))
                        // Held: completes next, holding its outcome over the sleeping child. Otherwise waits for it.
                        return task.input.hold ? .running(checkpoint: joined) : .waiting(checkpoint: joined, on: [id], policy: .allSettled)
                    }, context: context)
                case .joined:
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
                }
            }, abort: { _, _, _ in })
        for hold in [false, true] {
            let harness = try await openTasks(tasks: [AnyTaskDefinition(parent), AnyTaskDefinition(child)], now: clock.nowFunction,
                                              onWake: { _ in }).harness
            let root = try await harness.root(context: .background)
            let id = try await root.commit({ tx in
                try await tx.createTask(parent, input: ParentInput(hold: hold), options: .init(ownership: .conversation()))
            }, context: .background)
            try harness.resume()
            let parked = hold ? "completing" : "waiting"
            try await eventually { try await stateOf(harness, id)?.status == parked }
            // Swift: the parent's invocation ends on another thread after its state is stored, so wait for the whole value.
            try await eventually { try harness.wake() == Wake(active: false, at: 1_500) }
            try await eventually { try !harness.wake().active }
            #expect(try harness.wake() == Wake(active: false, at: 1_500))
            try await harness.close(context: .background)
        }
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
        try await eventually { try !harness.wake().active }
        #expect(try harness.wake() == Wake(active: false))
        try harness.resume()
        try await settle()
        try await eventually { try !harness.wake().active }
        #expect(try harness.wake() == Wake(active: false))
        try await harness.close(context: .background)
    }

    @Test func reportsAThrowingOnWakeAndOffersTheSameWakeAgainAtTheNextPass() async throws {
        struct AlarmFailed: Error {}
        let clock = TestClock(now: 1_000), wakes = SessionTestLog<Wake>(), failing = Flag(true)
        let nap = napTask(1_000)
        let opened = try await openTasks(tasks: [AnyTaskDefinition(nap)], now: clock.nowFunction, onWake: { wake in
            wakes.append(wake)
            if failing.value && wake.at != nil { throw AlarmFailed() }
        })
        let harness = opened.harness
        let id = try await startNap(harness, nap)
        try harness.resume()
        try await eventually { wakes.values.contains { $0.at == 2_000 && !$0.active } }
        // Swift: the report follows the throw on the delivering task.
        try await eventually { opened.reports.values.contains { $0 is AlarmFailed } }
        // The host recovers; an unrelated change offers the same, undelivered wake again.
        failing.value = false
        let offered = wakes.count
        try opened.registry.install(Extension(name: "unrelated"))
        try await eventually { wakes.count > offered }
        #expect(wakes.values.last == Wake(active: false, at: 2_000))
        clock.advance(by: 1_000)
        try harness.resume()
        _ = try await harness.waitForTask(id: id, context: .background)
        try await eventually { wakes.values.last == Wake(active: false) }
        try await harness.close(context: .background)
    }
}
