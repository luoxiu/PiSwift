// Tasks that cannot run: the crash-loop guard (`settings.restartLimit`, `Harness.retryTask()`) and blocked reasons in
// the task graph (upstream harness-blocked.test.ts).
import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct RunCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case run }
    var phase: Phase = .run
}
private typealias RunTask = TaskDefinition<JSONValue, RunCheckpoint, JSONValue, NoTaskHooks>

private struct StepsCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case one, two }
    var phase: Phase = .one
}
private typealias StepsTask = TaskDefinition<JSONValue, StepsCheckpoint, JSONValue, NoTaskHooks>

/// Whether the crash-loop task hangs, and how often its phase started.
private final class CrashState: Sendable {
    private let state: Mutex<(crashing: Bool, started: Int)>
    init(crashing: Bool) { state = Mutex((crashing, 0)) }
    var crashing: Bool { get { state.withLock { $0.crashing } } set { state.withLock { $0.crashing = newValue } } }
    var started: Int { state.withLock { $0.started } }
    func start() -> Bool { state.withLock { $0.started += 1; return $0.crashing } }
}

/// Holds until `signal` aborts, as a phase cut off by a close; returns normally then.
private func hang(_ signal: AbortSignal) async {
    _ = try? await aborted(signal)
}

/// A task that hangs in its phase while `crashing`, as one killed every time would, and completes otherwise.
private func crashLoop(_ state: CrashState,
                       abort: @escaping RunTask.Handler = { _, _, _ in }) -> RunTask {
    RunTask(name: "test.crash-loop", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, runtime, context in
        if state.start() { await hang(runtime.signal) }
        else { try await runtime.commit({ _, _ in try completed(JSONValue.null) }, context: context) }
    }, abort: abort)
}

private func sqlitePath() throws -> String {
    try sqliteTestDirectory().appendingPathComponent("session.sqlite").path
}

private struct Opened {
    let harness: Harness
    let wakes: SessionTestLog<Wake>
    let reports: HarnessReports
}

private func openWith(_ path: String, _ registry: Registry, restartLimit: Double? = nil) async throws -> Opened {
    let wakes = SessionTestLog<Wake>()
    let settings = HarnessSettingsProvider { HarnessSettings(restartLimit: restartLimit) }
    let opened = try await openTasks(storage: try await SqliteStorage.open(path: path), tasks: [], registry: registry,
                                     settings: settings, onWake: { wakes.append($0) })
    return Opened(harness: opened.harness, wakes: wakes, reports: opened.reports)
}

private func create(_ harness: Harness, _ definition: RunTask) async throws -> TaskID {
    let root = try await harness.root(context: .background)
    return try await root.commit({ tx in try await tx.createTask(definition, input: .null, options: .init(ownership: .conversation())) },
                                 context: .background)
}

private func outcomeStatus(_ harness: Harness, _ id: TaskID) async throws -> String {
    try await harness.waitForTask(id: id, context: .background).outcome.status
}

@Suite struct HarnessBlockedTests {
    @Test func parksATaskCutOffRestartLimitTimesInARowShowsWhyAndRunsItAgainOnRetryTask() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let registry = createRegistry()
        let loop = crashLoop(state)
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        var opened = try await openWith(path, registry, restartLimit: 3)
        let root = try await opened.harness.root(context: .background)
        let id = try await create(opened.harness, loop)
        // Each open runs the phase, and each close cuts it off: three restarts.
        for run in 1...3 {
            try opened.harness.resume()
            try await eventually { state.started == run }
            try await opened.harness.close(context: .background)
            opened = try await openWith(path, registry, restartLimit: 3)
        }
        let harness = opened.harness
        #expect(try await harness.getTask(id: id, context: .background)?.restarts == 3)
        #expect(opened.reports.infos == [ReportInfo(source: .task, taskId: id, taskKind: "test.crash-loop", conversationId: root.id)])
        #expect(opened.reports.values.map { String(describing: $0) }
            == ["Task \(id.rawValue) (test.crash-loop) was cut off 3 times without progress; it is parked until retryTask()"])
        let inspection = try await harness.inspect(context: .background)
        guard case .blocked(let reason, _)? = inspection.tasks.first(where: { $0.record.id == id })?.state else {
            Issue.record("The task must inspect as blocked"); return
        }
        #expect(reason == .restartLimit)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit)
        // Parked work needs no process: nothing is active.
        #expect(try harness.wake() == Wake(active: false))
        try harness.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.started == 3)

        state.crashing = false
        try await harness.retryTask(id: id, context: .background)
        #expect(try await outcomeStatus(harness, id) == "completed")
        #expect(state.started == 4)
        graph.dispose()
        try await harness.close(context: .background)
    }

    @Test func stillRunsTheAbortHandlerOfAParkedTask() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let aborted = SessionTestLog<TaskID>()
        let registry = createRegistry()
        let loop = crashLoop(state, abort: { task, runtime, context in
            aborted.append(task.id)
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        var opened = try await openWith(path, registry, restartLimit: 1)
        let id = try await create(opened.harness, loop)
        try opened.harness.resume()
        try await eventually { state.started == 1 }
        try await opened.harness.close(context: .background)
        opened = try await openWith(path, registry, restartLimit: 1)
        _ = try await opened.harness.abortTask(id: id, context: .background)
        #expect(try await outcomeStatus(opened.harness, id) == "aborted")
        #expect(aborted.values == [id])
        #expect(state.started == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func startsTheCountOverWhenTheTaskMakesProgress() async throws {
        let path = try sqlitePath()
        let crashing = Mutex(true), started = Mutex(0)
        let steps = StepsTask(name: "test.steps", version: 1, initial: { _ in StepsCheckpoint() }, phase: { task, runtime, context in
            started.withLock { $0 += 1 }
            switch task.checkpoint.phase {
            case .one:
                if crashing.withLock({ $0 }) { await hang(runtime.signal) }
                else { try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: StepsCheckpoint(phase: .two))) }, context: context) }
            case .two:
                await hang(runtime.signal)
            }
        }, abort: { _, _, _ in })
        let registry = createRegistry()
        try registry.install(Extension(name: "steps", tasks: [AnyTaskDefinition(steps)]))
        var opened = try await openWith(path, registry, restartLimit: 2)
        let root = try await opened.harness.root(context: .background)
        let id = try await root.commit({ tx in try await tx.createTask(steps, input: .null, options: .init(ownership: .conversation())) },
                                       context: .background)
        try opened.harness.resume()
        try await eventually { started.withLock { $0 } == 1 }
        try await opened.harness.close(context: .background)
        opened = try await openWith(path, registry, restartLimit: 2)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.restarts == 1)
        // Progress: phase one commits phase two, which resets the count.
        crashing.withLock { $0 = false }
        try opened.harness.resume()
        try await eventually { started.withLock { $0 } == 3 }
        #expect(try await opened.harness.getTask(id: id, context: .background)?.restarts == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func showsATaskWithoutADefinitionAsBlockedAndWakesTheHostOnceARegistryChangeUnblocksIt() async throws {
        let missing = RunTask(name: "test.missing", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, runtime, context in
            try await runtime.commit({ _, _ in try completed(JSONValue.null) }, context: context)
        }, abort: { _, _, _ in })
        let registry = createRegistry()
        let opened = try await openWith(try sqlitePath(), registry)
        let harness = opened.harness
        let graph = try await harness.taskGraph(context: .background)
        let id = try await create(harness, missing)
        try harness.resume()
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == .missingTask }
        #expect(try harness.wake() == Wake(active: false))
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(missing)]))
        // The graph follows the registry; the host hears it can run work now.
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == nil }
        try await eventually { opened.wakes.values.contains { $0.active } }
        #expect(try await outcomeStatus(harness, id) == "completed")
        graph.dispose()
        try await harness.close(context: .background)
    }

    // Swift: in the test above the task runs once unblocked, and its commit updates the graph too; here scheduling stays
    // paused, so only the registry change reaches the graph.
    @Test func followsARegistryChangeInTheGraphWithoutACommit() async throws {
        let missing = RunTask(name: "test.missing", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, _, _ in },
                              abort: { _, _, _ in })
        let registry = createRegistry()
        let harness = try await openWith(try sqlitePath(), registry).harness
        let id = try await create(harness, missing)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .missingTask)
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(missing)]))
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == nil }
        #expect(graph.value.tasks[String(id.rawValue)]?.state == .pending(phase: "run"))
        graph.dispose()
        try await harness.close(context: .background)
    }
}
