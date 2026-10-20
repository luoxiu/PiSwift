import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// A tool that calls each of `names` as a nested call and records what it got back.
private func prober(_ names: [String]) throws -> (registration: ToolRegistration, received: NestedResults) {
    let received = NestedResults()
    let registration = try nestedTool("probe") { _, api, context in
        for name in names { received.set(name, try await api.executeTool(name, context: context)) }
        return .init()
    }
    return (registration, received)
}
private func callerTool(_ name: String, callers: [ToolCaller]? = nil,
                        execute: (@Sendable (JSONObject, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult)? = nil) throws -> ToolRegistration {
    try nestedTool(name, callers: callers, execute: execute ?? { _, _, _ in .init(output: [.text(TextContent(text: "\(name) ran"))]) })
}
private func offered(_ root: Conversation) async throws -> [String] { try await root.agent(context: .background).tools.map(\.name) }
private func callable(_ root: Conversation) async throws -> [String] { try await root.agent(context: .background).callable.map(\.name) }

/// Port of upstream `test/harness-callers.test.ts`.
@Suite struct HarnessCallersTests {
    @Test func offersModelOnlyToolsItMayCallAndLetsToolsCallOnlyToolsTheyMayCall() async throws {
        let setup = HarnessChatSetup()
        let probe = try prober(["script", "hidden", "both"])
        for tool in [try callerTool("script", callers: [.model]), try callerTool("hidden", callers: [.tools]), try callerTool("both"), probe.registration] {
            try installHarnessTool(tool, setup: setup)
        }
        setup.models.setResponses([.message(try nestedCall("probe")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        #expect(try await offered(opened.root) == ["script", "both", "probe"])
        #expect(try await callable(opened.root) == ["hidden", "both", "probe"])
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let received = probe.received
        #expect(received["script"]?.diagnostics.first?.code == "tool_unavailable")
        #expect(received["hidden"]?.isError == false && received["hidden"]?.structuredOutput == "hidden ran")
        #expect(received["both"]?.isError == false && received["both"]?.structuredOutput == "both ran")
        try await opened.harness.close(context: .background)
    }

    @Test func narrowsWhatTheModelIsOfferedWithModelToolsLeavingTheRestCallableByTools() async throws {
        let setup = HarnessChatSetup()
        let read = try callerTool("read"), bash = try callerTool("bash"), probe = try prober(["read", "bash"])
        for tool in [read, bash, probe.registration] { try installHarnessTool(tool, setup: setup) }
        setup.models.setResponses([.message(try nestedCall("probe")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([probe.registration]))), context: .background)
        #expect(try await offered(opened.root) == ["probe"])
        #expect(try await callable(opened.root) == ["read", "bash", "probe"])
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(probe.received["read"]?.isError == false)
        #expect(probe.received["bash"]?.isError == false)

        try await opened.root.configure(change: .init(modelTools: .set(.remove([bash]))), context: .background)
        #expect(try await offered(opened.root) == ["read", "probe"])
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == .remove(["bash"]))
        try await opened.root.configure(change: .init(modelTools: .clear), context: .background)
        #expect(try await offered(opened.root) == ["read", "bash", "probe"])
        try await opened.harness.close(context: .background)
    }

    @Test func neverOffersAToolThatIsNotEnabledNorLetsToolsCallIt() async throws {
        let setup = HarnessChatSetup()
        let read = try callerTool("read"), bash = try callerTool("bash"), probe = try prober(["bash"])
        for tool in [read, bash, probe.registration] { try installHarnessTool(tool, setup: setup) }
        setup.models.setResponses([.message(try nestedCall("probe")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        // modelTools cannot bring back what tools disabled.
        try await opened.root.configure(change: .init(tools: .set(.remove([bash])), modelTools: .set(.exact([bash, probe.registration]))), context: .background)
        #expect(try await offered(opened.root) == ["probe"])
        #expect(try await callable(opened.root) == ["read", "probe"])
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(probe.received["bash"]?.diagnostics.first?.code == "tool_unavailable")
        try await opened.harness.close(context: .background)
    }

    @Test func answersAModelIssuedCallOfAToolItWasNotOfferedAsUnavailable() async throws {
        let setup = HarnessChatSetup()
        let read = try callerTool("read"), bash = try callerTool("bash")
        for tool in [read, bash] { try installHarnessTool(tool, setup: setup) }
        setup.models.setResponses([.message(try nestedCall("bash")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([read]))), context: .background)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let result = try #require(try harnessToolResults(try await allEntries(opened.root)).first)
        #expect(harnessToolText(result).contains("Tool bash is not available"))
        try await opened.harness.close(context: .background)
    }

    @Test func appliesAddToolsToModelToolsTooSoTheModelIsOfferedTheAddedTools() async throws {
        let setup = HarnessChatSetup()
        let extra = try callerTool("extra")
        let grow = try callerTool("grow") { _, _, _ in .init(output: [], control: .init(addTools: ["extra"])) }
        for tool in [extra, grow] { try installHarnessTool(tool, setup: setup) }
        setup.models.setResponses([.message(try nestedCall("grow")), .message(nestedDone)])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(modelTools: .set(.exact([grow]))), context: .background)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == .exact(["grow", "extra"]))
        #expect(try await offered(opened.root) == ["grow", "extra"])
        try await opened.harness.close(context: .background)
    }
}
