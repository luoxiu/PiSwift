import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct ReadmeExamplesTests {
    @Test func quickStart() async throws {
        // README: quick-start
        let context = ChordContext.background
        let models = FakeDurableModels(responses: [.message(fauxAssistantMessage(
            content: [.text(TextContent(text: "Paris."))], timestamp: 1))])
        let registry = createRegistry()
        try registry.install(Extension(name: "terse", sections: [
            section("preamble", tag: false) { _, _ in "You answer in one word." }
        ]))
        let harness = try await Harness.open(storage: MemoryStorage(),
            options: .init(models: models, registry: registry), context: context)
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
        let submission = try await root.submit(
            .input(content: .text("Capital of France?")), context: context)
        let settled = try await submission.wait(context: context)
        if let answer = settled.answer {
            let entry = try await root.commit({ tx in try await tx.entry(answer) }, context: context)
            let messages = try entry?.messages()
            print(messages ?? [])
        }
        try await harness.close(context: context)
        // README: end
        #expect(settled.status == "done")
        #expect(models.state().callCount == 1)
    }

    @Test func persistAndResume() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("readme.sqlite").path
        let context = ChordContext.background
        let models = FakeDurableModels(responses: [.message(fauxAssistantMessage(
            content: [.text(TextContent(text: "Hello."))], timestamp: 1))])
        let registry = createRegistry()
        // README: persist-and-resume
        let options = HarnessOptions(models: models, registry: registry)
        let first = try await Harness.open(storage: SqliteStorage.open(path: path),
            options: options, context: context)
        let root = try await first.root(options: .init(agent: .init(
            model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
        let original = try await root.submit(.input(content: .text("Hello"),
            requestId: "greeting-1"), context: context)
        _ = try await original.wait(context: context)
        try await first.close(context: context)

        let reopened = try await Harness.open(storage: SqliteStorage.open(path: path),
            options: options, context: context)
        let sameRoot = try await reopened.root(context: context)
        try reopened.resume()
        let again = try await sameRoot.submit(.input(content: .text("Hello"),
            requestId: "greeting-1"), context: context)
        // again.id == original.id: no second input is admitted.
        let settled = try await again.wait(context: context)
        try await reopened.close(context: context)
        // README: end
        #expect(sameRoot.id == root.id)
        #expect(again.id == original.id)
        #expect(settled.status == "done")
        #expect(models.state().callCount == 1)
    }

    @Test func sleepingAndWakingUp() async throws {
        let context = ChordContext.background
        let clock = TestClock(now: 1_000), notified = Mutex<[String]>([])
        @Sendable func notify(_ text: String) async { notified.withLock { $0.append(text) } }
        // README: sleeping
        struct ReminderInput: Codable, Sendable { let text: String; let at: Int64 }
        struct ReminderState: TaskCheckpoint {
            enum Phase: String, Codable, Sendable { case wait, deliver }
            var phase: Phase = .wait
        }
        let reminder = TaskDefinition<ReminderInput, ReminderState, JSONValue, NoTaskHooks>(
            name: "app.reminder", version: 1, initial: { _ in ReminderState() },
            phase: { task, runtime, context in
                switch task.checkpoint.phase {
                // Returns once the sleep is stored; the phase ends there.
                case .wait: try await runtime.sleepUntil(task.input.at, checkpoint: ReminderState(phase: .deliver), context: context)
                case .deliver:
                    await notify(task.input.text)
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
                }
            },
            abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        // README: end
        let registry = createRegistry()
        try registry.install(Extension(name: "reminders", tasks: [AnyTaskDefinition(reminder)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: registry,
            now: clock.nowFunction, setTimer: clock.setTimer), context: context)
        let root = try await harness.root(context: context)
        let id = try await root.commit({ tx in
            try await tx.createTask(reminder, input: ReminderInput(text: "stretch", at: 61_000), options: .init(ownership: .conversation()))
        }, context: context)
        try harness.resume()
        try await eventually { try await harness.getTask(id: id, context: context)?.state.status == "sleeping" }
        #expect(notified.withLock { $0 }.isEmpty)
        clock.advance(by: 60_000)
        #expect(try await harness.waitForTask(id: id, context: context).outcome.status == "completed")
        #expect(notified.withLock { $0 } == ["stretch"])
        try await harness.close(context: context)
    }

    @Test func hostWakeup() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("readme.sqlite").path
        let context = ChordContext.background
        let models = FakeDurableModels(responses: [.message(fauxAssistantMessage(content: [.text(TextContent(text: "Hi."))], timestamp: 1))])
        let registry = createRegistry()
        let alarm = ReadmeAlarm(), clock: @Sendable () -> Int64 = { 1_000 }
        // README: host-wakeup
        @Sendable func alarmTime(_ wake: Wake, now: Int64) -> Int64? {
            guard wake.active else { return wake.at }
            return min(now + 60_000, wake.at ?? .max)
        }
        let options = HarnessOptions(models: models, registry: registry,
            onWake: { wake in alarm.arm(at: alarmTime(wake, now: clock())) })
        let harness = try await Harness.open(storage: SqliteStorage.open(path: path),
            options: options, context: context)
        try harness.resume()
        // When the alarm fires: resume due sleeps and work a lost process left, then arm again.
        try harness.resume()
        alarm.arm(at: alarmTime(try harness.wake(), now: clock()))
        // Before admitting work: an early alarm is harmless, a missing one strands the work.
        alarm.arm(at: alarmTime(Wake(active: true, at: try harness.wake().at), now: clock()))
        let root = try await harness.root(context: context)
        _ = try await root.submit(.input(content: .text("Hello")), context: context)
        // README: end
        #expect(alarm.times.contains(61_000))
        try await root.waitForIdle(context: context)
        try await eventually { alarm.times.last == .some(nil) }
        try await harness.close(context: context)
    }

    @Test func extensionsToolsAndWatching() async throws {
        let context = ChordContext.background
        let models = FakeDurableModels(responses: [
            .message(fauxAssistantMessage(content: [.toolCall(ToolCall(
                id: "echo-1", name: "echo", arguments: ["text": AnyCodable("hello")]))],
                stopReason: .toolUse, timestamp: 1)),
            .message(fauxAssistantMessage(content: [.text(TextContent(text: "Done."))], timestamp: 2))
        ])
        let registry = createRegistry()
        // README: extensions-and-tools
        let echo = try ToolRegistration(name: "echo", description: "Return text",
            parameters: ["type": "object", "properties": .object([
                "text": .object(["type": "string"])
            ]), "required": .array(["text"])], replay: .safe) { args, _, _ in
                ToolExecutionResult(output: [.text(TextContent(
                    text: args["text"]?.stringValue ?? ""))])
            }
        try registry.install(Extension(name: "echo", tools: [echo]))
        // README: end
        let harness = try await Harness.open(storage: MemoryStorage(),
            options: .init(models: models, registry: registry), context: context)
        let root = try await harness.root(options: .init(agent: .init(
            model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
        // README: watching
        let observed = Mutex<[ConversationView]>([])
        let watch = try await root.watch(context: context)
        let initial = watch.value
        try watch.start { value, ops, _ in
            // A UI can render value. A remote observer can apply the exact ops.
            observed.withLock { $0.append(value) }
            print(ops.count)
        }
        // README: end
        let submission = try await root.submit(.input(content: .text("Echo hello")), context: context)
        #expect(try await submission.wait(context: context).status == "done")
        await watch.waitUntilIdle()
        _ = await watch.stop()
        #expect(initial.entries.isEmpty)
        let latest = try #require(observed.withLock { $0.last })
        let result = try #require(latest.entries.first { $0.kind == "pi.tool-result" })
        if case .toolResult(let message) = try result.messages()?.first {
            if case .text(let text) = message.content.first {
                #expect(text.text == "hello")
            } else { Issue.record("Expected tool text") }
        } else { Issue.record("Expected an echo tool result") }
        try await harness.close(context: context)
    }
}

/// The host scheduler the README's wakeup example arms; it records each time.
private final class ReadmeAlarm: Sendable {
    private let state = Mutex<[Int64?]>([])
    var times: [Int64?] { state.withLock { $0 } }
    func arm(at time: Int64?) { state.withLock { $0.append(time) } }
}
