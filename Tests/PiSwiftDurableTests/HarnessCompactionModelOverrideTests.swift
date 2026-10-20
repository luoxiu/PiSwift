import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// #10942: per-model compaction settings.
@Suite struct HarnessCompactionModelOverrideTests {
    // harness-compaction.test.ts:2396, both keys.
    @Test(arguments: ["faux/faux-1", "faux/other"])
    func currentModelOverrideAppliesToBlockingThreshold(key: String) async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        // Harness-wide: blocking only above the full window; the override for faux-1 blocks above 700.
        var policy = compactionBlockingPolicy
        policy.reserveTokens = 0; policy.modelOverrides = [key: .init(reserveTokens: 300)]
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        try await compactionTurn(chat, compactionText("u4", 200), "a4")
        #expect(chat.script.summaryRequests.count == (key == "faux/faux-1" ? 1 : 0))
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:2413.
    @Test func requestModelOverrideAppliesOnContextOverflow() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        var policy = compactionManualPolicy; policy.modelOverrides = ["faux/faux-1": .init(enabled: true)]
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText)), .message(chatAssistant("fits"))])
        let input = try await compactionNewInput(chat, tokens: 100)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(chat.script.summaryRequests.count == 1)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:2425.
    @Test func modelOverrideAppliesWhenCompactionSelectsAndSizesItsSummary() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        var policy = compactionManualPolicy
        policy.keepRecentTokens = 100_000; policy.modelOverrides = ["faux/faux-1": .init(reserveTokens: 500, keepRecentTokens: 150)]
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)).status == "completed")
        // 0.8 * 500 from the override, below the model's 900.
        #expect(chat.script.summaryRequests.first?.options?.maxTokens == 400)
        let messages = try await chat.root.context(context: .background).messages
        #expect(messages.dropFirst().map { textOf($0) ?? "" } == [compactionText("u3", 100), compactionText("a3", 100)])
        try await chat.harness.close(context: .background)
    }
    // Swift: the resolved settings carry the overrides, and the policy resolved for a model has none.
    @Test func resolvesOverridesFieldByField() {
        let settings = resolveSettings(.init(compaction: .init(reserveTokens: 1000, modelOverrides: [
            "local/small-32k": .init(reserveTokens: 4096, keepRecentTokens: 8000, backgroundTokens: 4096),
            "local/off": .init(enabled: false)
        ])))
        #expect(settings.compaction.modelOverrides?.count == 2)
        #expect(compactionPolicy(settings, model: .init(provider: "local", modelId: "small-32k"))
            == CompactionPolicy(enabled: true, reserveTokens: 4096, keepRecentTokens: 8000, backgroundTokens: 4096))
        #expect(compactionPolicy(settings, model: .init(provider: "local", modelId: "off"))
            == CompactionPolicy(enabled: false, reserveTokens: 1000, keepRecentTokens: 20000, backgroundTokens: 32768))
        // Exact keys: no provider-only or case-folded match.
        #expect(compactionPolicy(settings, model: .init(provider: "local", modelId: "Small-32k"))
            == CompactionPolicy(enabled: true, reserveTokens: 1000, keepRecentTokens: 20000, backgroundTokens: 32768))
    }
}
