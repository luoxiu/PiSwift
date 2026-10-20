// Ports upstream `packages/durable/src/harness/telemetry.ts` at 2ec55d808.

import PiSwiftTelemetry

private let entry = TelemetryEventDefinition(
    description: "A transcript entry was committed; content remains in the transcript.",
    attributes: [
        "entry.id": .init(.number(), description: "Transcript entry ID.", required: true, cardinality: .high),
        "entry.kind": .init(.string(), description: "Entry kind.", required: true),
    ])
private let reportTypes = ["session_failed", "task_faulted", "task_parked", "migration_failed", "task_outdated", "task_error",
                           "extension_error", "host_error", "listener_error"]
private let reportAttributes: [String: TelemetryEventAttributeDefinition] = [
    "type": .init(.string(values: reportTypes), description: "ReportInfo type.", required: true),
    "reason": .init(.string(values: ["threw", "restart_limit", "missing_task", "incompatible_task"]),
                    description: "Fixed report reason, when present.", required: false),
    "extension": .init(.string(), description: "Registered extension name, when present.", required: false),
    "task.id": .init(.number(), description: "Task ID, when present.", required: false, cardinality: .high),
]
private let report = TelemetryEventDefinition(description: "A report was raised; no error payload is recorded.",
                                              attributes: reportAttributes)
private let submission = TelemetryEventDefinition(
    description: "A submission was settled.",
    attributes: [
        "submission.id": .init(.number(), description: "Submission ID.", required: true, cardinality: .high),
        "status": .init(.string(values: ["done", "unanswered"]), description: "Settlement.", required: true),
        "answer.entry_id": .init(.number(), description: "Answer entry ID.", required: false, cardinality: .high),
    ])
private func metricAttribute(_ description: String) -> TelemetryMetricAttributeDefinition {
    TelemetryMetricAttributeDefinition(.string(), description: description, required: true)
}

/// Durable's content-free span, event, and metric vocabulary (upstream `DURABLE_TELEMETRY_SCHEMA`). IDs address durable
/// records, never content.
public let durableTelemetrySchema = defineTelemetrySchema(TelemetrySchemaDefinition(
    version: 1,
    spans: [
        "pi.durable.submit": TelemetrySpanDefinition(
            description: "Public submission admission and its commit. Inputs start root traces linked to their callers; "
                + "writes are children. Internal admissions emit phase events only.",
            parents: .any,
            startAttributes: [
                "submission.type": .init(.string(values: ["input", "write"]), description: "Submission type.", required: true),
                "conversation.id": .init(.number(), description: "Conversation ID.", required: true, cardinality: .high),
            ],
            endAttributes: [
                "submission.id": .init(.number(), description: "Admitted submission ID.", cardinality: .high),
                "result": .init(.string(values: ["queued", "placed", "done"]),
                                description: "Admission result; stale writes report done."),
            ],
            events: ["pi.durable.entry": entry, "pi.durable.submission": submission, "pi.durable.report": report],
            status: TelemetryStatusDefinition(errorWhen: "Admission failed.")
        ),
        "pi.durable.phase": TelemetrySpanDefinition(
            description: "One task phase invocation, including its decision commit, never a wait or restart.",
            parents: .any,
            startAttributes: [
                "task.id": .init(.number(), description: "Task ID.", required: true, cardinality: .high),
                "task.name": .init(.string(), description: "Registered task name.", required: true),
                "phase": .init(.string(), description: "Invoked checkpoint phase.", required: true),
                "kind": .init(.string(values: ["run", "abort"]), description: "Invocation kind.", required: true),
                "attempt": .init(.number(), description: "Checkpoint attempt, when present.", required: false),
                "resumed": .init(.boolean(), description: "First invocation of a task loaded in this process.", required: true),
            ],
            endAttributes: [
                "outcome": .init(.string(), description: "next=<phase>, waiting, sleeping, done, faulted, or aborted."),
                "tool.name": .init(.string(), description: "Called tool name."),
                "tool.call_id": .init(.string(), description: "Transcript tool call ID.", cardinality: .high),
            ],
            events: [
                "pi.durable.entry": entry,
                "pi.durable.submission": submission,
                "pi.durable.report": report,
                "pi.durable.checkpoint": TelemetryEventDefinition(
                    description: "The running checkpoint's phase changed while the invocation continued.",
                    attributes: ["phase": .init(.string(), description: "Committed checkpoint phase.", required: true)]),
                "pi.durable.replay": TelemetryEventDefinition(
                    description: "A nested tool call was answered from its stored result.",
                    attributes: ["tool.name": .init(.string(), description: "Called tool name.", required: true)]),
            ],
            status: TelemetryStatusDefinition(
                errorWhen: "Faulted, failed, and orphaned outcomes use task_faulted, task_failed, and task_orphaned with a "
                    + "diagnostic capped at 500 characters. Aborted outcomes keep status ok.")
        ),
    ],
    metrics: [
        "pi.durable.reports": .counter(description: "Reports raised, grouped by their fixed ReportInfo type.", attributes: [
            "type": .init(.string(values: reportTypes), description: "ReportInfo type.", required: true),
        ]),
        "pi.durable.phase.duration": .histogram(description: "Duration of a phase invocation and its decision commit.",
                                                unit: "ms", attributes: [
            "task": metricAttribute("Registered task name."),
            "phase": metricAttribute("Invoked checkpoint phase."),
            "outcome": metricAttribute("Phase outcome."),
        ]),
        "pi.durable.tasks.active": .upDownCounter(
            description: "Live tasks held by this Harness; decremented at terminal settlement or close.",
            attributes: ["task": metricAttribute("Registered task name.")]),
    ]
))

/// The attributes of a `pi.durable.report` event: the type, the fixed reason, the extension, and the task ID, never the
/// error.
internal func reportEventAttributes(_ info: ReportInfo) -> SpanAttributes {
    var attributes: SpanAttributes = ["type": .string(info.type)]
    switch info {
    case .taskFaulted(let task, let `extension`, let reason):
        attributes["reason"] = .string(reason.rawValue)
        attributes["extension"] = `extension`.map(AttributeValue.string)
        attributes["task.id"] = .number(Double(task.id.rawValue))
    case .taskOutdated(let task, let `extension`, let reason):
        attributes["reason"] = .string(reason.rawValue)
        attributes["extension"] = `extension`.map(AttributeValue.string)
        attributes["task.id"] = .number(Double(task.id.rawValue))
    case .taskParked(let task, let `extension`), .migrationFailed(let task, let `extension`), .taskError(let task, let `extension`):
        attributes["extension"] = `extension`.map(AttributeValue.string)
        attributes["task.id"] = .number(Double(task.id.rawValue))
    case .extensionError(let `extension`, let task, _):
        attributes["extension"] = `extension`.map(AttributeValue.string)
        attributes["task.id"] = task.map { .number(Double($0.id.rawValue)) }
    case .hostError(_, let task):
        attributes["task.id"] = task.map { .number(Double($0.id.rawValue)) }
    case .sessionFailed, .listenerError:
        break
    }
    return attributes
}

/// The first `limit` UTF-16 code units, as JavaScript's `slice(0, limit)`. A Swift string cannot hold half a surrogate
/// pair, so a pair cut in half drops its first half.
internal func telemetryPrefix(_ text: String, _ limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    var prefix = Array(text.utf16.prefix(limit))
    if let last = prefix.last, UTF16.isLeadSurrogate(last) { prefix.removeLast() }
    return String(decoding: prefix, as: UTF16.self)
}
