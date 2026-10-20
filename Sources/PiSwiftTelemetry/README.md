# PiSwiftTelemetry

> **Experimental.** The API can change without notice between releases.

PiSwiftTelemetry ports `@earendil-works/pi-telemetry`
([`packages/telemetry`](https://github.com/earendil-works/pi/tree/482c1381a/packages/telemetry))
at upstream `482c1381a`, the parent of `48909d987`. Upstream's sources, tests, and README there are
unchanged since `35f5c265d` (v0.84.0). Later upstream commits that `FLEET_FORK.md` lists as ported
come on top. It has no dependencies. The package requires macOS 15 or iOS 18.

It provides:

- the callback-based `TelemetryContext` and `TelemetrySpan` contract;
- the shared `noopTelemetryContext`;
- the reference `InMemoryTelemetryContext`;
- serializable schema definitions and a typed span starter;
- adapter conformance cases in `PiSwiftTelemetryTesting`, upstream's `/testing` subpath.

It has no exporter, no ambient current span, and no backend. A host plugs in OpenTelemetry, OSLog
signposts, Sentry, or another backend with an adapter: a class that implements `TelemetryContext`
for the root, and one that implements `TelemetrySpan` for each span. Code passes the parent context
explicitly.

## Concepts

- **Span**: a timed record of one operation. It starts before the work and ends when the work ends.
- **Parent and child spans**: a span started from another span is its child. Together they form a tree.
- **Attribute**: a named fact on a span, such as `provider: "openai"` or `item_count: 12`.
- **Event**: a named occurrence during a span, with its own attributes and no duration.
- **Status**: the outcome, `ok` or `error`. An error can carry a name and a message.
- **Context**: where new work belongs in the tree. A span is the context of its children.

A span is diagnostic data, not business state. Recording it must not change whether the work runs,
succeeds, fails, or is persisted.

## Core Context API

`startSpan` runs a callback in a new child span. The callback gets the span, which is also the
parent context of its children. `ReadmeExamplesTests` runs the code blocks; the marker names in
that file identify each block.

```swift
func loadAccount(_ accountId: String, telemetry: any TelemetryContext = noopTelemetryContext) async throws -> Account? {
    try await telemetry.startSpan(SpanOptions(
        name: "example.account.load", attributes: ["example.account.id": .string(accountId)]
    )) { span in
        let account = try await readAccount(accountId)
        span.setAttributes(["example.account.found": .boolean(account != nil)])
        return account
    }
}
```

There is no `end()`. `startSpan` keeps the span open until the callback returns or throws.
A thrown error sets the `error` status. For an expected failure that the callback returns as a
value, set the status:

```swift
let result = try await telemetry.startSpan(SpanOptions(name: "example.save")) { span in
    let result = try await save()
    if !result.ok {
        span.setStatus(.error(name: "SaveError", message: result.reason))
    }
    return result
}
```

## Adapter Contract

An adapter must:

- run the callback once, in the caller's task, before `startSpan` returns. Mark `startSpan`
  `nonisolated(nonsending)`, so the callback also runs on the caller's executor;
- return the callback's value, or throw the error it threw;
- keep the backend span open until the callback returns or throws;
- treat a return as `ok` and a throw as `error`, unless the callback set a status;
- let the last `setStatus` call win;
- merge `setAttributes` calls: a later value replaces an earlier one, and a nil value is ignored;
- keep recording methods synchronous and passive, and handle backend failures itself;
- ignore calls after the span settled, and run the callback of a child of a settled span without
  recording it.

Buffering, flushing, sampling, backend IDs, and backend context objects belong to the adapter.
The conformance cases check the observable behavior.

## No-op Context

`noopTelemetryContext` is the default when telemetry is optional. It runs callbacks in the
caller's task and returns their values and errors. It passes one shared inert span, also to
nested spans. It does not inspect or retain names, attributes, events, or statuses.

## In-Memory Reference Adapter

`InMemoryTelemetryContext` records spans in process memory. It suits tests and local diagnostics:

```swift
let telemetry = InMemoryTelemetryContext()
await telemetry.startSpan(SpanOptions(name: "example.operation", attributes: ["input": "demo"])) { span in
    span.addEvent("example.started")
    span.setAttributes(["output_count": 3])
}
print(telemetry.getSpans())
```

`getSpans()` returns snapshots in span-start order. Each `RecordedTelemetrySpan` has an ID from 1,
the parent ID, the merged attributes, the events in order, the status, whether it settled, and its
place in end order. It records no timestamps. Storage is unbounded. Create a fresh instance for each
test or recording scope.

## Adapter Conformance

`createTelemetryAdapterConformance` in PiSwiftTelemetryTesting returns cases for any test runner.
The factory makes a fresh fixture for each case. The fixture converts the backend's finished spans
into `RecordedTelemetrySpan` snapshots; `getSpans` may flush an exporter first:

```swift
private let cases = createTelemetryAdapterConformance {
    let adapter = InMemoryTelemetryContext()
    return TelemetryAdapterFixture(context: adapter, getSpans: { adapter.getSpans() }, dispose: {})
}

@Test(arguments: cases)
func telemetryAdapterConformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
    try await testCase.run()
}
```

A failed check throws `TelemetryConformanceFailure` with its file and line.

## Typed Schemas

A domain module defines a schema: span names, start and end attributes, events, and the status rule.
The schema is Codable data in upstream's JSON shape:

```swift
let exampleTelemetrySchema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [
    "example.read": TelemetrySpanDefinition(
        description: "Read one resource",
        parents: .any,
        startAttributes: [
            "example.resource": .init(.string(values: ["account", "project"]),
                                      description: "Resource kind", required: true),
        ],
        endAttributes: [
            "example.item_count": .init(.number(), description: "Number of returned items"),
        ],
        events: [
            "example.cache": TelemetryEventDefinition(description: "Cache lookup result", attributes: [
                "example.cache.hit": .init(.boolean(), description: "Whether the cache contained the resource",
                                           required: true),
            ]),
        ],
        status: TelemetryStatusDefinition(errorWhen: "The read throws or returns an error result")
    ),
]))

let startSpan = createTypedSpanStarter(telemetry, [exampleTelemetrySchema])
let accounts = try await startSpan("example.read", ["example.resource": "account"]) { span, startChildSpan in
    span.addEvent("example.cache", attributes: ["example.cache.hit": true])
    let accounts = try await readAccounts()
    span.setAttributes(["example.item_count": .number(Double(accounts.count))])
    try await startChildSpan("example.read", ["example.resource": "project"]) { childSpan, _ in
        let projects = try await readProjects()
        childSpan.setAttributes(["example.item_count": .number(Double(projects.count))])
    }
    return accounts
}
```

Start attributes are known when the span starts; end attributes are set while it runs, and are
always optional. Both become ordinary attributes of the same span. Setting an attribute does not
end the span. Upstream checks names and attributes against the schemas at compile time. Swift cannot
infer types from schema data, so nothing checks them; upstream does not check them at run time either.

Attribute types are `string`, `number`, `boolean`, and their arrays. A definition can list `values`
(scalars) or `elementValues` (arrays), `examples`, `sensitive`, and `cardinality` (`low` or `high`).
Start and event attributes state `required`. The parent rule is `.any`, `.rootOrExternal`, or
`.spans([...])`. It describes; nothing enforces it.

## Security and Portability

Telemetry is process-local diagnostics. Do not persist a context, a span, or a backend trace object
in records, messages, snapshots, or deferred handles. Attribute values are scalars and arrays. Keep
prompts, completions, tool arguments and output, file contents, provider payloads, headers,
credentials, and free-form error details out of attributes unless a schema and data policy allow them.

## Swift Differences and Scope

- `AttributeValue` is an enum with string, number, and boolean literals. Numbers are `Double`, like
  JavaScript numbers. `SpanAttributes` is `[String: AttributeValue?]`: nil stands for `undefined` and is
  ignored. Recorded snapshots hold `[String: AttributeValue]`. `SpanStatus` is an enum, and `.error(nil)`
  is upstream `{ status: "error" }`.
- `startSpan` is async with typed throws: a callback that cannot throw makes a call without `try`.
  JavaScript's synchronous throw and asynchronous rejection are one path. "Admitted synchronously"
  becomes "runs in the caller's task", and the conformance case checks the task.
- `TelemetryContext` is class-bound, so spans have identity. The no-op span is `noopTelemetryContext` itself.
- `InMemoryTelemetryContext` keeps its state behind a lock, because Swift tasks can record on one span
  from several threads. A thrown error's automatic status records the error's type name and its
  `errorDescription`, or its description. Every Swift error has these; upstream records a name and
  message only for `Error` objects.
- Swift values cannot throw on read, so upstream's unreadable-payload paths have no counterpart:
  the two "passivity" cases, "ignores failed attribute calls atomically", the unreadable and
  `undefined` rejections in the rejection case, and the no-op "does not inspect" test.
- Schemas are Codable structs. `TelemetryAttributeKind` replaces the union discriminated by `type`.
  Without intersection types, start and event attribute definitions repeat the attribute fields and
  add `required`. TypeScript's schema inference has no counterpart: the starter takes `String` names
  and `SpanAttributes`, its callback gets `any TelemetrySpan`, and duplicate span names are not rejected.
  `InferStartAttributes`, `ExactTelemetryAttributes`, `SchemaTelemetrySpan`, `TelemetrySchemaSpanUnion`,
  and the other `TelemetrySchemaSpan*` types are not ported.
- `TelemetryAdapterFixture` is a struct of closures. `dispose` replaces `AsyncDisposable`: it runs after
  every case, and when both the case and `dispose` fail, the case's error is thrown.
- PiSwiftAI does not take a telemetry context yet; upstream pi-ai's request options do.
  See `FLEET_FORK.md`.
