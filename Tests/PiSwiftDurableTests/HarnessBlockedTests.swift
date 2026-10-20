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

/// Storage over `base` whose every call hangs once `kill()` ran, as in a crash: it writes nothing more, not even the
/// `pending` records a close writes for the tasks it stops. `failNextCommit` fails one commit once `release` opens.
private final class KillableStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    private let dead = Mutex(false)
    private let never = SessionTestGate()
    private let failure = Mutex<(error: any Error, release: SessionTestGate)?>(nil)
    init(_ base: any DurableStorage) { self.base = base }
    func kill() { dead.withLock { $0 = true } }
    func failNextCommit(_ error: any Error, after release: SessionTestGate) { failure.withLock { $0 = (error, release) } }
    private func alive() async { if dead.withLock({ $0 }) { await never.wait() } }

    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        await alive()
        if let (error, release) = failure.withLock({ value in defer { value = nil }; return value }) {
            await release.wait()
            throw error
        }
        return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { await alive(); return try await base.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        await alive(); return try await base.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        await alive(); return try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        await alive(); return try await base.entry(id, context: context)
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        await alive(); return try await base.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        await alive(); return try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        await alive(); return try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        await alive(); return try await base.task(id, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        await alive(); return try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        await alive(); return try await base.submission(id, context: context)
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        await alive(); return try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        await alive(); return try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        await alive(); return try await base.findDocument(address, at: at, context: context)
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        await alive(); return try await base.document(id, at: at, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        await alive(); return try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws { await alive(); try await base.close(context: context) }
}

/// Storages of killed Harnesses, never closed by them: closed after each test.
private final class KilledStorages: Sendable {
    @TaskLocal static var current: KilledStorages?
    private let state = Mutex<[any DurableStorage]>([])
    func add(_ storage: any DurableStorage) { state.withLock { $0.append(storage) } }
    func closeAll() async {
        for storage in state.withLock({ $0 }) { try? await storage.close(context: .background) }
    }
}
/// Closes the storages of the Harnesses a test killed once it ends (upstream's `afterEach`).
private struct ClosesKilledStorages: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        let killed = KilledStorages()
        do { try await KilledStorages.$current.withValue(killed) { try await function() } }
        catch { await killed.closeAll(); throw error }
        await killed.closeAll()
    }
}

/// Settings whose `restartLimit` a test changes while the Harness runs.
private final class LiveLimit: Sendable {
    private let state: Mutex<Double?>
    init(_ value: Double?) { state = Mutex(value) }
    var value: Double? { get { state.withLock { $0 } } set { state.withLock { $0 = newValue } } }
    var provider: HarnessSettingsProvider { HarnessSettingsProvider { [self] in HarnessSettings(restartLimit: value) } }
}

private struct Opened {
    let harness: Harness
    let wakes: SessionTestLog<Wake>
    let reports: HarnessReports
    let storage: KillableStorage
    /// A crash: every later call of its storage hangs.
    func kill() {
        storage.kill()
        KilledStorages.current?.add(storage.base)
    }
}

private func openWith(_ path: String, _ registry: Registry, restartLimit: Double? = nil) async throws -> Opened {
    try await openWith(path, registry, settings: LiveLimit(restartLimit))
}

private func openWith(_ path: String, _ registry: Registry, settings: LiveLimit) async throws -> Opened {
    let wakes = SessionTestLog<Wake>()
    let storage = KillableStorage(try await SqliteStorage.open(path: path))
    let opened = try await openTasks(storage: storage, tasks: [], registry: registry, settings: settings.provider,
                                     onWake: { wakes.append($0) })
    return Opened(harness: opened.harness, wakes: wakes, reports: opened.reports, storage: storage)
}

private func create(_ harness: Harness, _ definition: RunTask, abandonOnRestart: Bool? = nil) async throws -> TaskID {
    let root = try await harness.root(context: .background)
    return try await root.commit({ tx in
        try await tx.createTask(definition, input: .null, options: .init(ownership: .conversation(), abandonOnRestart: abandonOnRestart))
    }, context: .background)
}

private func outcomeOf(_ harness: Harness, _ id: TaskID) async throws -> TaskOutcome {
    try await harness.waitForTask(id: id, context: .background).outcome
}

/// A scheduling pass runs within a few turns.
private func settle() async throws {
    for _ in 0..<100 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    for _ in 0..<100 { await Task.yield() }
}

private func blockedState(_ harness: Harness, _ id: TaskID) async throws -> TaskBlockedReason? {
    let inspection = try await harness.inspect(context: .background)
    guard case .blocked(let reason, _)? = inspection.tasks.first(where: { $0.record.id == id })?.state else { return nil }
    return reason
}

@Suite struct HarnessBlockedRecoveryTests {
    // Swift: the failing commit waits until the first wake is delivered. Upstream's microtasks deliver it before the
    // pass's commit; here both run in tasks, and a wake computed after the failure is never delivered.
    @Test func keepsTheHostsWakeActiveUntilOpensRecoveryPassHasLanded() async throws {
        let path = try sqlitePath()
        let held = RunTask(name: "test.held", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, _, _ in }, abort: { _, _, _ in })
        let registry = createRegistry()
        try registry.install(Extension(name: "held", tasks: [AnyTaskDefinition(held)]))
        let first = try await openWith(path, registry)
        let id = try await create(first.harness, held)
        try await first.harness.close(context: .background)
        // A crash left the task holding its outcome: the next open's recovery pass makes it terminal.
        let raw = try await SqliteStorage.open(path: path)
        let record = try #require(try await raw.task(id, context: .background))
        _ = try await raw.commit([.task(value: record.replacing(state: .completing(outcome: .completed(result: .null))))], context: .background)
        try await raw.close(context: .background)

        // That pass's commit fails, as on a platform reset.
        let wakes = SessionTestLog<Wake>()
        let storage = KillableStorage(try await SqliteStorage.open(path: path))
        let delivered = SessionTestGate()
        storage.failNextCommit(TestFailure("reset"), after: delivered)
        let harness = try await openTasks(storage: storage, tasks: [], registry: registry, onWake: { wake in
            wakes.append(wake)
            delivered.release()
        }).harness
        guard case .failed = await harness.closed else { Issue.record("The Harness must fail"); return }
        // The host was told work is underway, and never that it ended: its recovery alarm stays.
        #expect(wakes.values == [Wake(active: true)])
    }
}

@Suite(ClosesKilledStorages()) struct HarnessBlockedTests {
    @Test func parksATaskCutOffRestartLimitTimesInARowShowsWhyAndRunsItAgainOnRetryTask() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let registry = createRegistry()
        let loop = crashLoop(state)
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        var opened = try await openWith(path, registry, restartLimit: 3)
        let root = try await opened.harness.root(context: .background)
        let id = try await create(opened.harness, loop)
        // Each open runs the phase, and each crash cuts it off: three restarts.
        for run in 1...3 {
            try opened.harness.resume()
            try await eventually { state.started == run }
            opened.kill() // a crash: a close would not count
            opened = try await openWith(path, registry, restartLimit: 3)
        }
        let harness = opened.harness
        #expect(try await harness.getTask(id: id, context: .background)?.restarts == 3)
        #expect(opened.reports.infos == [ReportInfo(source: .task, taskId: id, taskKind: "test.crash-loop", conversationId: root.id,
                                                    extension: "loop", blocked: .restartLimit)])
        #expect(opened.reports.values.map { String(describing: $0) }
            == ["Task \(id.rawValue) (test.crash-loop) was cut off 3 times without progress; it is parked until retryTask()"])
        #expect(try await blockedState(harness, id) == .restartLimit)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit)
        // Parked work needs no process: nothing is active.
        try await eventually { try !harness.wake().active }
        #expect(try harness.wake() == Wake(active: false))
        try harness.resume()
        // A scheduling pass runs within a few turns; it leaves the parked task out.
        try await settle()
        #expect(state.started == 3)

        state.crashing = false
        try await harness.retryTask(id: id, context: .background)
        #expect(try await outcomeOf(harness, id).status == "completed")
        #expect(state.started == 4)
        graph.dispose()
        try await harness.close(context: .background)
    }

    @Test func countsNoRestartForATaskACloseStopped() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let registry = createRegistry()
        let loop = crashLoop(state)
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        var opened = try await openWith(path, registry, restartLimit: 1)
        let id = try await create(opened.harness, loop)
        try opened.harness.resume()
        try await eventually { state.started == 1 }
        try await opened.harness.close(context: .background)
        opened = try await openWith(path, registry, restartLimit: 1)
        let record = try await opened.harness.getTask(id: id, context: .background)
        #expect(record?.state.status == "pending")
        #expect(record?.restarts == nil)
        state.crashing = false
        #expect(try await outcomeOf(opened.harness, id).status == "completed")
        try await opened.harness.close(context: .background)
    }

    @Test func keepsAnAbortMarkAdmittedBeforeCloseInTheRecordCloseWritesBack() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let registry = createRegistry()
        let loop = crashLoop(state)
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        let harness = try await openWith(path, registry).harness
        let root = try await harness.root(context: .background)
        let id = try await create(harness, loop)
        try harness.resume()
        try await eventually { state.started == 1 }
        // Hold the line; the abort mark is admitted behind it, then close begins.
        let gate = SessionTestGate(), entered = SessionTestGate()
        let holding = Task { try await root.commit({ _ in entered.release(); await gate.wait() }, context: .background) }
        await entered.wait()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await eventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await eventually { harness.tasks.closing }
        // The invocation ends while the line is held; its write-back waits behind the abort mark.
        try await settle()
        gate.release()
        try await holding.value
        #expect(try await aborting.value == .marked)
        try await closing.value
        let raw = try await SqliteStorage.open(path: path)
        let record = try await raw.task(id, context: .background)
        #expect(record?.abortRequested == true)
        #expect(record?.state.status == "pending")
        try await raw.close(context: .background)
    }

    @Test func faultsATaskWhoseAbortHandlerIsCutOffRestartLimitTimes() async throws {
        let path = try sqlitePath()
        let aborts = Mutex(0)
        let stuck = RunTask(name: "test.stuck-abort", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, runtime, _ in
            await hang(runtime.signal)
        }, abort: { _, runtime, _ in
            aborts.withLock { $0 += 1 }
            await hang(runtime.signal)
        })
        let registry = createRegistry()
        try registry.install(Extension(name: "stuck", tasks: [AnyTaskDefinition(stuck)]))
        var opened = try await openWith(path, registry, restartLimit: 1)
        let root = try await opened.harness.root(context: .background)
        let id = try await create(opened.harness, stuck)
        try opened.harness.resume()
        let first = opened.harness
        Task { _ = try? await first.abortTask(id: id, context: .background) }
        try await eventually { aborts.withLock { $0 } == 1 }
        opened.kill() // a crash in the abort handler
        opened = try await openWith(path, registry, restartLimit: 1)
        let settled = try await opened.harness.waitForTask(id: id, context: .background)
        guard case .faulted(let error, _) = settled.outcome else { Issue.record("The task must fault"); return }
        #expect(error.detail == .object(["reason": .string("restart_limit")]))
        // The receipt keeps no restart count.
        #expect(settled.record.restarts == nil)
        #expect(aborts.withLock { $0 } == 1)
        let reports = opened.reports
        try await eventually { reports.count > 0 }
        #expect(reports.infos == [ReportInfo(source: .task, taskId: id, taskKind: "test.stuck-abort", conversationId: root.id,
                                             extension: "stuck", faulted: true, blocked: .restartLimit)])
        #expect(reports.values.map { String(describing: $0) }
            == ["Abort handler of task \(id.rawValue) (test.stuck-abort) was cut off 1 times"])
        try await opened.harness.close(context: .background)
    }

    @Test func runsAParkedTaskOnceARaisedRestartLimitNoLongerParksIt() async throws {
        let path = try sqlitePath()
        let state = CrashState(crashing: true)
        let registry = createRegistry()
        let loop = crashLoop(state)
        try registry.install(Extension(name: "loop", tasks: [AnyTaskDefinition(loop)]))
        let settings = LiveLimit(1)
        var opened = try await openWith(path, registry, settings: settings)
        let id = try await create(opened.harness, loop)
        try opened.harness.resume()
        try await eventually { state.started == 1 }
        opened.kill() // a crash: a close would not count
        opened = try await openWith(path, registry, settings: settings)
        let graph = try await opened.harness.taskGraph(context: .background)
        try opened.harness.resume()
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == .restartLimit }
        // Let a scheduling pass leave the parked task out.
        try await settle()
        state.crashing = false
        // The host's live settings change; the next pass runs the task.
        settings.value = .infinity
        try opened.harness.resume()
        #expect(try await outcomeOf(opened.harness, id).status == "completed")
        #expect(state.started == 2)
        graph.dispose()
        try await opened.harness.close(context: .background)
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
        opened.kill() // a crash: a close would not count
        opened = try await openWith(path, registry, restartLimit: 1)
        _ = try await opened.harness.abortTask(id: id, context: .background)
        #expect(try await outcomeOf(opened.harness, id).status == "aborted")
        #expect(aborted.values == [id])
        #expect(state.started == 1)
        try await opened.harness.close(context: .background)
    }

    @Test func doesNotCountTheSameCheckpointCommittedAgainAsProgress() async throws {
        let path = try sqlitePath()
        let started = Mutex(0)
        let intent = RunTask(name: "test.intent", version: 1, initial: { _ in RunCheckpoint() }, phase: { task, runtime, context in
            started.withLock { $0 += 1 }
            // Intent before an effect, then the effect never returns: the checkpoint is unchanged.
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: task.checkpoint)) }, context: context)
            await hang(runtime.signal)
        }, abort: { _, _, _ in })
        let registry = createRegistry()
        try registry.install(Extension(name: "intent", tasks: [AnyTaskDefinition(intent)]))
        var opened = try await openWith(path, registry, restartLimit: 2)
        let id = try await create(opened.harness, intent)
        for run in 1...2 {
            try opened.harness.resume()
            try await eventually { started.withLock { $0 } == run }
            let harness = opened.harness
            try await eventually { try await harness.getTask(id: id, context: .background)?.state.status == "running" }
            opened.kill() // a crash: a close would not count
            opened = try await openWith(path, registry, restartLimit: 2)
        }
        #expect(try await opened.harness.getTask(id: id, context: .background)?.restarts == 2)
        #expect(try await blockedState(opened.harness, id) == .restartLimit)
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
        opened.kill() // a crash: a close would not count
        opened = try await openWith(path, registry, restartLimit: 2)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.restarts == 1)
        // Progress: phase one commits phase two, which resets the count.
        crashing.withLock { $0 = false }
        try opened.harness.resume()
        try await eventually { started.withLock { $0 } == 3 }
        #expect(try await opened.harness.getTask(id: id, context: .background)?.restarts == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func tellsTheGraphAndTheHostWhenAMigrationFails() async throws {
        let path = try sqlitePath()
        let v1 = RunTask(name: "test.migrating", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, _, _ in }, abort: { _, _, _ in })
        let v2 = RunTask(name: "test.migrating", version: 2, initial: { _ in RunCheckpoint() }, phase: { _, _, _ in }, abort: { _, _, _ in },
                         migrate: { _, _, _ in throw TestFailure("cannot migrate") })
        let first = createRegistry()
        try first.install(Extension(name: "v1", tasks: [AnyTaskDefinition(v1)]))
        var opened = try await openWith(path, first)
        // Created, never run: scheduling stays off.
        let id = try await create(opened.harness, v1)
        try await opened.harness.close(context: .background)
        let second = createRegistry()
        try second.install(Extension(name: "v2", tasks: [AnyTaskDefinition(v2)]))
        opened = try await openWith(path, second)
        let harness = opened.harness, wakes = opened.wakes
        let graph = try await harness.taskGraph(context: .background)
        try harness.resume()
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == .migrationFailed }
        try await eventually { try !harness.wake().active }
        #expect(try harness.wake() == Wake(active: false))
        try await eventually { wakes.values.last?.active == false }
        graph.dispose()
        try await harness.close(context: .background)
    }

    @Test func showsAnAbandonedTaskWaitingForItsDefinitionAsBlocked() async throws {
        let path = try sqlitePath()
        let abandoned = RunTask(name: "test.abandoned", version: 1, initial: { _ in RunCheckpoint() }, phase: { _, _, _ in },
                                abort: { _, _, _ in })
        let registry = createRegistry()
        try registry.install(Extension(name: "abandoned", tasks: [AnyTaskDefinition(abandoned)]))
        var opened = try await openWith(path, registry)
        let id = try await create(opened.harness, abandoned, abandonOnRestart: true)
        try await opened.harness.close(context: .background)
        // The next open marks it `restart`; without its definition, it waits for one to clean up.
        opened = try await openWith(path, createRegistry())
        let harness = opened.harness
        let graph = try await harness.taskGraph(context: .background)
        try harness.resume()
        try await eventually { try await harness.getTask(id: id, context: .background)?.abortReason == .restart }
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == .missingTask }
        graph.dispose()
        try await harness.close(context: .background)
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
        try await eventually { try !harness.wake().active }
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(missing)]))
        // The graph follows the registry; the host hears it can run work now.
        try await eventually { graph.value.tasks[String(id.rawValue)]?.blocked == nil }
        try await eventually { opened.wakes.values.contains { $0.active } }
        #expect(try await outcomeOf(harness, id).status == "completed")
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
