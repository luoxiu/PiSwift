import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func tool(_ name: String, _ description: String, deferred: Bool? = nil) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description,
        parameters: ["type": "object", "properties": ["number": ["type": "number", "description": "Issue number"]]],
        deferred: deferred) { _, _, _ in .init(output: [.text(TextContent(text: "\(name) ran"))]) }
}

/// `alpha`, the deferred `github_get_issue` and `github_list_repos`, then `omega`, and `tool_search` last.
private func toolSearchSetup() throws -> HarnessChatSetup {
    let chat = HarnessChatSetup()
    try installHarnessTool(try tool("alpha", "Alpha tool"), setup: chat)
    try installHarnessTool(try tool("github_get_issue", "Get a GitHub issue by number", deferred: true), setup: chat)
    try installHarnessTool(try tool("github_list_repos", "List the repositories of a user", deferred: true), setup: chat)
    try installHarnessTool(try tool("omega", "Omega tool"), setup: chat)
    try chat.registry.install(try createToolSearchExtension())
    return chat
}

private func offered(_ root: Conversation) async throws -> [String] { try await root.agent(context: .background).tools.map(\.name) }
private func deferred(_ root: Conversation) async throws -> [String] { try await root.agent(context: .background).deferred.map(\.name) }
private func modelTools(_ harness: Harness, _ root: Conversation) async throws -> ModelToolSelection? {
    try await harness.snapshot(AgentDoc, conversationId: root.id, context: .background)?.modelTools
}

/// The model messages of the `pi.system` entries, oldest first.
private func systemMessages(_ entries: [EntryRecord]) throws -> [SystemMessage] {
    try entries.filter { $0.kind == systemEntry.kind }.compactMap { entry in
        try entry.messages()?.first.flatMap { if case .system(let system) = $0 { system } else { nil } }
    }
}

private func toolResultTexts(_ entries: [EntryRecord]) throws -> [String] {
    try harnessToolResults(entries).map { result in
        result.content.map { if case .text(let text) = $0 { text.text } else { "" } }.joined()
    }
}

private func submit(_ root: Conversation, _ text: String) async throws {
    _ = try await root.submit(.input(content: .text(text)), context: .background).wait(context: .background)
}

/// Port of upstream `test/tool-search.test.ts`.
@Suite struct ToolSearchTests {
    @Test func offersADeferredToolOnlyOnceToolSearchLoadsItByAppendingItsDeclaration() async throws {
        let chat = try toolSearchSetup()
        chat.models.setResponses([
            .message(try nestedCall("tool_search", ["query": "github issue", "limit": 1])),
            .message(try nestedCall("github_get_issue", ["number": 42], id: "c2")),
            .message(nestedDone),
        ])
        let opened = try await openChat(setup: chat)
        let root = opened.root
        #expect(try await offered(root) == ["alpha", "omega", "tool_search"])
        #expect(try await deferred(root) == ["github_get_issue", "github_list_repos"])
        // Deferred tools stay callable by other tools, such as code mode scripts.
        #expect(try await root.agent(context: .background).callable.map(\.name).contains("github_get_issue"))
        try await submit(root, "go")
        let entries = try await allEntries(root)
        let texts = try toolResultTexts(entries)
        #expect(texts.count == 2)
        #expect(texts.first == "Loaded 1 tool. They are available from your next call:\n- github_get_issue: Get a GitHub issue by number")
        #expect(texts.last == "github_get_issue ran")
        #expect(try await modelTools(opened.harness, root) == .edit(add: ["github_get_issue"]))
        #expect(try await offered(root) == ["alpha", "omega", "tool_search", "github_get_issue"])
        // A later search sees only the tools not loaded yet.
        #expect(try await deferred(root) == ["github_list_repos"])
        // The load appended the declaration: no tool was removed and declared again, so the cached prefix holds.
        let systems = try systemMessages(entries)
        #expect(systems.count == 2)
        #expect(systems.first?.toolsAdded?.map(\.name) == ["alpha", "omega", "tool_search"])
        #expect(systems.last?.toolsAdded?.map(\.name) == ["github_get_issue"])
        #expect(systems.last?.toolsRemoved == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func appendsEachLoadedToolInLoadOrderNotRegistryOrder() async throws {
        let chat = try toolSearchSetup()
        chat.models.setResponses([
            .message(try nestedCall("tool_search", ["query": "repositories", "limit": 1])),
            .message(try nestedCall("tool_search", ["query": "issue", "limit": 1], id: "c2")),
            .message(nestedDone),
        ])
        let opened = try await openChat(setup: chat)
        try await submit(opened.root, "go")
        #expect(try await offered(opened.root) == ["alpha", "omega", "tool_search", "github_list_repos", "github_get_issue"])
        let loads = try systemMessages(try await allEntries(opened.root)).dropFirst()
        #expect(loads.map { $0.toolsAdded?.map(\.name) } == [["github_list_repos"], ["github_get_issue"]])
        #expect(loads.allSatisfy { $0.toolsRemoved == nil })
        try await opened.harness.close(context: .background)
    }

    @Test func recordsLoadsByNameUnknownAndNonDeferredNamesChangeNothingRemoveWinsAndALoadLiftsIt() async throws {
        let chat = try toolSearchSetup()
        let grow = try ToolRegistration(name: "grow", description: "grow", parameters: ["type": "object", "properties": [:]]) { _, _, _ in
            .init(output: [], control: .init(addTools: ["github_get_issue", "alpha", "ghost"]))
        }
        try installHarnessTool(grow, setup: chat)
        chat.models.setResponses([.message(try nestedCall("grow")), .message(nestedDone), .message(try nestedCall("grow")), .message(nestedDone)])
        let opened = try await openChat(setup: chat)
        let root = opened.root
        try await submit(root, "go")
        #expect(try await modelTools(opened.harness, root) == .edit(add: ["github_get_issue", "alpha", "ghost"]))
        #expect(try await offered(root) == ["alpha", "omega", "tool_search", "grow", "github_get_issue"])
        // A name in both remove and add is not offered.
        let getIssue = try #require(try await root.agent(context: .background).callable.first { $0.name == "github_get_issue" })
        try await root.configure(change: .init(modelTools: .set(.edit(remove: [getIssue], add: [getIssue]))), context: .background)
        #expect(try await !offered(root).contains("github_get_issue"))
        // Loading it again drops it from remove.
        try await submit(root, "again")
        #expect(try await modelTools(opened.harness, root) == .edit(add: ["github_get_issue", "alpha", "ghost"]))
        #expect(try await offered(root).contains("github_get_issue"))
        try await opened.harness.close(context: .background)
    }

    @Test func keepsALoadedToolWhenItsExtensionIsGoneForAWhileAndAppendsToAnExactList() async throws {
        let chat = try toolSearchSetup()
        let issue = try tool("github_get_issue", "Get a GitHub issue by number", deferred: true)
        chat.models.setResponses([.message(try nestedCall("tool_search", ["query": "github issue", "limit": 1])), .message(nestedDone)])
        let opened = try await openChat(setup: chat)
        let root = opened.root
        try await submit(root, "go")
        // The server goes away: its extension is installed again without the tool.
        try chat.registry.install(Extension(name: "tool:github_get_issue", tools: []))
        #expect(try await !offered(root).contains("github_get_issue"))
        try chat.registry.install(Extension(name: "tool:github_get_issue", tools: [issue]))
        #expect(try await offered(root).contains("github_get_issue"))
        // With an exact list, a load appends to it as before.
        let tools = try await root.agent(context: .background).tools
        let alpha = try #require(tools.first { $0.name == "alpha" })
        let search = try #require(tools.first { $0.name == "tool_search" })
        try await root.configure(change: .init(modelTools: .set(.exact([alpha, search]))), context: .background)
        chat.models.setResponses([.message(try nestedCall("tool_search", ["query": "repositories", "limit": 1])), .message(nestedDone)])
        try await submit(root, "more")
        #expect(try await modelTools(opened.harness, root) == .exact(["alpha", "tool_search", "github_list_repos"]))
        try await opened.harness.close(context: .background)
    }

    @Test func keepsLoadedToolsPerBranchAndInTheBaselineAfterAReset() async throws {
        let chat = try toolSearchSetup()
        chat.models.setResponses([.message(try nestedCall("tool_search", ["query": "github issue", "limit": 1])), .message(nestedDone)])
        let opened = try await openChat(setup: chat)
        let root = opened.root
        try await submit(root, "go")
        let entries = try await allEntries(root)
        let before = try await root.fork(at: try #require(entries.first).id, options: .init(ownership: .ownerless()), context: .background)
        let after = try await root.fork(at: try #require(entries.last).id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await !offered(before).contains("github_get_issue"))
        #expect(try await offered(after).contains("github_get_issue"))
        try await root.reset(context: .background)
        chat.models.setResponses([.message(nestedDone)])
        try await submit(root, "fresh")
        let baseline = try #require(try systemMessages(try await allEntries(root)).last)
        #expect(baseline.toolsAdded?.map(\.name) == ["alpha", "omega", "tool_search", "github_get_issue"])
        try await opened.harness.close(context: .background)
    }

    @Test func findsNothingForAnUnrelatedQueryAndLoadsNothing() async throws {
        let chat = try toolSearchSetup()
        chat.models.setResponses([.message(try nestedCall("tool_search", ["query": "weather forecast"])), .message(nestedDone)])
        let opened = try await openChat(setup: chat)
        try await submit(opened.root, "go")
        #expect(try toolResultTexts(try await allEntries(opened.root)) == ["No matching tools found."])
        #expect(try await modelTools(opened.harness, opened.root) == nil)
        try await opened.harness.close(context: .background)
    }

    // Swift-only: upstream tests the ranking only through code mode's `searchTools()` and `tool_search`.
    @Test func tokenizesAtCamelCaseAndAcronymBoundariesWithoutStopWordsAndStemsPlurals() {
        #expect(tokenize("getHTMLIssues for the repos2Users") == ["get", "html", "issue", "repos2", "user"])
        #expect(tokenize("searches boxes classes buzzes dishes stories gas") == ["search", "box", "class", "buzz", "dish", "story", "gas"])
        // Lowercased like JavaScript's toLowerCase, then split at anything outside a-z0-9: the Kelvin sign becomes `k`.
        #expect(tokenize("Ünïcode_names \u{212A}ey") == ["n", "code", "name", "key"])
    }

    @Test func ranksWithBM25BestFirstKeepingDocumentOrderForTiesAndHonoringTheLimit() {
        let documents = [SearchDocument(name: "a", text: "list repositories"), SearchDocument(name: "b", text: "get issue"),
                         SearchDocument(name: "c", text: "issue issue comment"), SearchDocument(name: "d", text: "get issue")]
        #expect(rankDocuments("issue", documents, limit: 8) == ["c", "b", "d"])
        #expect(rankDocuments("issue", documents, limit: 2) == ["c", "b"])
        #expect(rankDocuments("the", documents, limit: 8) == [])
        #expect(rankDocuments("issue", documents, limit: 0) == [])
    }
}
