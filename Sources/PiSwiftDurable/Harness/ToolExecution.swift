import Foundation
import PiSwiftAI
import PiSwiftChord
import Synchronization

/// Nested call admissions one invocation started, and its default key sequence. Cleanup waits for the admissions, so it
/// sees every nested call.
private final class NestedAdmissions: Sendable {
    private struct State: Sendable {
        var sequence = 0
        var pending: [HarnessPromise<Void>] = []
        var madeNestedMemo: HarnessPromise<Void>?
    }
    private let state = Mutex(State())
    /// Default keys: the order of this invocation's calls, so a rerun that calls in the same order reattaches.
    func nextKey() -> String { state.withLock { state in state.sequence += 1; return String(state.sequence) } }
    /// This attempt's commit of the `madeNestedCallsMemo` memo: once, by the first call; a failed one is tried again by
    /// the next call.
    func madeNestedMemo(_ commit: () async throws -> Void) async throws {
        let (memo, first) = state.withLock { state -> (HarnessPromise<Void>, Bool) in
            if let memo = state.madeNestedMemo { return (memo, false) }
            let memo = HarnessPromise<Void>()
            state.madeNestedMemo = memo
            return (memo, true)
        }
        guard first else { return try await memo.value() }
        do {
            try await commit()
            memo.finish(.success(()))
        } catch {
            state.withLock { $0.madeNestedMemo = nil }
            memo.finish(.failure(error))
            throw error
        }
    }
    func admit<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        let done = HarnessPromise<Void>()
        state.withLock { $0.pending.append(done) }
        defer { done.finish(.success(())) }
        return try await work()
    }
    func settled() async { for admission in state.withLock({ $0.pending }) { try? await admission.value() } }
}

/// Execute with the resolved implementation, then settle its result.
internal func runTool(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall, _ tool: ToolRegistration,
                      _ args: JSONObject, _ context: ChordContext) async throws {
    let limits = OutputLimits(maxBytes: tool.outputLimits?.maxBytes ?? defaultMaxBytes,
                              maxLines: tool.outputLimits?.maxLines ?? defaultMaxLines,
                              retain: tool.outputLimits?.retain ?? .head)
    let lifetime = ToolInvocationLifetime(callId: call.id)
    let publishes: Bool = if case .nested(let nested) = input { nested.progress != false } else { true }
    let reporter = ToolReporter(runtime: runtime, lifetime: lifetime, limits: limits, publishes: publishes, context: context)
    let admissions = NestedAdmissions()
    // A caller that can rerun reattaches to its nested calls and child tasks after a restart; any other caller never
    // resumes, so they are abandoned (`TaskOptions.abandonOnRestart`).
    let resumes = tool.replay == .safe
    var result: ToolExecutionResult
    var ending = ToolEnding.completed
    var durationMs: Int?
    do {
        let env = try await runtime.env(context: context)
        var api = ToolExecutionApi(taskId: runtime.taskId, conversationId: runtime.conversationId, callId: call.id,
            registry: runtime.registry, models: { runtime.models }, env: env, read: runtime.hookApi.read,
            outputWindow: limits.retain == .tail ? ShellOutputWindow(maxBytes: limits.maxBytes, maxLines: limits.maxLines,
                minIntervalMs: runtime.settings.progress.outputIntervalMs, bytesPerSecond: progressBytesPerSecond) : nil,
            runtime: runtime, lifetime: lifetime, agent: { try await runtime.agent(context: $0) },
            output: { try reporter.output($0, skipped: $1) }, diagnostic: { try reporter.diagnostic($0) },
            details: { try await reporter.details($0, context: $1) },
            memo: { try await runtime.memo($0, value: $1, context: $2) },
            retainedOutput: {
                let retained = reporter.snapshot().output
                return RetainedToolOutput(text: retained.text, truncated: retained.droppedBytes > 0)
            },
            nestedCall: { name, arguments, options, callContext in
                let key = options.key ?? admissions.nextKey()
                if let explicit = options.key { try checkNestedKey(explicit) }
                // Registered now, so cleanup waits for it.
                let id = try await admissions.admit {
                    // The memo first, once per attempt.
                    try await admissions.madeNestedMemo {
                        _ = try await runtime.memo(madeNestedCallsMemo, value: .bool(true), context: callContext)
                    }
                    return try await startNestedCall(runtime, parentCallId: call.id, name: name, arguments: arguments,
                                                     key: key, progress: options.progress, abandonOnRestart: !resumes,
                                                     context: callContext)
                }
                let settled = try await runtime.waitForTask(id, context: callContext)
                let stored = try await runtime.snapshot(NestedCallDoc, taskId: runtime.taskId, key: key, context: callContext)
                // A nested call the scheduler faulted or orphaned stored none.
                return stored?.result ?? fallbackNestedResult(id, name: name, outcome: settled.outcome)
            },
            resumes: resumes)
        api.pendingDetailsCount = { reporter.pendingDetailsCount }
        let now = runtime.scheduler.toolServices.executionTime()
        let started = now()
        do { result = try await tool.execute(.object(args), api, context) }
        catch {
            durationMs = toolDurationMs(now() - started)
            throw error
        }
        durationMs = toolDurationMs(now() - started)
    } catch {
        if runtime.signal.aborted || context.abortSignal?.aborted == true {
            let pending = await reporter.stop()
            for waiter in pending { waiter.reject(error) }
            throw error
        }
        result = ToolExecutionResult(isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: toolErrorText(error), code: "tool_error")])
        // A throw, from `execute()` or from building the environment, ends the task `failed`, which cancels what the
        // call owned; it no longer supervises it. The error text is already in the result.
        ending = .failed("Tool \(call.name) threw")
    }
    lifetime.end()
    // No admission starts after the lifetime ends; let those underway commit, so settlement aborts and lists their calls.
    await admissions.settled()
    // Details still waiting for a progress commit settle with the terminal commit, the final flush.
    let pending = await reporter.stop()
    do {
        let final = try await finalToolResult(runtime, input, call, tool, result, reporter, context)
        try await settleTool(runtime, input, call, ending, durationMs: durationMs, context: context) { _ in final }
        for waiter in pending { waiter.resolve() }
    } catch {
        for waiter in pending { waiter.reject(error) }
        throw error
    }
}
private func toolDurationMs(_ duration: Duration) -> Int {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return max(0, Int(value.rounded()))
}
/// The settled result: the tool's result with the retained output and last details as fallbacks, its diagnostics after
/// those reported through the api, `afterTool` applied, explicit text bounded, and `structuredOutput` checked against the
/// tool's schema, with the Harness's diagnostics last. A nested call whose `structuredOutput` breaks the contract gets an
/// error result without it; a model-issued call only loses it, and the break is reported to the host.
private func finalToolResult(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                             _ tool: ToolRegistration, _ result: ToolExecutionResult,
                             _ reporter: ToolReporter, _ context: ChordContext) async throws -> ToolExecutionResult {
    let reported = reporter.snapshot()
    let retained = result.output == nil ? reported.output : nil
    var final = result
    if let retained { final.output = retained.text.isEmpty ? [] : [.text(TextContent(text: retained.text))] }
    if final.details == nil { final.details = reported.details }
    final.diagnostics = reported.diagnostics + (result.diagnostics ?? [])
    let retainedIdentity = final.outputIdentity
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        if let replacement = try await hooks.afterTool?(call, final, runtime.hookApi, context) {
            final = replacement
        }
    }
    var harness: [ToolDiagnostic] = []
    // The retained output's truncation applies only while afterTool kept that output.
    if final.outputIdentity == retainedIdentity, let retained, retained.droppedBytes > 0 {
        harness.append(toolTruncated(retained.droppedBytes, retained.droppedLines, retain: reporter.limits.retain))
    }
    let bounded = boundToolContent(final.output ?? [], limits: reporter.limits)
    if bounded.droppedBytes > 0 { harness.append(toolTruncated(bounded.droppedBytes, bounded.droppedLines, retain: reporter.limits.retain)) }
    let nested: Bool = if case .nested = input { true } else { false }
    if let broken = try structuredOutputError(tool, final) {
        final.structuredOutput = nil
        if nested {
            final.isError = true
            harness.append(ToolDiagnostic(severity: .error, message: broken, code: "invalid_structured_output"))
        } else {
            // The model never sees structured output, so its call stands; the host learns of the broken tool.
            try runtime.report(ToolStructuredOutputError(message: broken))
        }
    }
    // Programs get the tool's own value: without a schema, its output. The model reads only `output`, so model-issued
    // calls skip both.
    if nested && tool.structuredOutputSchema == nil { final.structuredOutput = try nestedOutputValue(bounded.content) }
    // A schema tool's error result without structured output has its text only in the output, which programs never
    // get: it becomes an error diagnostic, as a thrown error's message does, unless one says what went wrong already.
    if nested, tool.structuredOutputSchema != nil, final.isError == true, final.structuredOutput == nil,
       !((final.diagnostics ?? []) + harness).contains(where: { $0.severity == .error }) {
        let text = bounded.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
        if !text.isEmpty { harness.append(ToolDiagnostic(severity: .error, message: text, code: "tool_error")) }
    }
    final.output = bounded.content; final.diagnostics = (final.diagnostics ?? []) + harness
    return final
}
/// A tool's `structuredOutput` broke its contract; reported for a model-issued call.
public struct ToolStructuredOutputError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Text that describes the error.
    public let message: String
    /// Stores the error text.
    public init(message: String) { self.message = message }
    /// Text that describes this value or error to the caller.
    public var description: String { message }
}
/// Why a result's `structuredOutput` breaks the tool's contract, or nil when it keeps it.
private func structuredOutputError(_ tool: ToolRegistration, _ result: ToolExecutionResult) throws -> String? {
    guard let schema = tool.structuredOutputSchema else {
        return result.structuredOutput == nil ? nil : "Tool \(tool.name) returned structuredOutput but declares no structuredOutputSchema"
    }
    guard let value = result.structuredOutput else {
        return result.isError == true ? nil : "Tool \(tool.name) returned no structuredOutput"
    }
    let foundationSchema = try foundationJSON(from: .object(schema)) as! [String: Any]
    let validation = JSONSchemaValidator.shared.validate(try foundationJSON(from: value), against: foundationSchema,
                                                         coerceTypes: false)
    if validation.isValid { return nil }
    let first = validation.errors.first
    let path = first.map { $0.path.hasPrefix("root.") ? String($0.path.dropFirst(5)) : $0.path } ?? "root"
    return "Tool \(tool.name) returned structuredOutput that does not match its schema: \(path.isEmpty ? "root" : path): \(first?.message ?? "invalid")"
}
internal func boundToolContent(_ content: [ContentBlock], limits: OutputLimits) -> (content: [ContentBlock], droppedBytes: Int, droppedLines: Int) {
    let indices = content.indices.filter { if case .text = content[$0] { return true }; return false }
    let bounded = boundOutput(indices.map { if case .text(let text) = content[$0] { return text.text }; return "" }.joined(), limits: limits)
    guard bounded.droppedBytes > 0 else { return (content, 0, 0) }
    let keep = limits.retain == .head ? indices.first : indices.last
    var result: [ContentBlock] = []
    for index in content.indices {
        if case .text(var text) = content[index] {
            if index == keep { text.text = bounded.text; result.append(.text(text)) }
        } else { result.append(content[index]) }
    }
    return (result, bounded.droppedBytes, bounded.droppedLines)
}
