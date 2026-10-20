import Synchronization
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Input of a held task: the gate it waits on and, with `slowAbort`, whether its abort handler first waits for the gate
/// `abort.<name>`.
struct HarnessHoldInput: Codable, Sendable {
    var name: String
    var slowAbort = false
}
typealias HarnessHoldTask = TaskDefinition<HarnessHoldInput, HarnessTaskCheckpoint, Int, NoTaskHooks>

/// Named gates for held tasks, one set per test; a gate opened before its task waits counts.
final class HarnessHoldGates: Sendable {
    private struct State {
        var outcomes: [String: TaskOutcome] = [:]
        var waiters: [String: [HarnessChatSignal]] = [:]
    }
    private let state = Mutex(State())
    /// Opens the gate: its task commits `outcome`.
    func open(_ name: String, _ outcome: TaskOutcome = .completed(result: .null)) {
        let waiters = state.withLock { state in
            state.outcomes[name] = outcome
            return state.waiters.removeValue(forKey: name) ?? []
        }
        for waiter in waiters { waiter.signal() }
    }
    /// The outcome the gate opened with, or nil when `signal` aborts first.
    func wait(_ name: String, signal: AbortSignal? = nil) async -> TaskOutcome? {
        let wake = HarnessChatSignal()
        let opened = state.withLock { state -> TaskOutcome? in
            if let outcome = state.outcomes[name] { return outcome }
            state.waiters[name, default: []].append(wake)
            return nil
        }
        if let opened { return opened }
        let registration = signal?.addAbortListener { _ in wake.signal() }
        defer { if let signal, let registration { signal.removeAbortListener(registration) } }
        if signal?.aborted == true { wake.signal() }
        await wake.wait()
        return state.withLock { $0.outcomes[name] }
    }
}

/// A task that holds until its named gate opens, then commits the gate's outcome, or until it is aborted. Its abort
/// handler ends it `aborted`.
func harnessHold(_ gates: HarnessHoldGates, name: String = "test.hold") -> HarnessHoldTask {
    HarnessHoldTask(name: name, version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
        guard let outcome = await gates.wait(task.input.name, signal: runtime.signal) else { return }
        try await runtime.commit({ _, _ in .terminal(outcome: outcome) }, context: context)
    }, abort: { task, runtime, context in
        if task.input.slowAbort { _ = await gates.wait("abort.\(task.input.name)") }
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}

/// Task nodes the scheduler's walks down have reached so far.
func harnessWalked(_ harness: Harness) -> Int { harness.tasks.state.withLock { $0.walked } }
/// Whether no reconcile pass is scheduled or running and none has holders left to check, so a walk count read now
/// leaves out the passes earlier commits caused.
func harnessReconciled(_ harness: Harness) -> Bool {
    harness.tasks.state.withLock { !$0.reconcileScheduled && $0.reconciles.isEmpty && $0.finalizeChecks.isEmpty }
}
