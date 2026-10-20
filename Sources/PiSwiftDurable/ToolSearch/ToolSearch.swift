// The `tool_search` tool, a copy of the coding agent's: the model searches the deferred tools it is not offered yet,
// and the matches are loaded with `control.addTools`, so the next request offers them. Loading writes the
// conversation's `modelTools` (its `add`), so loaded tools stay offered on that branch, also after a compaction.

import Foundation
import PiSwiftAI
import PiSwiftChord

/// The name of the tool search tool.
public let TOOL_SEARCH_TOOL_NAME = "tool_search"
/// How many tools a search loads when the call does not say.
public let DEFAULT_TOOL_SEARCH_LIMIT = 8

/// Fixed, so it does not change while deferred tools are registered, for example as MCP servers connect.
private let toolSearchDescription = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`\(TOOL_SEARCH_TOOL_NAME)`) to search for the required tools. For MCP tool discovery, always use `\(TOOL_SEARCH_TOOL_NAME)`."

private let toolSearchSchema: JSONObject = ["type": "object", "properties": [
    "query": ["type": "string", "description": "Search query for deferred tools."],
    "limit": ["type": "number", "description": .string("Maximum number of tools to return. Defaults to \(DEFAULT_TOOL_SEARCH_LIMIT).")],
], "required": ["query"]]

private struct ToolSearchInput: Decodable, Sendable {
    var query: String
    var limit: Double?
}

/// `tool_search` result details: the tools it loaded.
public struct ToolSearchToolDetails: Sendable, Equatable, Codable {
    /// The names of the tools the search loaded, best match first.
    public var loaded: [String]
    /// Lists the loaded tools.
    public init(loaded: [String]) { self.loaded = loaded }
}

/// Schema descriptions and property names, recursively.
private func schemaText(_ schema: JSONValue?, _ parts: inout [String]) {
    guard case .object(let schema)? = schema else { return }
    if case .string(let description)? = schema["description"] { parts.append(description) }
    if case .object(let properties)? = schema["properties"] {
        for (name, property) in properties {
            parts.append(name)
            schemaText(property, &parts)
        }
    }
    schemaText(schema["items"], &parts)
    for key in ["anyOf", "oneOf", "allOf"] {
        if case .array(let variants)? = schema[key] { for variant in variants { schemaText(variant, &parts) } }
    }
}

/// Search text of a tool: its name, the name with `_` as spaces, its description, and its parameters' text.
private func searchText(_ tool: ToolRegistration) throws -> String {
    var parts = [tool.name, tool.name.replacingOccurrences(of: "_", with: " "), tool.description]
    schemaText(try tool.currentOrderedDeclaration()["parameters"], &parts)
    return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
}

/// The first line of a trimmed description, as upstream's `split(/\r?\n/)[0]`.
private func firstLine(_ text: String) -> String {
    let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
    var line = String.UnicodeScalarView(scalars.prefix { $0 != "\n" })
    if line.last == "\r" { line.removeLast() }
    return String(line)
}

/// Creates the `tool_search` tool, which ranks `Agent.deferred` with BM25 and loads the matches.
public func createToolSearchTool() throws -> ToolRegistration {
    try defineTool(name: TOOL_SEARCH_TOOL_NAME, description: toolSearchDescription, parameters: toolSearchSchema,
        args: ToolSearchInput.self, replay: .safe,
        // Searching changes what the model is offered; scripts have their own `searchTools()`.
        callers: [.model]) { args, api, context in
            if args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DurableToolError(message: "query must not be empty")
            }
            let max = args.limit ?? Double(DEFAULT_TOOL_SEARCH_LIMIT)
            guard max.isFinite, max.rounded(.towardZero) == max, max > 0 else {
                throw DurableToolError(message: "limit must be a positive integer")
            }
            let candidates = try await api.agent(context).deferred
            let documents = try candidates.map { SearchDocument(name: $0.name, text: try searchText($0)) }
            let loaded = rankDocuments(args.query, documents, limit: Int(exactly: max) ?? Int.max)
            let text = loaded.isEmpty
                ? "No matching tools found."
                : "Loaded \(loaded.count) tool\(loaded.count == 1 ? "" : "s"). They are available from your next call:\n" + loaded.map { name in
                    let description = candidates.first { harnessNamesEqual($0.name, name) }?.description ?? ""
                    return "- \(name): \(firstLine(description))"
                }.joined(separator: "\n")
            return ToolExecutionResult(output: [.text(TextContent(text: text))],
                                       details: try JSONValue(encoding: ToolSearchToolDetails(loaded: loaded)),
                                       control: loaded.isEmpty ? nil : ToolControl(addTools: loaded))
        }
}

/// The `tool_search` extension: install it and select it where the model should find deferred tools.
public func createToolSearchExtension() throws -> Extension {
    Extension(name: "tool-search", tools: [try createToolSearchTool()])
}
