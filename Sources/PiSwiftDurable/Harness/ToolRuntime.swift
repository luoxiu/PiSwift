import PiSwiftChord

extension ToolExecutionApi {
    internal func taskRuntime() throws -> TaskRuntime {
        guard let runtime else { throw TaskDefinitionError("Tool execution API has no task runtime") }
        try runtime.invocation.check()
        return runtime
    }
    /// Commits the supplied changes atomically and publishes them after storage succeeds.
    public func commit<T>(_ change: (Transaction) async throws -> T, context: ChordContext) async throws -> T {
        try await withTaskCancellationContext(context) { context in
            let runtime = try taskRuntime()
            return try await runtime.scheduler.gated(runtime.invocation, context: context) { tx, _ in
                return try await change(tx)
            }
        }
    }
    /// Create a task in one commit. A child task of a tool that is not replay-safe defaults to `abandonOnRestart`: the
    /// tool never resumes after a restart, so nothing awaits the child then.
    public func createTask<Input, Checkpoint>(_ task: TaskKind<Input, Checkpoint>, input: Input,
                                             options: TaskOptions, context: ChordContext) async throws -> TaskID {
        let child = childOptions(options)
        return try await commit({ tx in try await tx.createTask(task, input: input, options: child) }, context: context)
    }
    /// Create a task in one commit. A child task of a tool that is not replay-safe defaults to `abandonOnRestart`: the
    /// tool never resumes after a restart, so nothing awaits the child then.
    public func createTask<Input, Checkpoint, Result, Hooks>(
        _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input,
        options: TaskOptions, context: ChordContext
    ) async throws -> TaskID {
        let child = childOptions(options)
        return try await commit({ tx in try await tx.createTask(task, input: input, options: child) }, context: context)
    }
    private func childOptions(_ options: TaskOptions) -> TaskOptions {
        guard case .task = options.ownership, !resumes, options.abandonOnRestart == nil else { return options }
        return TaskOptions(ownership: options.ownership, conversationId: options.conversationId,
                           background: options.background, abandonOnRestart: true)
    }
    /// Run tool `name` as a nested call of this one and wait for its result. The nested call is its own `pi.tool` task,
    /// owned by this call: it resolves the tool among the conversation's callable tools, validates, runs the `ToolTask`
    /// hooks (which see `call.parent`), applies output limits and the tool's replay policy, and reports progress in
    /// `pi.live.nestedTools`. Its result returns here instead of entering the transcript. A call that is blocked,
    /// invalid, throws, is interrupted, or is aborted returns an `isError` result.
    ///
    /// The nested call's key names it within this call; its call ID is `<callId>/<key>`. By default the key is the call's
    /// position among this invocation's nested calls, `1`, `2`, ..., in the order the calls start running. Calls made
    /// concurrently, through `async let` or a task group, start in no fixed order, so a replay-safe caller that makes
    /// them concurrently passes explicit keys. An explicit `key` must be non-empty, without `/`,
    /// not `__proto__`, and not a positive integer, so it never collides with a default one. A rerun of a replay-safe
    /// tool that makes a call with a used key, by calling in the same order or by passing the same `key`, gets that nested
    /// call back, finished or still running, instead of starting another. A nested call a crash interrupted before its
    /// result committed follows its own replay policy, so this is not exactly-once execution. Reusing a key with another
    /// tool or other arguments throws. A tool that is not replay-safe never reruns: after a restart, its unfinished nested
    /// calls are abandoned (`TaskOptions.abandonOnRestart`) before they run again.
    ///
    /// `progress: false` commits no running output, details, or diagnostics to the nested call's slot, only its status;
    /// the result still carries its details and diagnostics, and a schema-less tool's output as `structuredOutput`. An
    /// interrupted or aborted call's result is built from its slot, so it then has none of them. Either way, programs
    /// never get the partial output of an interrupted or aborted call.
    ///
    /// Nested calls run as soon as they are made, whatever their `executionMode`; the caller decides what runs at once
    /// by what it awaits. Cancelling `context` stops only the wait; the nested call runs on. When this call settles,
    /// nested calls it left running are aborted first. A nested result's `usage` is already counted under its tool; a
    /// result that passes it on counts it again. Throws, instead of returning a result, once `execute()` has returned,
    /// when this call is aborted, or when the Harness closes.
    public func executeTool(_ name: String, arguments: JSONObject = [:], options: ExecuteToolOptions = .init(),
                            context: ChordContext) async throws -> NestedToolExecutionResult {
        try await withTaskCancellationContext(context) { context in
            try await nestedCall(name, arguments, options, context)
        }
    }
    /// Returns the current durable task record, or nil when it is absent.
    public func getTask(id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await taskRuntime().getTask(id, context: context)
    }
    /// Waits for a terminal task outcome and returns its durable receipt.
    public func waitForTask(id: TaskID, context: ChordContext) async throws -> SettledTask {
        try await taskRuntime().waitForTask(id, context: context)
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(id: ConversationID, context: ChordContext) async throws -> ConversationHandle? {
        try await taskRuntime().conversation(id, context: context)
    }
    /// Reads the visible model context through the optional inclusive entry boundary.
    public func context(at: EntryID? = nil, context: ChordContext) async throws -> ContextView {
        try await taskRuntime().context(conversationId, at: at, context: context)
    }
}
