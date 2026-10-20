import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// An opened Harness whose held tasks wait on `gates`, with its root conversation, scheduling running.
private struct HeldHarness {
    let harness: Harness
    let root: Conversation
    let gates: HarnessHoldGates
    let hold: HarnessHoldTask
    let spawner: HarnessHoldTask
}
private func openHeld(_ storage: any DurableStorage = MemoryStorage(), gates: HarnessHoldGates = HarnessHoldGates()) async throws -> HeldHarness {
    let hold = harnessHold(gates)
    // Tries to create, in the commit that ends it, a conversation it owns with a held task in it, named by its input.
    let spawner = HarnessHoldTask(name: "test.spawner", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
        try await runtime.commit({ tx, _ in
            let child = try await tx.createConversation(ownership: .task(taskId: task.id)).id
            _ = try await tx.hold(hold, task.input.name, in: child)
            return .terminal(outcome: .completed(result: .null))
        }, context: context)
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
    let harness = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(hold), AnyTaskDefinition(spawner)]).harness
    let root = try await harness.root(context: .background)
    try harness.resume()
    return HeldHarness(harness: harness, root: root, gates: gates, hold: hold, spawner: spawner)
}
private extension Transaction {
    func hold(_ definition: HarnessHoldTask, _ name: String, owner: TaskID? = nil, in conversation: ConversationID? = nil,
              background: Bool = false, slowAbort: Bool = false) async throws -> TaskID {
        try await createTask(definition, input: .init(name: name, slowAbort: slowAbort),
                             options: .init(ownership: owner.map { .task(taskId: $0) } ?? .conversation(), conversationId: conversation, background: background))
    }
    func conversation(ownedBy owner: TaskID) async throws -> ConversationID { try await createConversation(ownership: .task(taskId: owner)).id }
}
private func status(_ harness: Harness, _ id: TaskID) async throws -> String? { try await harness.getTask(id: id, context: .background)?.state.status }
private func outcome(_ harness: Harness, _ id: TaskID) async throws -> String { try await harness.waitForTask(id: id, context: .background).outcome.status }
private func start(_ held: HeldHarness, in id: ConversationID, _ name: String, slowAbort: Bool = false) async throws -> TaskID {
    let conversation = try #require(try await held.harness.conversation(id: id, context: .background))
    return try await conversation.commit({ tx in try await tx.hold(held.hold, name, slowAbort: slowAbort) }, context: .background)
}

/// Port of the ownership cases upstream `cb4375493` added to `test/harness-ownership.test.ts`: work below ended tasks,
/// chains deeper than the call stack, and what a pass visits. Swift sets have no insertion order, so the walk bounds read
/// the scheduler's walk probe instead of counting set iterations, and are tighter.
@Suite struct HarnessOwnershipChainTests {
    @Test func holdsAnOwnerForWorkInAConversationItsEndedChildTaskOwns() async throws {
        let held = try await openHeld()
        let harness = held.harness
        let tree = try await held.root.commit({ tx in
            let owner = try await tx.hold(held.hold, "owner")
            let child = try await tx.hold(held.hold, "child", owner: owner)
            return (owner: owner, child: child, conversation: try await tx.conversation(ownedBy: child))
        }, context: .background)
        held.gates.open("child")
        #expect(try await outcome(harness, tree.child) == "completed")
        // The ended child's conversation still belongs to the owner above it.
        _ = try await start(held, in: tree.conversation, "late")
        held.gates.open("owner")
        try await eventually { try await status(harness, tree.owner) == "completing" }
        held.gates.open("late")
        #expect(try await outcome(harness, tree.owner) == "completed")
        try await harness.close(context: .background)
    }

    @Test func cascadesThroughEndedTasksIntoAnOwnedBackgroundSubtreeWhenAbortingAcrossBackground() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // root conversation -> A -> B -> conversation -> background C -> D
        let tree = try await held.root.commit({ tx in
            let a = try await tx.hold(held.hold, "a")
            let b = try await tx.hold(held.hold, "b", owner: a)
            let conversation = try await tx.conversation(ownedBy: b)
            let c = try await tx.hold(held.hold, "c", in: conversation, background: true)
            return (a: a, c: c, d: try await tx.hold(held.hold, "d", owner: c))
        }, context: .background)
        held.gates.open("b")
        held.gates.open("a")
        #expect(try await outcome(harness, tree.a) == "completed")
        try await held.root.abort(background: true, context: .background)
        for id in [tree.c, tree.d] { #expect(try await outcome(harness, id) == "aborted") }
        try await harness.close(context: .background)
    }

    @Test func keepsOwnershipQueriesOffFinishedSubtrees() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Ended chains under a live owner, each ending in an empty owned conversation.
        let owner = try await held.root.commit({ tx in try await tx.hold(held.hold, "owner") }, context: .background)
        let chains = 50
        var tasks: [TaskID] = []
        for n in 0..<chains {
            tasks += try await held.root.commit({ tx in
                let first = try await tx.hold(held.hold, "c\(n).0", owner: owner)
                let second = try await tx.hold(held.hold, "c\(n).1", owner: first)
                _ = try await tx.conversation(ownedBy: second)
                return [first, second]
            }, context: .background)
        }
        for n in 0..<chains { held.gates.open("c\(n).1"); held.gates.open("c\(n).0") }
        for id in tasks { _ = try await harness.waitForTask(id: id, context: .background) }
        try await eventually { harnessReconciled(harness) }
        // Task nodes walks down reach while the owner settles: one through every ended task reaches a hundred; one over
        // live work alone, none below the owner.
        let before = harnessWalked(harness)
        held.gates.open("owner")
        #expect(try await outcome(harness, owner) == "completed")
        #expect(harnessWalked(harness) - before < chains)
        try await harness.close(context: .background)
    }

    @Test func tracksOwnershipChainsDeeperThanTheCallStack() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Upstream runs 20,000 tasks, each owning the next, created in one commit above a live leaf; they end top-down and
        // hold. Here 2,000: each write to `MemoryStorage`'s status index, and each terminal task in a commit's document
        // check, costs time linear in the tasks, so 20,000 take minutes outside the scheduler. The test below holds the
        // indexes to 20,000.
        let depth = 2_000
        let tree = try await held.root.commit({ tx in
            let top = try await tx.hold(held.hold, "top")
            var owner = top
            for n in 0..<depth { owner = try await tx.hold(held.hold, "link\(n)", owner: owner) }
            return (top: top, leaf: try await tx.hold(held.hold, "leaf", owner: owner))
        }, context: .background)
        for n in 0..<depth { held.gates.open("link\(n)") }
        held.gates.open("top")
        try await eventually(timeout: .seconds(60)) { try await status(harness, tree.top) == "completing" }
        held.gates.open("leaf")
        #expect(try await outcome(harness, tree.leaf) == "completed")
        #expect(try await outcome(harness, tree.top) == "completed")
        try await harness.close(context: .background)
    }

    @Test func keepsTheIndexesOfAChainOfTwentyThousandEndedTasksWithLoops() throws {
        // Live P owns 20,000 tasks in a chain, the last owning conversation C; they end bottom-up, C empty. Work in C later
        // is listed through all of them, found below P, freed P when it ends, and unlisted again: each step walks the
        // whole chain, as a recursion deeper than the call stack would.
        var state = TaskScheduler.State()
        let root = try ConversationID(1), child = try ConversationID(2), depth = 20_000
        func record(_ id: Int, owner: Int? = nil, in conversation: ConversationID? = nil, _ state: TaskState) throws -> TaskRecord {
            TaskRecord(id: try TaskID(Int64(id)), conversationId: conversation ?? root, kind: "test.link", version: 1, input: .null,
                       state: state, owner: try owner.map { try TaskID(Int64($0)) })
        }
        let pending = TaskState.pending(checkpoint: .object([:])), ended = TaskState.terminal(outcome: .completed(result: .null))
        state.setEdge(root, nil)
        let p = try record(10, pending)
        state.track(nil, p)
        let links = Array(11...(10 + depth))
        for id in links { state.track(nil, try record(id, owner: id - 1, pending)) }
        state.setEdge(child, try TaskID(Int64(links.last!)))
        for id in links.reversed() { state.track(try record(id, owner: id - 1, pending), try record(id, owner: id - 1, ended)) }
        #expect(state.below[.task(p.id)] == nil && state.settled.count == depth)
        let d = try record(100_000, in: child, pending)
        state.track(nil, d)
        #expect(state.known(d.parent) && !state.unloaded.contains(d.id))
        #expect(state.hasOwnedLive(p.id) && !state.idle(root))
        let holding = try record(10, .completing(outcome: .completed(result: .null)))
        state.track(p, holding)
        state.finalizeChecks = []
        state.track(d, try record(100_000, in: child, ended))
        #expect(state.finalizeChecks == [p.id])
        #expect(!state.hasOwnedLive(p.id) && !state.idle(root) && state.idle(child))
        #expect(state.below[.task(p.id)] == nil && state.below[.conversation(child)] == nil)
    }

    @Test func holdsAnOwnerForWorkACommitCreatesBelowEndedTasksLoadedFromStorage() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite").path
        let gates = HarnessHoldGates()
        let first = try await openHeld(try await SqliteStorage.open(path: path), gates: gates)
        // Live P owns B, which owns A, which owns the empty conversation C; B and A end.
        let tree = try await first.root.commit({ tx in
            let p = try await tx.hold(first.hold, "p")
            let b = try await tx.hold(first.hold, "b", owner: p)
            let a = try await tx.hold(first.hold, "a", owner: b)
            return (p: p, a: a, b: b, c: try await tx.conversation(ownedBy: a))
        }, context: .background)
        gates.open("a")
        gates.open("b")
        _ = try await first.harness.waitForTask(id: tree.a, context: .background)
        _ = try await first.harness.waitForTask(id: tree.b, context: .background)
        try await first.harness.close(context: .background)
        // After reopen, B and A are known only once a chain load reads them.
        let held = try await openHeld(try await SqliteStorage.open(path: path), gates: gates)
        let d = try await start(held, in: tree.c, "d")
        gates.open("p")
        try await eventually { try await status(held.harness, tree.p) == "completing" }
        gates.open("d")
        #expect(try await outcome(held.harness, d) == "completed")
        #expect(try await outcome(held.harness, tree.p) == "completed")
        try await held.harness.close(context: .background)
    }

    @Test func holdsAnOwnerForWorkCreatedLaterBelowEndedTasksWithoutAReopen() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Live P owns B, which owns A, which owns the empty conversation C; B and A end, C stays.
        let tree = try await held.root.commit({ tx in
            let p = try await tx.hold(held.hold, "p")
            let b = try await tx.hold(held.hold, "b", owner: p)
            let a = try await tx.hold(held.hold, "a", owner: b)
            return (p: p, b: b, c: try await tx.conversation(ownedBy: a))
        }, context: .background)
        held.gates.open("a")
        held.gates.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let d = try await start(held, in: tree.c, "d")
        held.gates.open("p")
        try await eventually { try await status(harness, tree.p) == "completing" }
        held.gates.open("d")
        #expect(try await outcome(harness, d) == "completed")
        #expect(try await outcome(harness, tree.p) == "completed")
        try await harness.close(context: .background)
    }

    /// Live P owns `depth` ended tasks in a chain, the last owning conversation C, empty when they ended. Work started in
    /// C later is still P's: every case below must reach it through the ended tasks.
    private func endedBridge(_ depth: Int) async throws -> (held: HeldHarness, p: TaskID, c: ConversationID) {
        let held = try await openHeld()
        let tree = try await held.root.commit({ tx in
            let p = try await tx.hold(held.hold, "p", slowAbort: true)
            var links: [TaskID] = [], owner = p
            for n in 0..<depth { owner = try await tx.hold(held.hold, "link\(n)", owner: owner); links.append(owner) }
            return (p: p, links: links, c: try await tx.conversation(ownedBy: owner))
        }, context: .background)
        for n in (0..<depth).reversed() { held.gates.open("link\(n)") }
        for id in tree.links { _ = try await held.harness.waitForTask(id: id, context: .background) }
        return (held, tree.p, tree.c)
    }

    @Test(arguments: [2, 5]) func abortsWorkBelowEndedTasksWithTheirLiveOwnerWhichWaitsForIt(depth: Int) async throws {
        let (held, p, c) = try await endedBridge(depth)
        let d = try await start(held, in: c, "d")
        _ = try await held.harness.abortTask(id: p, context: .background)
        #expect(try await outcome(held.harness, d) == "aborted")
        // P's abort handler ran only after D ended.
        held.gates.open("abort.p")
        #expect(try await outcome(held.harness, p) == "aborted")
        try await held.harness.close(context: .background)
    }

    @Test(arguments: [2, 5]) func keepsTheRootBusyAndAbortsWithItWorkBelowEndedTasks(depth: Int) async throws {
        let (held, p, c) = try await endedBridge(depth)
        let harness = held.harness
        held.gates.open("p")
        _ = try await harness.waitForTask(id: p, context: .background)
        // P has ended: D and D2 hang below ended tasks only, and are still the root conversation's work.
        let d = try await start(held, in: c, "d"), d2 = try await start(held, in: c, "d2")
        #expect(!harness.tasks.idle(held.root.id) && !harness.tasks.idle(nil))
        let rootIdle = settled { try await held.root.waitForIdle(context: .background) }
        let harnessIdle = settled { try await harness.waitForIdle(context: .background) }
        try await held.root.abort(context: .background)
        for id in [d, d2] { #expect(try await outcome(harness, id) == "aborted") }
        try await eventually { rootIdle.isSettled && harnessIdle.isSettled }
        try await harness.close(context: .background)
    }

    @Test func reachesWorkBelowEndedTasksAcrossTwoOwnedConversations() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Live P -> ended B -> conversation C -> ended X -> ended A -> conversation C2; work starts in C2 later. X owns no
        // conversation, only the task A, so only owning a known task keeps it.
        let tree = try await held.root.commit({ tx in
            let p = try await tx.hold(held.hold, "p")
            let b = try await tx.hold(held.hold, "b", owner: p)
            let c = try await tx.conversation(ownedBy: b)
            let x = try await tx.hold(held.hold, "x", in: c)
            let a = try await tx.hold(held.hold, "a", owner: x)
            return (p: p, b: b, c2: try await tx.conversation(ownedBy: a))
        }, context: .background)
        for name in ["a", "x", "b"] { held.gates.open(name) }
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let d = try await start(held, in: tree.c2, "d")
        held.gates.open("p")
        try await eventually { try await status(harness, tree.p) == "completing" }
        #expect(!harness.tasks.idle(held.root.id))
        try await held.root.abort(context: .background)
        #expect(try await outcome(harness, d) == "aborted")
        #expect(try await outcome(harness, tree.p) == "completed")
        try await harness.close(context: .background)
    }

    @Test(arguments: ["completes", "is aborted"])
    func freesAnOwnerOnceTheLastWorkBelowEndedTasksEndsAfterABackgroundTaskThere(ending: String) async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Live P owns B, which owns A, which owns conversation C with background Z and, later, foreground D.
        let tree = try await held.root.commit({ tx in
            let p = try await tx.hold(held.hold, "p")
            let b = try await tx.hold(held.hold, "b", owner: p)
            let a = try await tx.hold(held.hold, "a", owner: b)
            let c = try await tx.conversation(ownedBy: a)
            return (p: p, b: b, c: c, z: try await tx.hold(held.hold, "z", in: c, background: true))
        }, context: .background)
        held.gates.open("a")
        held.gates.open("b")
        _ = try await harness.waitForTask(id: tree.b, context: .background)
        let d = try await start(held, in: tree.c, "d", slowAbort: true)
        if ending == "completes" {
            held.gates.open("p")
            try await eventually { try await status(harness, tree.p) == "completing" }
        } else {
            // P waits for D's abort before its own abort handler runs.
            _ = try await harness.abortTask(id: tree.p, context: .background)
            try await eventually { try await harness.getTask(id: d, context: .background)?.abortRequested == true }
        }
        // Z ends first, D last.
        held.gates.open("z")
        _ = try await harness.waitForTask(id: tree.z, context: .background)
        held.gates.open(ending == "completes" ? "d" : "abort.d")
        _ = try await harness.waitForTask(id: d, context: .background)
        #expect(try await outcome(harness, tree.p) == (ending == "completes" ? "completed" : "aborted"))
        try await harness.close(context: .background)
    }

    @Test func finalizesManyHeldSiblingsThatEndTogetherInOnePass() async throws {
        let held = try await openHeld()
        let harness = held.harness
        // Top holds 1000 held children, each holding one live leaf; the leaves end in one commit.
        let count = 1000
        let tree = try await held.root.commit({ tx in
            let top = try await tx.hold(held.hold, "top")
            var siblings: [TaskID] = []
            for n in 0..<count { siblings.append(try await tx.hold(held.hold, "s\(n)", owner: top)) }
            var leaves: [TaskID] = []
            for n in (0..<count).reversed() { leaves.append(try await tx.hold(held.hold, "l\(n)", owner: siblings[n])) }
            return (top: top, leaves: leaves)
        }, context: .background)
        for n in 0..<count { held.gates.open("s\(n)") }
        held.gates.open("top")
        try await eventually(timeout: .seconds(30)) {
            try await harness.inspect(context: .background).tasks.filter { $0.record.state.status == "completing" }.count == count + 1
        }
        try await eventually { harnessReconciled(harness) }
        // Task nodes walks down reach while it all finalizes: one pass walks the siblings once; a recheck of the holder
        // per freed sibling walks them again each time. Upstream bounds it at 20 per sibling, as its sets iterate in
        // insertion order; Swift's do not, so such a recheck stops at the first live sibling sooner, about n·ln n in all,
        // and only a bound of 2 per sibling tells it apart.
        let before = harnessWalked(harness)
        try await held.root.commit({ tx in
            // Reads before the first write.
            var records: [TaskRecord] = []
            for id in tree.leaves { records.append(try #require(await tx.task(id))) }
            for record in records { try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: .null)))) }
        }, context: .background)
        #expect(try await outcome(harness, tree.top) == "completed")
        #expect(harnessWalked(harness) - before < count * 2)
        try await harness.close(context: .background)
    }

    // Pins the Transaction rule that a conversation cannot be created in the commit that ends its owner task.
    @Test func rejectsAConversationCreatedInTheCommitThatEndsItsOwnerTask() async throws {
        let held = try await openHeld()
        let spawner = try await held.root.commit({ tx in
            try await tx.createTask(held.spawner, input: .init(name: "spawned"), options: .init(ownership: .conversation()))
        }, context: .background)
        let settled = try await held.harness.waitForTask(id: spawner, context: .background)
        guard case .faulted(let error, _) = settled.outcome else { Issue.record("Spawner must fault, got \(settled.outcome)"); return }
        #expect(["completing", "terminal"].map { "Conversation owner task \(spawner.rawValue) is \($0)" }.contains(error.message))
        try await held.harness.close(context: .background)
    }
}
