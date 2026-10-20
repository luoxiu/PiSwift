import Foundation
import PiSwiftChord

/// A node of the ownership tree: a task, or a conversation. Walks up continue at one; `below` lists them downward.
internal enum OwnershipUp: Hashable, Sendable { case task(TaskID), conversation(ConversationID) }
/// One step of a walk up: an owner task with its node, a conversation, or an owner edge that is not loaded yet.
internal enum OwnershipStep: Sendable { case task(TaskID, TaskNode), conversation(ConversationID), unknown }
/// The immutable ownership fields of a task.
internal struct TaskNode: Sendable {
    let conversationId: ConversationID
    let owner: TaskID?
    let background: Bool
    init(_ record: TaskRecord) { conversationId = record.conversationId; owner = record.owner; background = record.background }
    /// The node it hangs from: its owner task, or its conversation.
    var parent: OwnershipUp { owner.map(OwnershipUp.task) ?? .conversation(conversationId) }
}
/// Candidate records a commit staged; they override committed records in ownership walks.
internal struct TaskOverlay: Sendable {
    var tasks: [TaskID: TaskRecord]
    /// Owner task of each staged conversation, nil when ownerless.
    let edges: [ConversationID: TaskID?]
    /// Links to the staged tasks `below` does not list, by parent node, for walks down; built at first use.
    var links: [OwnershipUp: Set<OwnershipUp>]?
    static let empty = TaskOverlay(tasks: [:], edges: [:], links: [:])
    init(tasks: [TaskID: TaskRecord], edges: [ConversationID: TaskID?], links: [OwnershipUp: Set<OwnershipUp>]? = nil) {
        self.tasks = tasks; self.edges = edges; self.links = links
    }
    init(_ tx: Transaction) throws {
        tasks = Dictionary(uniqueKeysWithValues: try tx.stagedTasks().map { ($0.id, $0) })
        edges = Dictionary(uniqueKeysWithValues: try tx.stagedConversations().map { ($0.id, $0.owner?.taskId) })
    }
}

/// The scheduler's in-memory ownership indexes (spec §5.5). Every method runs under the scheduler's lock, so a walk
/// sees one state. None recurses: ownership chains can be deeper than the call stack.
extension TaskScheduler.State {
    /// Owner task of a conversation, `.some(nil)` when ownerless, nil while not loaded.
    func edge(_ id: ConversationID, _ overlay: TaskOverlay = .empty) -> TaskID?? { overlay.edges[id] ?? edges[id] }
    func node(_ id: TaskID, _ overlay: TaskOverlay = .empty) -> TaskNode? {
        (overlay.tasks[id] ?? live[id]).map(TaskNode.init) ?? settled[id]
    }
    /// Live task IDs in the order they became live; others last.
    func ordered(_ ids: some Sequence<TaskID>) -> [TaskID] { ids.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) } }

    /// Walk up from `start`: owner tasks and conversations, ending at an ownerless root or an edge not loaded yet.
    /// `step` returns false to stop.
    func walkUp(_ start: OwnershipUp, overlay: TaskOverlay = .empty, _ step: (OwnershipStep) -> Bool) {
        var at: OwnershipUp? = start, seen = Set<OwnershipUp>()
        while let current = at, seen.insert(current).inserted {
            switch current {
            case .task(let id):
                guard let node = node(id, overlay) else { _ = step(.unknown); return }
                if !step(.task(id, node)) { return }
                at = node.parent
            case .conversation(let id):
                if !step(.conversation(id)) { return }
                guard let edge = self.edge(id, overlay) else { _ = step(.unknown); return }
                at = edge.map(OwnershipUp.task)
            }
        }
    }
    func above(_ start: OwnershipUp, overlay: TaskOverlay = .empty) -> [OwnershipStep] {
        var steps: [OwnershipStep] = []
        walkUp(start, overlay: overlay) { steps.append($0); return true }
        return steps
    }
    /// Whether ordinary traversal from the conversation, or from every ownerless conversation for nil, reaches `start`:
    /// walking up reaches the scope without crossing a background owner, unless `background`. Nil while an edge is not
    /// loaded.
    func inScope(_ start: OwnershipUp, conversationId: ConversationID?, background: Bool = false) -> Bool? {
        var found: Bool? = conversationId == nil
        walkUp(start) { step in
            switch step {
            case .unknown: found = nil; return false
            case .conversation(let id): if id == conversationId { found = true; return false }
            case .task(_, let node): if node.background && !background { found = false; return false }
            }
            return true
        }
        return found
    }
    func belowCancelled(_ start: OwnershipUp) -> Bool { cancellingOwner(start) != nil }
    /// The nearest live owner above `start` whose cancellation intent reaches it, if any: walking up finds an owner with
    /// intent before a background owner without it. Terminal owners never cascade (spec §5.4).
    func cancellingOwner(_ start: OwnershipUp) -> TaskRecord? {
        // Nothing cancels, the common case: no walk.
        if intent.isEmpty { return nil }
        var found: TaskRecord?
        walkUp(start) { step in
            guard case .task(let id, let node) = step else { return true }
            if let record = live[id], record.cancellationIntent { found = record; return false }
            return !node.background
        }
        return found
    }
    /// Whether the chain above `node` is loaded, without walking: known tasks outside `unloaded` have a loaded chain.
    func known(_ node: OwnershipUp) -> Bool {
        switch node {
        case .task(let id): return (live[id] != nil || settled[id] != nil) && !unloaded.contains(id)
        case .conversation(let id):
            guard let edge = edges[id] else { return false }
            return edge.map { known(.task($0)) } ?? true
        }
    }
    /// The nearest live task above ended ordinary work `node`, in the overlay's view: the one that work held, if any.
    /// Work at or below a background task holds nothing above it.
    func nearestLiveAbove(_ node: TaskNode, overlay: TaskOverlay = .empty) -> TaskRecord? {
        var current = node
        while !current.background {
            guard let owner = current.owner ?? (edge(current.conversationId, overlay) ?? nil) else { return nil }
            let record = overlay.tasks[owner] ?? live[owner]
            if let record, record.state.status != "terminal" { return record }
            guard let above = record.map(TaskNode.init) ?? settled[owner] else { return nil }
            current = above
        }
        return nil
    }

    /// The tasks below `start` that a walk down reaches: those `below` lists and the overlay's new tasks, with its
    /// candidates in place of committed records; `visit` gets each with its live record, nil once it ended, and returns
    /// false to stop. Background tasks are reached but not entered, unless `crossBackground`, and neither are the tasks
    /// `enter` rejects.
    mutating func walkDown(_ start: OwnershipUp, overlay: inout TaskOverlay, crossBackground: Bool = false,
                           enter: ((TaskID) -> Bool)? = nil, _ visit: (TaskID, TaskNode, TaskRecord?) -> Bool) {
        if overlay.links == nil { overlay.links = links(overlay) }
        let staged = overlay.links ?? [:]
        var pending: [OwnershipUp] = [start]
        while let at = pending.popLast() {
            for children in [below[at], staged[at]] {
                for child in children ?? [] {
                    guard case .task(let id) = child else { pending.append(child); continue }
                    let record = overlay.tasks[id] ?? live[id]
                    guard let node = record.map(TaskNode.init) ?? settled[id] else { continue }
                    walked += 1
                    if !visit(id, node, record.flatMap { $0.state.status == "terminal" ? nil : $0 }) { return }
                    if (crossBackground || !node.background) && (enter?(id) ?? true) { pending.append(child) }
                }
            }
        }
    }
    mutating func walkDown(_ start: OwnershipUp, crossBackground: Bool = false, enter: ((TaskID) -> Bool)? = nil,
                           _ visit: (TaskID, TaskNode, TaskRecord?) -> Bool) {
        var overlay = TaskOverlay.empty
        walkDown(start, overlay: &overlay, crossBackground: crossBackground, enter: enter, visit)
    }
    /// The links walks down need for the commit's new tasks: each one under its parent node, then each node above it
    /// that `below` does not list yet, until one it lists, a live task (always listed), or the chain's end.
    func links(_ overlay: TaskOverlay) -> [OwnershipUp: Set<OwnershipUp>] {
        var links: [OwnershipUp: Set<OwnershipUp>] = [:]
        for record in overlay.tasks.values where live[record.id] == nil && settled[record.id] == nil {
            var child = OwnershipUp.task(record.id), parent: OwnershipUp? = record.parent
            while let up = parent, links[up]?.contains(child) != true {
                links[up, default: []].insert(child)
                if case .task(let id) = up, live[id] != nil || overlay.tasks[id] != nil { break }
                let above: OwnershipUp?
                switch up {
                case .conversation(let id): above = (edge(id, overlay) ?? nil).map(OwnershipUp.task)
                case .task(let id): above = settled[id]?.parent
                }
                if let above, below[above]?.contains(up) == true { break }
                child = up; parent = above
            }
        }
        return links
    }
    /// The live ordinary owned work of `owner` (spec §5.5): the live non-background tasks below it that a walk down
    /// reaches without entering a background task; with `first`, only the first. Candidates in `overlay` replace
    /// committed records; the walk does not enter tasks in `done`, which have none. Owner chains must be loaded.
    mutating func ownedLive(_ owner: TaskID, overlay: inout TaskOverlay, first: Bool = false, done: Set<TaskID> = []) -> [TaskID] {
        var found: [TaskID] = []
        walkDown(.task(owner), overlay: &overlay, enter: done.isEmpty ? nil : { !done.contains($0) }) { id, node, live in
            guard live != nil, !node.background else { return true }
            found.append(id); return !first
        }
        return found
    }
    mutating func hasOwnedLive(_ owner: TaskID, overlay: inout TaskOverlay, done: Set<TaskID> = []) -> Bool {
        !ownedLive(owner, overlay: &overlay, first: true, done: done).isEmpty
    }
    mutating func hasOwnedLive(_ owner: TaskID) -> Bool {
        var overlay = TaskOverlay.empty
        return hasOwnedLive(owner, overlay: &overlay)
    }
    /// The path from a member of `on` back to `task` in the wait-for graph, if the wait would close a cycle (spec §5.1).
    /// An edge X -> Y means X cannot settle before Y: Y is in the `on` of waiting X that is not abort-marked, or Y is live
    /// ordinary owned work of X, which holds X as `completing`. Each task is visited once and each subtree walked once, so
    /// a check is bounded by the live work it reaches. Owner chains must be loaded.
    mutating func waitCycle(_ task: TaskID, _ on: [TaskID], overlay: inout TaskOverlay) -> [TaskID]? {
        var from: [TaskID: TaskID?] = [:]
        // Upstream's `walked`; named apart from the walk probe.
        var walkedTasks = Set<TaskID>()
        var pending: [TaskID] = []
        func reach(_ id: TaskID, _ via: TaskID?) {
            if from.keys.contains(id) { return }
            from[id] = .some(via)
            pending.append(id)
        }
        func path(_ end: TaskID) -> [TaskID] {
            var steps: [TaskID] = []
            var at: TaskID? = end
            while let step = at { steps.append(step); at = from[step] ?? nil }
            return steps.reversed()
        }
        for id in on { reach(id, nil) }
        while let id = pending.popLast() {
            if id == task { return path(id) }
            guard let record = overlay.tasks[id] ?? live[id], record.state.status != "terminal" else { continue }
            // An abort-marked task waits only for its owned work, as abort runs bottom-up (`waitingOn`).
            if case .waiting(_, let members, _, _) = record.state, !record.abortRequested {
                for member in members { reach(member, id) }
            }
            if !walkedTasks.insert(id).inserted { continue }
            // Below a walked task the walk does not go again: its own walk covered what lies below.
            var found: [TaskID] = []
            let entered = walkedTasks
            walkDown(.task(id), overlay: &overlay, enter: { !entered.contains($0) }) { below, node, live in
                guard live != nil, !node.background else { return true }
                found.append(below)
                reach(below, id)
                return true
            }
            walkedTasks.formUnion(found)
        }
        return nil
    }
    /// Live tasks a task waits for before its next invocation: its live ordinary owned work when abort-marked, since
    /// abort runs bottom-up, otherwise the live part of the `on` of a wait; with `first`, only the first.
    mutating func waitingOn(_ record: TaskRecord, first: Bool = false) -> [TaskID] {
        if record.abortRequested {
            var overlay = TaskOverlay.empty
            return ordered(ownedLive(record.id, overlay: &overlay, first: first))
        }
        guard case .waiting(_, let on, _, _) = record.state else { return [] }
        if !first { return on.filter { live[$0] != nil } }
        return on.first { live[$0] != nil }.map { [$0] } ?? []
    }
    /// No live non-background task in the scope; a task whose owner edges are not loaded yet counts as inside.
    mutating func idle(_ conversationId: ConversationID?) -> Bool {
        // Tasks whose chain is not loaded are not listed below their scope yet; one counts as inside unless its walk up
        // decides otherwise.
        for id in unloaded {
            if let record = live[id], !record.background, inScope(record.parent, conversationId: conversationId) != false { return false }
        }
        var busy = false
        for start in conversationId.map({ [$0] }) ?? Array(roots) {
            walkDown(.conversation(start)) { _, node, live in
                busy = live != nil && !node.background
                return !busy
            }
            if busy { return false }
        }
        return true
    }
    /// Every live foreground task below a live owner with cancellation intent, with the reason its nearest such owner
    /// passes on: a walk down from each owner with intent does not enter another, whose own walk covers what is below
    /// it. Only an owner abandoned after a restart, and nothing else, passes its `restart` reason on.
    mutating func cascades() -> [(record: TaskRecord, reason: TaskAbortReason?)] {
        var found: [(record: TaskRecord, reason: TaskAbortReason?)] = []
        let intent = self.intent
        for id in intent {
            guard let owner = live[id] else { continue }
            let reason: TaskAbortReason? = owner.abortReason == .restart && !owner.failedOutcome ? .restart : nil
            walkDown(.task(id), enter: { !intent.contains($0) }) { _, node, live in
                if let live, !node.background { found.append((live, reason)) }
                return true
            }
        }
        return found
    }

    /// Bring the indexes in line with a task's committed record. A task that ended may free the nearest live task above
    /// it: one holding its outcome finalizes, an abort-marked one runs its abort handler; its waiters may run.
    /// Whether a reconcile pass would have work: a cascade to derive, held outcomes to check, or `failFast` waits.
    var reconcileWork: Bool { cascadePending || !finalizeChecks.isEmpty || !failFastChecks.isEmpty }
    mutating func track(_ previous: TaskRecord?, _ record: TaskRecord) {
        let id = record.id
        if case .waiting(_, let on, _, _)? = previous?.state { for task in on { deleteFrom(&waiters, task, id) } }
        if record.state.status == "terminal" {
            let node = TaskNode(record)
            live.removeValue(forKey: id); order.removeValue(forKey: id)
            sleeping.remove(id); intent.remove(id); runnable.remove(id); finalizeChecks.remove(id)
            settled[id] = node
            // Before anything is forgotten: the walk up to the task it held passes the ended tasks between them. Its chain
            // is loaded, as every commit that ends a task loads the chains of `unloaded` first.
            release(node)
            for waiter in waiters[id] ?? [] { runnable.insert(waiter) }
            relist(.task(id))
            dropIfUnneeded(.task(id))
            return
        }
        live[id] = record
        if previous == nil {
            order[id] = nextOrder; nextOrder += 1
            if !known(record.parent) { unloaded.insert(id) }
            relist(.task(id))
        }
        if record.cancellationIntent { intent.insert(id) } else { intent.remove(id) }
        if record.state.status == "completing" { runnable.remove(id); finalizeChecks.insert(id) }
        else { runnable.insert(id) }
        if case .waiting(_, let on, _, _) = record.state { for task in on { waiters[task, default: []].insert(id) } }
        if record.state.status == "sleeping" { sleeping.insert(id) } else { sleeping.remove(id) }
    }
    /// Make every sleeping task whose time has come a reservation candidate.
    mutating func wakeDue(now: Int64) {
        for id in sleeping {
            if let record = live[id], !record.notDue(now) { runnable.insert(id) }
        }
    }
    /// The nearest live task above ended ordinary work may be free now: one holding its outcome, or an aborting one.
    mutating func release(_ node: TaskNode) {
        guard let above = nearestLiveAbove(node) else { return }
        if above.state.status == "completing" { finalizeChecks.insert(above.id) }
        else if above.abortRequested { runnable.insert(above.id) }
    }
    mutating func setEdge(_ id: ConversationID, _ owner: TaskID?) {
        edges.updateValue(owner, forKey: id)
        // The conversation now hangs from its owner, or is a root; with nothing below it, it waits for the sweep.
        relist(.conversation(id))
        dropIfUnneeded(.conversation(id))
    }
    /// Know a terminal task a chain load read, so walks pass through it; its own chain is not loaded yet.
    mutating func settle(_ id: TaskID, _ node: TaskNode) {
        settled[id] = node; unloaded.insert(id)
        relist(.task(id))
        dropIfUnneeded(.task(id))
    }
    /// Queue an ended task or a conversation for the sweep when nothing is listed below it.
    mutating func dropIfUnneeded(_ node: OwnershipUp) {
        if case .task(let id) = node, live[id] != nil { return }
        if below[node] != nil { return }
        dropQueue.insert(node)
    }
    /// Drop the queued nodes that are still unneeded: not live, nothing listed below. Runs once a publication is fully
    /// tracked, and as a job of its own on the line, never inside an operation: work a commit creates below a chain its
    /// own callback loaded keeps that chain. A flat loop: unlisting already queued every node on the way up that lost its
    /// last listed node.
    mutating func sweep() {
        for node in dropQueue where below[node] == nil {
            switch node {
            case .conversation(let id): edges.removeValue(forKey: id); roots.remove(id)
            case .task(let id): if live[id] == nil { settled.removeValue(forKey: id); unloaded.remove(id) }
            }
        }
        dropQueue.removeAll()
    }
    /// List `start` under its parent node in `below` while it is a live task or has nodes listed below it, and unlist it
    /// otherwise; then its parent, as far up as that changes. So `below` holds exactly the tree around live work; a
    /// parent that loses its last listed node is queued for the sweep.
    mutating func relist(_ start: OwnershipUp) {
        var node = start
        while true {
            var needed = below[node] != nil
            let parent: OwnershipUp
            switch node {
            case .conversation(let id):
                guard let edge = edges[id] else { return }
                guard let owner = edge else {
                    if needed { roots.insert(id) } else { roots.remove(id) }
                    return
                }
                parent = .task(owner)
            case .task(let id):
                needed = needed || live[id] != nil
                guard let known = live[id].map(TaskNode.init) ?? settled[id] else { return }
                parent = known.parent
            }
            if (below[parent]?.contains(node) == true) == needed { return }
            if needed {
                let first = below[parent] == nil
                below[parent, default: []].insert(node)
                if !first { return }
            } else {
                deleteFrom(&below, parent, node)
                if below[parent] != nil { return }
                dropIfUnneeded(parent)
            }
            node = parent
        }
    }
}

private func deleteFrom<Key: Hashable, Value: Hashable>(_ map: inout [Key: Set<Value>], _ key: Key, _ value: Value) {
    guard var values = map[key] else { return }
    values.remove(value)
    map[key] = values.isEmpty ? nil : values
}

internal extension TaskRecord {
    /// Whether a live owner's cancellation reaches the work below it: an abort mark, or an outcome other than `completed`.
    var cancellationIntent: Bool { state.status != "terminal" && (abortRequested || failedOutcome) }
}
