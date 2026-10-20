/// The `coding-tools` extension: read, write, edit, and bash. A host must install it explicitly. `options.images`
/// prepares the images `read` returns (see `ReadToolOptions`).
/// On iOS, use the read, write, and edit factories if the host has no remote shell.
/// Local bash calls on iOS produce a normal harness error result with shellUnavailable.
public func createCodingTools(options: ReadToolOptions = .init()) throws -> Extension {
    try defineExtension(Extension(name: "coding-tools", tools: [
        createReadTool(options: options), createWriteTool(), createEditTool(), createBashTool()
    ]))
}

/// `createCodingTools()` without an image processor.
public var CodingTools: Extension {
    get throws { try createCodingTools() }
}
