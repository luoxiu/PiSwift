/// The task a report is about.
public struct ReportTask: Sendable, Equatable {
    /// The task's ID.
    public let id: TaskID
    /// The task's registered name.
    public let kind: String
    /// The conversation the task runs in.
    public let conversationId: ConversationID
    /// Names the task a report is about.
    public init(id: TaskID, kind: String, conversationId: ConversationID) {
        self.id = id; self.kind = kind; self.conversationId = conversationId
    }
}

/// A host callback, by its `HarnessOptions` name; `env` is the environment builder, `models` a provider call.
public enum HostCallback: String, Sendable, Equatable {
    /// `HarnessOptions.now`.
    case now
    /// `HarnessOptions.settings`.
    case settings
    /// `HarnessOptions.registry`.
    case registry
    /// `HarnessOptions.env`, the environment builder.
    case env
    /// `HarnessOptions.models`, for provider calls such as cancelling a deferred response.
    case models
    /// `HarnessOptions.setTimer`.
    case setTimer
    /// `HarnessOptions.onWake`.
    case onWake
}

/// Why a task ended `faulted` (`ReportInfo.taskFaulted`).
public enum TaskFaultReason: String, Sendable, Equatable {
    /// Its phase threw.
    case threw
    /// Its abort handler was cut off `settings.restartLimit` times.
    case restartLimit = "restart_limit"
}

/// Why a running task keeps its old definition (`ReportInfo.taskOutdated`).
public enum TaskOutdatedReason: String, Sendable, Equatable {
    /// The definition was uninstalled.
    case missingTask = "missing_task"
    /// The definition was replaced by one that cannot take over the task's state.
    case incompatibleTask = "incompatible_task"
}

/// What a report to `HarnessOptions.onReport` is about. `extension`, where present, names the extension whose code
/// failed, when known; for a task's own code, the one that installed the definition the task ran.
/// - `sessionFailed`: the error failed the Session, which closes: a Storage error, often a platform reset.
/// - `taskFaulted`: the task ended `faulted`: its phase threw (`.threw`), or its abort handler was cut off
///   `settings.restartLimit` times (`.restartLimit`).
/// - `taskParked`: the restart limit parked the task until `Harness.retryTask()`.
/// - `migrationFailed`: the task's stored state could not be migrated; it is blocked until the registry changes.
/// - `taskOutdated`: a running task keeps running under its old definition, which was uninstalled (`.missingTask`) or
///   replaced by one that cannot take over its state (`.incompatibleTask`).
/// - `taskError`: the task's own `runtime.report()`, or a failure in running it.
/// - `extensionError`: a hook, a section, a wrapper, or a tool's invalid structured output; with the task that ran it,
///   or, outside a task, the conversation whose agent was resolved.
/// - `hostError`: a host callback threw; with the task that called it, if one did.
/// - `listenerError`: a commit, close, watch, view, or document listener threw.
public enum ReportInfo: Sendable, Equatable {
    /// The error failed the Session, which closes.
    case sessionFailed
    /// The task ended `faulted`.
    case taskFaulted(task: ReportTask, extension: String?, reason: TaskFaultReason)
    /// The restart limit parked the task.
    case taskParked(task: ReportTask, extension: String?)
    /// The task's stored state could not be migrated.
    case migrationFailed(task: ReportTask, extension: String?)
    /// A running task keeps running under its old definition.
    case taskOutdated(task: ReportTask, extension: String?, reason: TaskOutdatedReason)
    /// The task's own `runtime.report()`, or a failure in running it.
    case taskError(task: ReportTask, extension: String?)
    /// Extension code threw: a hook, a section, a wrapper, or a tool's invalid structured output.
    case extensionError(extension: String?, task: ReportTask?, conversationId: ConversationID?)
    /// A host callback threw.
    case hostError(callback: HostCallback, task: ReportTask?)
    /// A commit, close, watch, view, or document listener threw.
    case listenerError

    /// The report's type tag, as upstream's `type`.
    public var type: String {
        switch self {
        case .sessionFailed: "session_failed"
        case .taskFaulted: "task_faulted"
        case .taskParked: "task_parked"
        case .migrationFailed: "migration_failed"
        case .taskOutdated: "task_outdated"
        case .taskError: "task_error"
        case .extensionError: "extension_error"
        case .hostError: "host_error"
        case .listenerError: "listener_error"
        }
    }
    /// The default info of a report: a listener's, which never fails what ran it.
    static let listener = ReportInfo.listenerError
}

/// Whose code a task's `runtime.report()` is about when not the task's own: an extension's, or a host callback.
public enum ReportFrom: Sendable, Equatable {
    /// Extension code the task called, such as a section, with the extension's name when known.
    case `extension`(String?)
    /// A host callback, such as the environment builder.
    case host(HostCallback)
}
