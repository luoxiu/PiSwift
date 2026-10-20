import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// The checkpoint of upstream's scriptable `Node`: it runs, then resumes in a round after a wait.
private struct WaitNodeCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run, resume }
    var phase: Phase = .run
    var round = 0
}
/// A node's input is its name, which selects its behavior.
private typealias WaitNode = TaskDefinition<String, WaitNodeCheckpoint, String, NoTaskHooks>

/// Per-name behavior of upstream's `Node`, one set per test; unscripted parts use the defaults: a run waits for its
/// gate or its abort signal and then ends as the gate says, a resume completes, an abort ends `aborted`.
private final class WaitNodes: Sendable {
    typealias Handler = @Sendable (TaskRuntime, ChordContext) async throws -> Void
    struct Behavior: Sendable { var run: Handler?; var resume: Handler?; var abort: Handler? }
    private final class Behaviors: Sendable {
        let state = Mutex<[String: Behavior]>([:])
        subscript(name: String) -> Behavior { state.withLock { $0[name] } ?? Behavior() }
    }
    private let behaviors = Behaviors()
    let gates = HarnessHoldGates()
    /// Handler starts in order, such as `run:a`, `abort:a`.
    let log = SessionTestLog<String>()
    let definition: WaitNode
    init() {
        let behaviors = behaviors, gates = gates, log = log
        definition = WaitNode(name: "test.node", version: 1, initial: { _ in WaitNodeCheckpoint() }, phase: { task, runtime, context in
            let name = task.input
            switch task.checkpoint.phase {
            case .run:
                log.append("run:\(name)")
                if let run = behaviors[name].run { return try await run(runtime, context) }
                guard let outcome = await gates.wait(name, signal: runtime.signal) else { return }
                try await runtime.commit({ _, _ in .terminal(outcome: outcome) }, context: context)
            case .resume:
                log.append("resume:\(name)")
                if let resume = behaviors[name].resume { return try await resume(runtime, context) }
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .string(name))) }, context: context)
            }
        }, abort: { task, runtime, context in
            let name = task.input
            log.append("abort:\(name)")
            if let abort = behaviors[name].abort { return try await abort(runtime, context) }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(result: .string(name))) }, context: context)
        })
    }
    func script(_ name: String, run: Handler? = nil, resume: Handler? = nil, abort: Handler? = nil) {
        behaviors.state.withLock { $0[name] = Behavior(run: run, resume: resume, abort: abort) }
    }
    /// Opens the gate of a default run: it completes.
    func open(_ name: String) { gates.open(name, .completed(result: .string(name))) }
    /// A child task named `name`, owned by `owner`.
    func spawn(_ tx: Transaction, _ owner: TaskID, _ name: String) async throws -> TaskID {
        try await tx.createTask(definition, input: name, options: .init(ownership: .task(taskId: owner)))
    }
    /// A task named `name` owned by `conversation`.
    func start(_ conversation: Conversation, _ name: String) async throws -> TaskID {
        try await conversation.commit({ [definition] tx in
            try await tx.createTask(definition, input: name, options: .init(ownership: .conversation()))
        }, context: .background)
    }
    /// Scripts `name` to spawn `child` and finish, so the running child holds it as `completing`.
    func spawnAndFinish(_ name: String, _ child: String) -> TaskIDs {
        let found = TaskIDs()
        script(name, run: { [self] runtime, context in
            try await runtime.commit({ tx, _ in
                found[child] = try await spawn(tx, runtime.taskId, child)
                return .running(checkpoint: try JSONValue(encoding: WaitNodeCheckpoint(phase: .resume, round: 1)))
            }, context: context)
        })
        return found
    }
}

/// Task IDs by name, filled in as tasks are created.
private final class TaskIDs: Sendable {
    private let ids = Mutex<[String: TaskID]>([:])
    subscript(name: String) -> TaskID? {
        get { ids.withLock { $0[name] } }
        set { ids.withLock { $0[name] = newValue } }
    }
    func require(_ name: String) throws -> TaskID { try #require(self[name]) }
}

/// Wait on `on`, resuming in round 1.
private func waitOn(_ on: [TaskID], _ policy: JoinPolicy = .allSettled) throws -> TaskState {
    .waiting(checkpoint: try JSONValue(encoding: WaitNodeCheckpoint(phase: .resume, round: 1)), on: on, policy: policy)
}
private func openNodes(_ nodes: WaitNodes) async throws -> (harness: Harness, root: Conversation) {
    let harness = try await harnessOpen([AnyTaskDefinition(nodes.definition)])
    let root = try await harness.root(context: .background)
    try harness.resume()
    return (harness, root)
}
private func status(_ harness: Harness, _ id: TaskID) async throws -> String? {
    try await harness.getTask(id: id, context: .background)?.state.status
}
/// The task's outcome once it ended. A cycle that went unnoticed never ends: this throws after five seconds instead.
private func outcomeOf(_ harness: Harness, _ id: TaskID) async throws -> String {
    try await harnessEventually { try await status(harness, id) == "terminal" }
    return try await harness.waitForTask(id: id, context: .background).outcome.status
}

/// Port of the wait cycle cases (#10411) of upstream `test/harness-structured.test.ts`, which upstream took with their
/// approach from #10533 by @odysseus0.
@Suite struct HarnessTaskWaitCycleTests {
    @Test func rejectsTheWaitThatClosesACycle() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        nodes.script("a", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("b")]) }, context: context) })
        nodes.script("b", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("a")]) }, context: context) })
        try await root.commit({ [definition = nodes.definition] tx in
            ids["a"] = try await tx.createTask(definition, input: "a", options: .init(ownership: .conversation()))
            ids["b"] = try await tx.createTask(definition, input: "b", options: .init(ownership: .conversation()))
        }, context: .background)
        // a -> b and b -> a are waits, and whichever comes second closes the cycle.
        let aID = try ids.require("a"), bID = try ids.require("b")
        async let a = outcomeOf(harness, aID)
        async let b = outcomeOf(harness, bID)
        #expect(try await [a, b].sorted() == ["completed", "faulted"])
        try await harness.close(context: .background)
    }

    @Test func rejectsTheWaitThatClosesACycleThroughAHeldOwner() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        let child = nodes.spawnAndFinish("held", "child")
        nodes.script("child", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("other")]) }, context: context) })
        nodes.script("other", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("held")]) }, context: context) })
        try await root.commit({ [definition = nodes.definition] tx in
            ids["held"] = try await tx.createTask(definition, input: "held", options: .init(ownership: .conversation()))
            ids["other"] = try await tx.createTask(definition, input: "other", options: .init(ownership: .conversation()))
        }, context: .background)
        // held -> child is a hold; child -> other -> held are waits, and whichever wait comes second closes the cycle.
        #expect(try await outcomeOf(harness, try ids.require("held")) == "completed")
        let childID = try child.require("child"), otherID = try ids.require("other")
        async let waiting = outcomeOf(harness, childID)
        async let other = outcomeOf(harness, otherID)
        #expect(try await [waiting, other].sorted() == ["completed", "faulted"])
        try await harness.close(context: .background)
    }

    @Test func rejectsACycleThroughHoldsTwoLevelsDeep() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        let child = nodes.spawnAndFinish("held", "child")
        let grandchild = nodes.spawnAndFinish("child", "grandchild")
        nodes.script("grandchild", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("other")]) }, context: context) })
        nodes.script("other", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("held")]) }, context: context) })
        try await root.commit({ [definition = nodes.definition] tx in
            ids["held"] = try await tx.createTask(definition, input: "held", options: .init(ownership: .conversation()))
            ids["other"] = try await tx.createTask(definition, input: "other", options: .init(ownership: .conversation()))
        }, context: .background)
        // held -> child -> grandchild are holds; grandchild -> other -> held are waits.
        try await harnessEventually { grandchild["grandchild"] != nil }
        let grandchildID = try grandchild.require("grandchild"), otherID = try ids.require("other")
        async let waiting = outcomeOf(harness, grandchildID)
        async let other = outcomeOf(harness, otherID)
        #expect(try await [waiting, other].sorted() == ["completed", "faulted"])
        #expect(try await outcomeOf(harness, try child.require("child")) == "completed")
        try await harness.close(context: .background)
    }

    @Test func letsABackgroundTaskWaitOnTheOwnerOfItsConversation() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        nodes.script("background", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("owner")]) }, context: context) })
        let background = try await root.commit({ [definition = nodes.definition] tx in
            let owner = try await tx.createTask(definition, input: "owner", options: .init(ownership: .conversation()))
            ids["owner"] = owner
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            return try await tx.createTask(definition, input: "background",
                                           options: .init(ownership: .conversation(), conversationId: conversation.id, background: true))
        }, context: .background)
        // background -> owner is a wait but owner -> background is no hold, so there is no cycle.
        try await harnessEventually { try await status(harness, background) == "waiting" }
        nodes.open("owner")
        #expect(try await outcomeOf(harness, background) == "completed")
        try await harness.close(context: .background)
    }

    // The issue's orchestrator, worker, and reviewer.
    @Test func rejectsACycleOfAHoldAndTwoWaitsThatEachLookReasonable() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        let reviewerWaits = SessionTestGate()
        // The orchestrator spawns a worker and finishes; the running worker holds it as completing.
        nodes.script("orchestrator", run: { runtime, context in
            try await runtime.commit({ tx, _ in
                ids["worker"] = try await nodes.spawn(tx, runtime.taskId, "worker")
                return .running(checkpoint: try JSONValue(encoding: WaitNodeCheckpoint(phase: .resume, round: 1)))
            }, context: context)
        })
        // The reviewer waits for the orchestrator's result.
        nodes.script("reviewer", run: { runtime, context in
            try await runtime.commit({ _, _ in try waitOn([try ids.require("orchestrator")]) }, context: context)
            reviewerWaits.release()
        })
        // The worker waits for the reviewer, closing the cycle.
        nodes.script("worker", run: { runtime, context in
            await reviewerWaits.wait()
            try await runtime.commit({ _, _ in try waitOn([try ids.require("reviewer")]) }, context: context)
        })
        ids["orchestrator"] = try await nodes.start(root, "orchestrator")
        try await harnessEventually { try await status(harness, try ids.require("orchestrator")) == "completing" }
        ids["reviewer"] = try await nodes.start(root, "reviewer")
        var outcomes: [String] = []
        for name in ["orchestrator", "worker", "reviewer"] { outcomes.append(try await outcomeOf(harness, try ids.require(name))) }
        #expect(outcomes == ["completed", "faulted", "completed"])
        let worker = try await harness.waitForTask(id: try ids.require("worker"), context: .background).outcome
        let cycle = try ["worker", "reviewer", "orchestrator", "worker"].map { String(try ids.require($0).rawValue) }.joined(separator: " -> ")
        guard case .faulted(let error, _) = worker else { Issue.record("Worker must fault, got \(worker)"); return }
        #expect(error.message.contains("\(cycle) is a wait cycle"), "\(error.message)")
        try await harness.close(context: .background)
    }

    @Test func allowsADiamondOfWaits() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        // A diamond: top waits on left and right, both wait on bottom. No cycle.
        nodes.script("top", run: { runtime, context in
            try await runtime.commit({ _, _ in try waitOn([try ids.require("left"), try ids.require("right")]) }, context: context)
        })
        nodes.script("left", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("bottom")]) }, context: context) })
        nodes.script("right", run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require("bottom")]) }, context: context) })
        try await root.commit({ [definition = nodes.definition] tx in
            for name in ["bottom", "left", "right", "top"] {
                ids[name] = try await tx.createTask(definition, input: name, options: .init(ownership: .conversation()))
            }
        }, context: .background)
        nodes.open("bottom")
        #expect(try await outcomeOf(harness, try ids.require("top")) == "completed")
        try await harness.close(context: .background)
    }

    @Test func followsNoWaitOfAnAbortMarkedTaskWhichWaitsOnlyForItsOwnedWork() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        let cleanup = SessionTestGate()
        // b owns c and waits on a; aborting b leaves c's cleanup pending, so b waits only for c.
        nodes.script("b", run: { runtime, context in
            try await runtime.commit({ tx, _ in
                ids["c"] = try await nodes.spawn(tx, runtime.taskId, "c")
                return try waitOn([try ids.require("a")])
            }, context: context)
        })
        nodes.script("c", abort: { runtime, context in
            await cleanup.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(result: "c")) }, context: context)
        })
        let aWaits = SessionTestGate()
        nodes.script("a", run: { runtime, context in
            await aWaits.wait()
            try await runtime.commit({ _, _ in try waitOn([try ids.require("b")]) }, context: context)
        }, resume: { runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: "a")) }, context: context)
        })
        try await root.commit({ [definition = nodes.definition] tx in
            ids["a"] = try await tx.createTask(definition, input: "a", options: .init(ownership: .conversation()))
            ids["b"] = try await tx.createTask(definition, input: "b", options: .init(ownership: .conversation()))
        }, context: .background)
        try await harnessEventually { try await status(harness, try ids.require("b")) == "waiting" }
        #expect(try await harness.abortTask(id: try ids.require("b"), context: .background) == .marked)
        try await harnessEventually { nodes.log.values.contains("abort:c") }
        // a -> b would close a -> b -> a through b's stale wait; b now waits only for c.
        aWaits.release()
        try await harnessEventually { try await status(harness, try ids.require("a")) == "waiting" }
        cleanup.release()
        #expect(try await outcomeOf(harness, try ids.require("b")) == "aborted")
        #expect(try await outcomeOf(harness, try ids.require("a")) == "completed")
        try await harness.close(context: .background)
    }

    @Test func rejectsALongerCycleOfWaits() async throws {
        let nodes = WaitNodes(), ids = TaskIDs()
        let (harness, root) = try await openNodes(nodes)
        let names = ["x", "y", "z"]
        for (index, name) in names.enumerated() {
            let next = names[(index + 1) % names.count]
            nodes.script(name, run: { runtime, context in try await runtime.commit({ _, _ in try waitOn([try ids.require(next)]) }, context: context) })
        }
        try await root.commit({ [definition = nodes.definition] tx in
            for name in names { ids[name] = try await tx.createTask(definition, input: name, options: .init(ownership: .conversation())) }
        }, context: .background)
        var outcomes: [String] = []
        for name in names { outcomes.append(try await outcomeOf(harness, try ids.require(name))) }
        #expect(outcomes.filter { $0 == "faulted" }.count == 1)
        #expect(outcomes.filter { $0 == "completed" }.count == 2)
        try await harness.close(context: .background)
    }
}
