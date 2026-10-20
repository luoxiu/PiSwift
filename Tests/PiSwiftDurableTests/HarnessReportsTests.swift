// Every report says where it came from: `onReport(error, info)` (upstream harness-reports.test.ts).
import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct ReportCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case run, done }
    var phase: Phase = .run
}
private typealias ReportTask = TaskDefinition<JSONValue, ReportCheckpoint, JSONValue, NoTaskHooks>

private struct Report: Equatable {
    let message: String
    let info: ReportInfo
}

/// Open a Harness with `tasks` installed that collects every report's message and info.
private func open(_ tasks: [AnyTaskDefinition], storage: any DurableStorage = MemoryStorage(),
                  onWake: (@Sendable (Wake) throws -> Void)? = nil,
                  setTimer: SetTimer? = nil) async throws -> (harness: Harness, registry: Registry, reports: HarnessReports) {
    let registry = createRegistry()
    try registry.install(Extension(name: "test", tasks: tasks))
    let reports = HarnessReports()
    let harness = try await Harness.open(storage: storage, options: HarnessOptions(
        models: FakeDurableModels(), registry: registry, setTimer: setTimer, onWake: onWake,
        onReport: { reports.append($0, info: $1) }), context: .background)
    return (harness, registry, reports)
}

private func reportsOf(_ reports: HarnessReports) -> [Report] {
    zip(reports.values, reports.infos).map { Report(message: String(describing: $0), info: $1) }
}

@Suite struct HarnessReportsTests {
    @Test func sayWhichTaskReportedAFailureOrFaulted() async throws {
        let faulty = ReportTask(name: "test.faulty", version: 1, initial: { _ in ReportCheckpoint() }, phase: { _, runtime, _ in
            try runtime.report(TestFailure("noted"))
            throw TestFailure("broken")
        }, abort: { _, _, _ in })
        let (harness, _, reports) = try await open([AnyTaskDefinition(faulty)])
        let root = try await harness.root(context: .background)
        let id = try await root.commit({ tx in try await tx.createTask(faulty, input: .null, options: .init(ownership: .conversation())) },
                                       context: .background)
        try harness.resume()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "faulted")
        try await eventually { reports.count == 2 }
        let task = ReportInfo(source: .task, taskId: id, taskKind: "test.faulty", conversationId: root.id)
        #expect(reportsOf(reports) == [
            Report(message: "noted", info: task),
            Report(message: "broken", info: ReportInfo(source: .task, taskId: id, taskKind: "test.faulty", conversationId: root.id, faulted: true)),
        ])
        try await harness.close(context: .background)
    }

    @Test func tellExtensionListenerWakeAndTimerFailuresFromAFailedSession() async throws {
        let sleeper = ReportTask(name: "test.sleeper", version: 1, initial: { _ in ReportCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                // The host's setTimer throws: reported, and armed with the default timer instead.
                _ = runtime.setTimer({}, delayMs: 10)
                try await runtime.sleepUntil(try runtime.now() + 60_000, checkpoint: ReportCheckpoint(phase: .done), context: context)
            case .done:
                try await runtime.commit({ _, _ in try completed(JSONValue.null) }, context: context)
            }
        }, abort: { _, _, _ in })
        let storage = ControlledStorage()
        let (harness, registry, reports) = try await open([AnyTaskDefinition(sleeper)], storage: storage,
            onWake: { _ in throw TestFailure("alarm") },
            setTimer: { _, _, _ in throw TestFailure("no timers") })
        let echo = try ToolRegistration(name: "echo", description: "echo", parameters: [:]) { _, _, _ in ToolExecutionResult(output: []) }
        try registry.install(Extension(name: "tools", tools: [echo]))
        try registry.install(Extension(name: "wraps", wraps: [wrapTool(echo) { var tool = $0; tool.name = "renamed"; return tool }]))
        _ = try harness.subscribeCommits { _, _ in throw TestFailure("listener") }
        let root = try await harness.root(context: .background)
        _ = try await root.agent(context: .background)
        _ = try await root.commit({ tx in try await tx.createTask(sleeper, input: .null, options: .init(ownership: .conversation())) },
                                  context: .background)
        try harness.resume()
        try await eventually {
            let messages = reportsOf(reports).map(\.message)
            return messages.contains("alarm") && messages.contains("no timers")
        }
        let infoOf = { (message: String) in reportsOf(reports).first { $0.message == message }?.info }
        #expect(infoOf("Wrapper renamed echo to renamed") == ReportInfo(source: .extension, conversationId: root.id))
        #expect(infoOf("listener") == ReportInfo(source: .listener))
        #expect(infoOf("alarm") == ReportInfo(source: .wake))
        #expect(infoOf("no timers") == ReportInfo(source: .timer))

        await storage.failNextCommit(TestFailure("disk gone"))
        _ = try? await root.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        _ = await harness.closed
        #expect(infoOf("disk gone") == ReportInfo(source: .session))
    }
}
