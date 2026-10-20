import Testing
import PiSwiftAI
import PiSwiftCodingAgent

// Source: packages/coding-agent/test/compaction-serialization.test.ts at 15e7bdc14 ("should omit thinking").
// Tool call arguments use this port's own `key=value` format, not upstream's JSON values.
@Test func serializeConversationOmitsThinking() {
    let message = AssistantMessage(content: [
        .thinking(ThinkingContent(thinking: "private reasoning", thinkingSignature: "sig")),
        .text(TextContent(text: "visible reply")),
        .toolCall(ToolCall(id: "tc1", name: "read", arguments: ["path": AnyCodable("a.ts")]))
    ], api: .anthropicMessages, provider: "anthropic", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse, timestamp: 0)
    #expect(serializeConversation([.assistant(message)]) == "[Assistant]: visible reply\n\n[Assistant tool calls]: read(path=a.ts)")
}
