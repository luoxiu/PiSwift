/// Where a reported failure came from (`HarnessOptions.onReport`):
/// - `session`: the error failed the Session, which closes (a Storage error, or the Session's own bookkeeping).
/// - `task`: a task's phase faulted, a task's runtime reported it, or a task cannot run; `taskId` names it.
/// - `extension`: extension code other than a task phase: a hook, a system prompt section, or a wrapper.
/// - `listener`: a commit, close, watch, view, or document listener.
/// - `host`: a host callback: the clock, the settings, the registry, or the environment builder.
/// - `timer`: `HarnessOptions.setTimer`.
/// - `wake`: `HarnessOptions.onWake`.
public enum ReportSource: String, Sendable, Equatable {
    /// The error failed the Session, which closes.
    case session
    /// A task's phase faulted, its runtime reported a failure, or it cannot run.
    case task
    /// Extension code other than a task phase: a hook, a system prompt section, or a wrapper.
    case `extension`
    /// A commit, close, watch, view, or document listener.
    case listener
    /// A host callback: the clock, the settings, the registry, or the environment builder.
    case host
    /// `HarnessOptions.setTimer`.
    case timer
    /// `HarnessOptions.onWake`.
    case wake
}

/// Whose code a task's `runtime.report()` is about: its own (default), an extension's, or the host's.
public enum ReportFrom: Sendable, Equatable {
    /// The task's own code.
    case task
    /// Extension code the task called, such as a section, with the extension's name when known.
    case `extension`(String?)
    /// A host callback, such as the environment builder.
    case host
}

/// What a report is about: its source and, when a task is involved, the task.
public struct ReportInfo: Sendable, Equatable {
    /// Where the failure came from.
    public let source: ReportSource
    /// The task involved, when one is.
    public let taskId: TaskID?
    /// The task's registered name.
    public let taskKind: String?
    /// The conversation of the task, or the one whose agent was resolved.
    public let conversationId: ConversationID?
    /// The extension whose code failed, when known: the one that installed a failing task's definition, or a hook's, a
    /// section's, a wrapper's, or a tool's. Built-in tasks have none.
    public let `extension`: String?
    /// Set (`true`) when the error ended its task `faulted`.
    public let faulted: Bool?
    /// Set (`.restartLimit`) when the report is about the task being parked by `settings.restartLimit`, or faulted at it.
    public let blocked: TaskBlockedReason?
    /// Describes where a report came from and the task it is about.
    public init(source: ReportSource, taskId: TaskID? = nil, taskKind: String? = nil,
                conversationId: ConversationID? = nil, extension: String? = nil, faulted: Bool? = nil,
                blocked: TaskBlockedReason? = nil) {
        self.source = source; self.taskId = taskId; self.taskKind = taskKind
        self.conversationId = conversationId; self.extension = `extension`; self.faulted = faulted; self.blocked = blocked
    }
    /// The default source of a report: a listener, which never fails what ran it.
    static let listener = ReportInfo(source: .listener)
}
