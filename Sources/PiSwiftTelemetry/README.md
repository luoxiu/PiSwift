# PiSwiftTelemetry

> **Experimental.** The API can change without notice between releases.

PiSwiftTelemetry ports `@earendil-works/pi-telemetry`
([`packages/telemetry`](https://github.com/earendil-works/pi/tree/482c1381a/packages/telemetry))
at upstream `482c1381a`, the parent of `48909d987`. Upstream's sources, tests, and README there are
unchanged since `35f5c265d` (v0.84.0). Later upstream commits that `FLEET_FORK.md` lists as ported
come on top: propagation, links, and metrics (`48909d987`), and capabilities on every context
(`2ec55d808`). It has no dependencies. The package
requires macOS 15 or iOS 18.

It provides:

- the callback-based `TelemetryContext` and `TelemetrySpan` contract;
- the shared `noopTelemetryContext`;
- opaque cross-process propagation and span links;
- counters, up-down counters, histograms, and typed metric schemas;
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
parent context of its children. A context may expose its adapter's `metrics` and `propagation`;
child spans and extracted parents carry the same objects. The adapter, a `TelemetryContext`, starts
root spans and stays with the host; invocation contexts (`ChordContext.telemetry`) and PiSwiftAI's
request options carry a `TelemetrySpan`, never the adapter. A tracing adapter that only implements
`startSpan` is valid. `ReadmeExamplesTests` runs the code blocks; the marker names in that file
identify each block.

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
- expose its optional `metrics` and `propagation` on its root, its spans, and its extracted parents,
  inert fallback spans included;
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

## Propagation and Span Links

An adapter may also implement `TelemetryPropagation`. Expose it as `context.propagation`, so code can
inject or extract with the context it already has; the root, the spans, and the extracted parents share
the adapter's object:

```swift
public protocol TelemetryPropagation: AnyObject, Sendable {
    func inject(_ context: any TelemetryContext) -> TelemetryCarrier?
    func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext
}
public typealias TelemetryCarrier = [String: String]
```

A carrier is an opaque string map that survives JSON. The adapter owns its format; W3C `traceparent`
and `tracestate` fit without being required. Transport code sends only the carrier, never a context
or a span:

```swift
let caller = InMemoryTelemetryContext()
let provider = InMemoryTelemetryContext()
try await caller.startSpan(SpanOptions(name: "rpc.client")) { span in
    let wire = try JSONEncoder().encode(caller.inject(span))
    let carrier = try JSONDecoder().decode(TelemetryCarrier?.self, from: wire)
    try await provider.extract(carrier).startSpan(SpanOptions(name: "rpc.server")) { serverSpan in
        try await handleRequest(serverSpan)
    }
}
```

Injection returns a detached carrier, or nil for roots, no-op contexts, and contexts the adapter does
not support. Extraction returns a parent the receiver owns. An absent, invalid, or unknown carrier
falls back to the adapter's root, so incoming work is still recorded. Both methods are synchronous,
passive, and do not throw. Trace metadata is untrusted diagnostics, never authorization. Transport
boundaries own carrier size limits.

A link relates work without changing its parent. Pass `SpanOptions.links` when the target is known at
creation, or call `span.addLink()` once the span has started:

```swift
try await telemetry.startSpan(SpanOptions(
    name: "activation", links: [SpanLink(context: firstGetter, attributes: ["reason": "trigger"])]
)) { activation in
    laterGetter.addLink(SpanLink(context: activation))
    try await activate()
}
```

A link target is a `TelemetryContext`: a span or an extracted remote parent. For a remote link, first
call `adapter.extract(carrier)`. A settled target can still be linked and injected; a settled source
ignores `addLink()`. Links append in order and copy their attributes; a link to a root, a no-op, or an
unsupported context is ignored. The typed span starter's callback span has `addLink()` too; initial
links need the plain `startSpan()`.

`noopTelemetryPropagation` never inspects its arguments: injection returns nil, extraction returns
`noopTelemetryContext`.

## Metrics

An adapter may implement `TelemetryMetrics` alongside `TelemetryContext` and `TelemetryPropagation`.
Applications configure one adapter, not a backend for each capability. Expose it as `context.metrics`;
child spans keep it, so a nested model call records metrics without its own setting. The in-memory
adapter implements the factories itself:

```swift
let bytes = telemetry.counter("network.bytes", options: InstrumentOptions(
    description: "Encoded WebSocket bytes", unit: "By"))
bytes.add(Double(encodedSize), attributes: ["direction": "out"])

let active = telemetry.upDownCounter("calls.active")
active.add(1)
active.add(-1)

let duration = telemetry.histogram("call.duration", options: HistogramOptions(
    unit: "ms", boundaries: [1, 10, 100, 1000]))
duration.record(elapsedMs, attributes: ["method": "read"], context: currentSpan)
```

Factories take an instrument name and optional `InstrumentOptions` (`description`, `unit`).
`HistogramOptions` adds `boundaries`: finite, strictly increasing bucket hints. Backends own
aggregation and may translate the hints. Counters accept non-negative finite increments; up-down
counters and histograms accept finite signed values. A histogram's `record(_:attributes:context:)`
can correlate a measurement with a span, an exemplar. A counter's `add` has no context.

Factories and recording methods are synchronous, passive, and do not throw. An invalid measurement
or invalid boundaries are ignored. `noopTelemetryMetrics` returns shared instruments and inspects
nothing. Record only values the code already has; do not compute extra data for telemetry.

Use only low-cardinality attributes: bounded values such as a direction or a method, not request IDs,
user IDs, prompts, or arbitrary paths. The attribute bag stays open; the instrumentation owns this
policy, not the backend.

### Typed metric schemas

`TelemetrySchemaDefinition.metrics` declares instrument names, kinds, metadata, and attributes.
`createTypedMetrics` combines one or more schemas:

```swift
let schema = defineTelemetrySchema(TelemetrySchemaDefinition(version: 1, spans: [:], metrics: [
    "network.bytes": .counter(description: "Encoded bytes", unit: "By", attributes: [
        "direction": .init(.string(values: ["in", "out"]), description: "Direction", required: true,
                           cardinality: .low),
    ]),
]))

let metrics = createTypedMetrics(telemetry, [schema])
metrics.counter("network.bytes").add(Double(encodedSize), attributes: ["direction": "out"])
```

A definition is `.counter`, `.upDownCounter`, or `.histogram`; only `.histogram` takes `boundaries`.
Metric attributes use the span attribute types, and their cardinality can only be `.low`. Omitting
it does not waive the low-cardinality policy. Unlike the typed span starter, the typed metrics read
and keep each instrument's metadata from the schemas. Upstream checks names, kinds, and attributes at
compile time; nothing checks them in Swift, and nothing checks attributes at run time upstream either.

`InMemoryTelemetryContext.getMetrics()` returns `RecordedTelemetryMeasurement` snapshots in recording
order: `kind`, `name`, `description`, `unit`, `boundaries`, `value`, `attributes`, and the exemplar's
carrier as `context`, or nil. It is a log of measurements, not aggregated counters or buckets; storage
is unbounded and records no timestamps.

## No-op Context

`noopTelemetryContext`, the shared inert span, is the default when telemetry is optional. It runs
callbacks in the caller's task and returns their values and errors. It passes itself, also to
nested spans. Its `metrics` and `propagation` are `noopTelemetryMetrics` and `noopTelemetryPropagation`.
It does not inspect or retain names, attributes, events, or statuses.

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
the local parent ID, the carriers of the span (`context`) and of its parent (`parentContext`), the
links in order, the merged attributes, the events in order, the status, whether it settled, and its
place in end order. It records no timestamps. A remote parent has a nil `parentId` and a
`parentContext`; a root has neither. A `RecordedTelemetryLink` holds the target's carrier and the
link attributes.

The adapter implements `TelemetryPropagation` with a small carrier of its own: a unique recorder
scope and the span ID. The carrier survives JSON and works across processes without a shared
registry. Its keys are an implementation detail, not a wire format for other adapters. Storage is
unbounded. Create a fresh instance for each test or recording scope.

## Adapter Conformance

`createTelemetryAdapterConformance` in PiSwiftTelemetryTesting returns cases for any test runner.
The factory makes a fresh fixture for each case. The fixture converts the backend's finished spans
into `RecordedTelemetrySpan` snapshots; `getSpans` may flush an exporter first:

```swift
private let cases = createTelemetryAdapterConformance {
    let adapter = InMemoryTelemetryContext()
    return TelemetryAdapterFixture(context: adapter, propagation: adapter, metrics: adapter,
                                   getMetrics: { adapter.getMetrics() }, getSpans: { adapter.getSpans() },
                                   dispose: {})
}

@Test(arguments: cases)
func telemetryAdapterConformance(_ testCase: TelemetryAdapterConformanceCase) async throws {
    try await testCase.run()
}
```

The cases cover the capabilities on roots, child spans, extracted parents, and inert spans, the
callback contract, and links. A fixture that supplies `propagation` also gets the
JSON round trip, multiple adapter hops, and the fallback for unknown carriers; one that supplies
`metrics` and `getMetrics` gets ordered measurements, exemplars, input copying, and the suppression of
invalid measurements and boundaries. A failed check throws `TelemetryConformanceFailure` with its file
and line.

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

## Pi Schemas

PiSwiftAI exports `aiTelemetrySchema` (upstream `AI_TELEMETRY_SCHEMA`): `pi.ai.request` and `pi.ai.poll`
spans with their events and metrics, recorded when request options carry a parent span in `telemetry`.
PiSwiftDurable exports `durableTelemetrySchema` (upstream `DURABLE_TELEMETRY_SCHEMA`): `pi.durable.submit`
and `pi.durable.phase` spans, their events, and metrics, recorded with `HarnessOptions.telemetry`. Both use
pi-owned `pi.ai.*` and `pi.durable.*` names, which an adapter may translate to backend conventions.

## Security and Portability

Telemetry is diagnostics, not durable application state. Do not persist a context, a span, or a
backend trace object in records, messages, snapshots, or deferred handles. An injected
`TelemetryCarrier` may cross a transport or be stored as optional diagnostic correlation data. It is
best effort: an adapter change may lose the correlation, but must not prevent work. Attribute values are scalars and arrays. Keep
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
  `undefined` rejections in the rejection case, the no-op "does not inspect" test, and the unreadable
  links, carriers, options, and attributes in the links, propagation, and metrics cases.
- Schemas are Codable structs. `TelemetryAttributeKind` replaces the union discriminated by `type`.
  Without intersection types, start and event attribute definitions repeat the attribute fields and
  add `required`. TypeScript's schema inference has no counterpart: the starter takes `String` names
  and `SpanAttributes`, its callback gets `any TelemetrySpan`, and duplicate span names are not rejected.
  `InferStartAttributes`, `ExactTelemetryAttributes`, `SchemaTelemetrySpan`, `TelemetrySchemaSpanUnion`,
  and the other `TelemetrySchemaSpan*` types are not ported.
- `TelemetryPropagation` and `TelemetryMetrics` are class-bound protocols. The instruments are protocols
  (`TelemetryCounter`, `TelemetryUpDownCounter`, `TelemetryHistogram`) with convenience overloads for
  omitted attributes and options. `TelemetryMetricDefinition` is built with `.counter`,
  `.upDownCounter`, or `.histogram`, so only histograms take boundaries; a counter with boundaries does
  not decode. `TelemetryMetricAttributeDefinition` repeats the start attribute fields with a
  cardinality that can only be `.low`. `createTypedMetrics` takes `String` names and returns plain
  instruments: upstream's `SchemaTelemetryCounter` and `SchemaTelemetryHistogram` and its duplicate
  name check are compile-time only.
- The in-memory spans and extracted parents carry their own carriers, where upstream keeps them in a
  module-level WeakMap. Any in-memory recorder injects another one's spans, as upstream. Its scope is a
  lowercase UUID, as `crypto.randomUUID()` gives, and extraction checks it and the span ID by hand
  against upstream's two regular expressions and its safe-integer bound.
- `TelemetryAdapterFixture` is a struct of closures. `dispose` replaces `AsyncDisposable`: it runs after
  every case, and when both the case and `dispose` fail, the case's error is thrown.
- `metrics` and `propagation` are protocol requirements with default implementations that return nil,
  for upstream's optional members. `noopTelemetryContext` has the type `any TelemetrySpan`. An inert
  in-memory span is a span of its own type carrying the recorder's capabilities, where upstream spreads
  the no-op span and overrides them. In-memory spans keep their recorder's context alive, as the
  capability they expose.
- PiSwiftAI records `pi.ai.*` spans in its dispatch functions `stream`, `streamSimple`, and
  `streamDeferred`, and in `complete`, `completeSimple`, and `fetchDeferred`, which use them; upstream
  records them in `Models`, which PiSwiftAI does not have. Without `telemetry` in the options, the
  provider's stream is returned unchanged; with it, a task forwards the events through an observed stream.
  A setup failure throws, as these functions do, after it is recorded as upstream records its error
  event. Each metrics object's instruments are created once and cached by a weak reference to it.
  See `FLEET_FORK.md`.
