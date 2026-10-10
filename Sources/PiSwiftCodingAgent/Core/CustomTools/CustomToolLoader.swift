import Foundation
import PiSwiftAI

private final class CustomToolPluginStore: Sendable {
    static let shared = CustomToolPluginStore()
    private let state = LockedState<[any CustomToolPlugin]>([])

    func add(_ plugin: any CustomToolPlugin) {
        state.withLock { plugins in
            plugins.append(plugin)
        }
    }
}

private func resolveToolPath(_ toolPath: String, cwd: String) -> String {
    resolveToCwd(toolPath, cwd: cwd)
}

private func discoverToolsInDir(_ dir: String) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return []
    }

    var tools: [String] = []
    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") { continue }
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDir = values?.isDirectory ?? false

        if isDir, name.hasSuffix(".bundle") {
            tools.append(entry.path)
            continue
        }

        let ext = entry.pathExtension.lowercased()
        if ext == "dylib" || ext == "so" {
            tools.append(entry.path)
        }
    }

    return tools.sorted()
}

private func loadCustomTool(
    _ toolPath: String,
    cwd: String,
    sharedApi: CustomToolAPI
) -> (tools: [LoadedCustomTool]?, error: String?) {
    let resolvedPath = resolveToolPath(toolPath, cwd: cwd)
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        return (nil, "Custom tool not found")
    }

    let resolvedUrl = URL(fileURLWithPath: resolvedPath)
    if resolvedUrl.pathExtension.lowercased() == "bundle" {
        guard let bundle = Bundle(path: resolvedPath) else {
            return (nil, "Failed to load bundle")
        }
        guard bundle.load() else {
            return (nil, "Failed to load bundle")
        }
        guard let principal = bundle.principalClass as? CustomToolPlugin.Type else {
            return (nil, "Bundle principal class must conform to CustomToolPlugin")
        }

        let toolCount = sharedApi.toolsSnapshot().count
        let plugin = principal.init()
        plugin.register(sharedApi)
        CustomToolPluginStore.shared.add(plugin)

        let tools = sharedApi.toolsSnapshot().dropFirst(toolCount).map { tool in
            LoadedCustomTool(path: toolPath, resolvedPath: resolvedPath, tool: tool)
        }
        return (tools, nil)
    }

    return (nil, "Unsupported custom tool format. Use a .bundle with a CustomToolPlugin principal class")
}

public func loadCustomTools(
    _ paths: [String],
    _ cwd: String,
    _ builtInToolNames: [String],
    _ eventBus: EventBus? = nil
) -> CustomToolsLoadResult {
    var tools: [LoadedCustomTool] = []
    var errors: [CustomToolLoadError] = []
    var seenNames = Set<String>()
    _ = builtInToolNames

    let resolvedEventBus = eventBus ?? createEventBus()
    let sharedApi = CustomToolAPI(cwd: cwd, events: resolvedEventBus)

    for toolPath in paths {
        let result = loadCustomTool(toolPath, cwd: cwd, sharedApi: sharedApi)
        if let error = result.error {
            errors.append(CustomToolLoadError(path: toolPath, error: error))
            continue
        }
        guard let loadedTools = result.tools else { continue }

        for loaded in loadedTools {
            if seenNames.contains(loaded.tool.name) {
                errors.append(CustomToolLoadError(
                    path: toolPath,
                    error: "Tool name \"\(loaded.tool.name)\" conflicts with existing tool"
                ))
                continue
            }
            seenNames.insert(loaded.tool.name)
            tools.append(loaded)
        }
    }

    return CustomToolsLoadResult(
        tools: tools,
        errors: errors,
        setUIContext: { uiContext, hasUI in
            sharedApi.ui = uiContext
            sharedApi.hasUI = hasUI
        },
        setSendMessageHandler: { handler in
            sharedApi.setSendMessageHandler(handler)
        }
    )
}

public func discoverAndLoadCustomTools(
    _ configuredPaths: [String],
    _ cwd: String,
    _ builtInToolNames: [String],
    _ agentDir: String = getAgentDir(),
    _ eventBus: EventBus? = nil
) -> CustomToolsLoadResult {
    var allPaths: [String] = []
    var seen: Set<String> = []

    func addPaths(_ paths: [String]) {
        for path in paths {
            let resolved = resolveToolPath(path, cwd: cwd)
            if !seen.contains(resolved) {
                seen.insert(resolved)
                allPaths.append(path)
            }
        }
    }

    let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("tools").path
    addPaths(discoverToolsInDir(globalDir))

    let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("tools").path
    addPaths(discoverToolsInDir(localDir))

    addPaths(configuredPaths.map { resolveToolPath($0, cwd: cwd) })

    return loadCustomTools(allPaths, cwd, builtInToolNames, eventBus)
}
