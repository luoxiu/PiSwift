import Foundation

public struct CodemodeExtensionOptions: Sendable {
    public var mode: CodemodeMode?
    public var inlineBudget: Double?
    public var models: Bool
    public var collisionPolicy: ToolNameCollisionPolicy?
    public var defaultTimeoutMs: Int?
    public var maxTimeoutMs: Int?
    public var validationErrorPrefix: String?

    public init(mode: CodemodeMode? = nil, inlineBudget: Double? = nil, models: Bool = true,
                collisionPolicy: ToolNameCollisionPolicy? = nil,
                defaultTimeoutMs: Int? = nil, maxTimeoutMs: Int? = nil,
                validationErrorPrefix: String? = nil) {
        self.mode = mode
        self.inlineBudget = inlineBudget
        self.models = models
        self.collisionPolicy = collisionPolicy
        self.defaultTimeoutMs = defaultTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.validationErrorPrefix = validationErrorPrefix
    }
}

/// The built-in registers codemode inactive. A host can activate it with +codemode or --tools.
public func createCodemodeExtension(options: CodemodeExtensionOptions = .init()) -> InlineExtension {
    InlineExtension(name: "codemode", builtin: true, replaceable: true) { api in
        let toolOptions = CodemodeToolOptions(
            models: options.models,
            getToolNamespace: { name in api.getAllTools().first { $0.name == name }?.namespace },
            appendEntry: { type, data in
                api.appendEntry(type, ["set": data.set.mapValues(\.value), "delete": data.delete])
            },
            getMode: { options.mode ?? api.getSettings().codemode?.mode ?? .on },
            getInlineBudget: {
                let value = options.inlineBudget ?? api.getSettings().codemode?.inlineBudget
                return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            },
            getToolGuidelines: {
                // Upstream builds a Map, so a later entry with the same name wins.
                Dictionary(api.getAllTools().map { ($0.name, $0.promptGuidelines ?? []) },
                           uniquingKeysWith: { _, last in last })
            },
            collisionPolicy: options.collisionPolicy ?? api.toolNameCollisionPolicy,
            defaultTimeoutMs: options.defaultTimeoutMs,
            maxTimeoutMs: options.maxTimeoutMs,
            validationErrorPrefix: options.validationErrorPrefix,
            getDefaultTimeoutMs: { api.getSettings().codemode?.defaultTimeoutMs },
            getMaxTimeoutMs: { api.getSettings().codemode?.maxTimeoutMs },
            recordLateCall: { parentId, call in
                var row: [String: Any] = ["id": call.id, "name": call.name,
                                          "args": call.args, "status": call.status.rawValue]
                if let error = call.error {
                    row["error"] = error
                }
                if let duration = call.durationMs {
                    row["durationMs"] = duration
                }
                api.appendEntry(CODEMODE_LATE_CALL_ENTRY_TYPE,
                                ["parentToolCallId": parentId, "call": row])
            })
        _ = api.registerTool(createCodemodeToolDefinition(options: toolOptions))
    }
}
