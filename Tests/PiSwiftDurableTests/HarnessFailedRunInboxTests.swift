// Inputs queued behind a failed run: `settings.afterFailedRun` (upstream harness-failed-run-inbox.test.ts).
import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// A response that fails for good once released; `reached` fires when it was requested.
private func failingOnce() -> HarnessGatedResponse {
    HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "Invalid request"))
}

/// A run that fails with an input queued behind it, under `policy`; returns how the queued input settled.
private func failWithQueuedInput(_ policy: AfterFailedRun?) async throws -> (harness: Harness, root: Conversation, second: Submission) {
    let setup = HarnessChatSetup(settings: HarnessSettings(afterFailedRun: policy))
    let failing = failingOnce()
    setup.models.setResponses([failing.step, .message(chatAssistant("second answer")), .message(chatAssistant("third answer"))])
    let chat = try await openChat(setup: setup)
    let first = try await chat.root.submit(.input(content: .text("Analyze this report")), context: .background)
    await failing.reached.wait()
    let second = try await chat.root.submit(.input(content: .text("Email me the summary"), whenBusy: .followUp), context: .background)
    failing.release()
    let settled = try await first.wait(context: .background)
    #expect(settled.status == "unanswered" && settled.reason == "model_error")
    return (chat.harness, chat.root, second)
}

@Suite struct HarnessFailedRunInboxTests {
    @Test func stayQueuedByDefault() async throws {
        let (harness, root, second) = try await failWithQueuedInput(nil)
        try await harness.waitForIdle(context: .background)
        #expect(try await second.status(context: .background).status == "queued")
        // The next input runs the queue, as before.
        let third = try await root.submit(.input(content: .text("Anything else?")), context: .background)
        #expect(try await second.wait(context: .background).status == "done")
        #expect(try await third.wait(context: .background).status == "done")
        try await harness.close(context: .background)
    }

    @Test func startTheNextRunWithThemWithContinue() async throws {
        let (harness, root, second) = try await failWithQueuedInput(.continue)
        let settled = try await second.wait(context: .background)
        #expect(settled.status == "done")
        let answer = try #require(settled.answer)
        let entry = try await allEntries(root).first { $0.id == answer }
        #expect(textOf(try entry?.messages()?.first) == "second answer")
        try await harness.close(context: .background)
    }

    @Test func settleUnansweredWithRunFailedWithWithdraw() async throws {
        let (harness, _, second) = try await failWithQueuedInput(.withdraw)
        let settled = try await second.wait(context: .background)
        #expect(settled.status == "unanswered" && settled.reason == "run_failed")
        try await harness.close(context: .background)
    }
}
