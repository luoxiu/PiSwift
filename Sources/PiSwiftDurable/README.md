# PiSwiftDurable

> **Experimental.** The API can change without notice between releases.

PiSwiftDurable ports the library core of `@earendil-works/pi-durable` at
[v1.1.0](https://github.com/earendil-works/pi/tree/v1.1.0/packages/durable),
plus the later upstream commits that `FLEET_FORK.md` lists as ported.
It uses PiSwiftAI for model types and PiSwiftChord for JSON state and observation.
The package requires macOS 15 or iOS 18. It uses Swift 6 strict concurrency.

## Concepts

- **Harness** opens a Session and runs durable tasks. All writes use atomic commits.
- **Conversation** contains immutable transcript entries. Compare handles by `id`.
- **Document** holds JSON state. A typed token defines scope, history, initial value,
  version, and fork policy. Use Codable, Sendable value types.
- **Task** runs a state machine with a stored checkpoint. A conversation or task owns it.
  Built-in tasks run generation, tools, and compaction.
- **Submission** admits input or a write. `wait` returns its stored outcome.
- **Registry** holds extensions, tools, prompt sections, hooks, wrappers, and tasks.
  Conversations store choices by name. Install extensions again when you reopen storage.

Changes go to storage before observers receive them. A transcript normally contains
`pi.user`, a positional `pi.system` entry, and `pi.assistant`. Tool rounds also add
`pi.tool-result`. Built-in documents include `pi.agent`, `pi.provider`, `pi.live`,
`pi.inbox`, and `pi.usage`.

Calls take a `ChordContext`. `ChordContext.background` does not cancel.
`ChordContextKey` carries typed values. These names replace upstream `Context` and
`ContextKey`. PiSwiftAI already has a public `Context`. This rename is the user's choice.
Cancellation of a submission wait cancels that wait. It does not withdraw the submission.

## Quick Start

Use `FakeDurableModels` from PiSwiftDurableTesting for deterministic tests.
A host supplies `DurableModels` for real requests. The core has no global provider registry.
Import Foundation, PiSwiftAI, PiSwiftChord, PiSwiftDurable, and PiSwiftDurableTesting.
Run each body below in an async throwing function. `ReadmeLocalExamplesTests` runs all
code blocks with public imports. The marker names in that file identify each block.
This block uses the chat scenario from upstream example 14.

```swift
let context = ChordContext.background
let models = FakeDurableModels(responses: [.message(fauxAssistantMessage(
    content: [.text(TextContent(text: "Paris."))], timestamp: 1))])
let registry = createRegistry()
try registry.install(Extension(name: "terse", sections: [
    section("preamble", tag: false) { _, _ in "You answer in one word." }
]))
let harness = try await Harness.open(storage: MemoryStorage(),
    options: .init(models: models, registry: registry), context: context)
let root = try await harness.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
let submission = try await root.submit(
    .input(content: .text("Capital of France?")), context: context)
let settled = try await submission.wait(context: context)
if let answer = settled.answer {
    let entry = try await root.commit({ tx in try await tx.entry(answer) }, context: context)
    let messages = try entry?.messages()
    print(messages ?? [])
}
try await harness.close(context: context)
```

`submit` stores the input. Generation prepares the prompt, calls the model service,
and commits the answer. `wait` returns `done` or an unanswered outcome.
The test checks `done` and one model call. Example 14 also checks `Paris.` and entry kinds.

## Persist and Resume

`MemoryStorage` keeps data for the life of its instance. Use SQLite or JSONL for restart
persistence. Supply a writable SQLite `path`, plus `models`, `registry`, and `context`.
The test supplies one fake `Hello.` answer. A repeated request ID returns the original submission.

```swift
let options = HarnessOptions(models: models, registry: registry)
let first = try await Harness.open(storage: SqliteStorage.open(path: path),
    options: options, context: context)
let root = try await first.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
let original = try await root.submit(.input(content: .text("Hello"),
    requestId: "greeting-1"), context: context)
_ = try await original.wait(context: context)
try await first.close(context: context)

let reopened = try await Harness.open(storage: SqliteStorage.open(path: path),
    options: options, context: context)
let sameRoot = try await reopened.root(context: context)
try reopened.resume()
let again = try await sameRoot.submit(.input(content: .text("Hello"),
    requestId: "greeting-1"), context: context)
// again.id == original.id: no second input is admitted.
let settled = try await again.wait(context: context)
try await reopened.close(context: context)
```

Pending tasks keep checkpoints and memos on close. Reopen with their extensions installed,
then call `resume`. Submission or waiting also enables scheduling. Example 13 resumes
through tick 5 without duplicate ticks. Examples 24 and 31 check task and tool recovery.
Close the Harness to stop its work and close storage.

## Extensions and Tools

Create `registry` with `createRegistry()`. Install this extension before you open the Harness.

```swift
let echo = try ToolRegistration(name: "echo", description: "Return text",
    parameters: ["type": "object", "properties": .object([
        "text": .object(["type": "string"])
    ]), "required": .array(["text"])], replay: .safe) { args, _, _ in
        ToolExecutionResult(output: [.text(TextContent(
            text: args["text"]?.stringValue ?? ""))])
    }
try registry.install(Extension(name: "echo", tools: [echo]))
```

The Harness validates arguments before execution. A safe tool can run again after an
interrupted execute phase. Declare safe replay only if the work can repeat safely.
An unsafe interrupted call becomes an interrupted tool result. Tools can use their bound
API for commits, memos, owned tasks, output, details, models, and the host environment.
An extension can also supply `sections`, `hooks`, `wraps`, and `tasks`.
Replacement keeps an extension's position. A running call keeps its selected code.
The next call uses the new code (example 31).

A result has three channels: `output` for the model, `structuredOutput` for programs that
call the tool, and `details` for UIs. A tool that declares `structuredOutputSchema` returns
a matching `structuredOutput`, which the Harness validates. Programs that call a tool without
a schema get its bounded output: one text item as a string, one image as its JSON, nothing
as `""`, and anything else as the content list. The transcript stores only `output` and
`details`. A broken `structuredOutput` gives a nested call an `invalid_structured_output`
error result. A model-issued call only loses it, and `onReport` gets the break.

A tool calls another tool with `api.executeTool(_:arguments:options:context:)`. The nested
call is its own `pi.tool` task, owned by the caller. It is validated, runs the tool hooks,
whose `ToolHookCall` carries `parent`, and keeps its own output limits and replay policy.
Its `NestedToolExecutionResult` returns to the caller, not the transcript. The result lives
in the caller's `NestedResultDoc` until the caller settles. Nested calls show in
`pi.live.nestedTools` and as tool events with `parentToolCallId` and `parentTaskId`.
A key names each nested call: its position by default, or `options.key`. A replay-safe
caller that reruns after a crash gets its nested calls back by key. A caller that is not
replay-safe never reruns, so its unfinished nested calls are abandoned after a restart.
Before a caller settles, it aborts the nested calls it left running.

`callers` on a tool says who may call it: `.model`, `.tools`, or both by default.
A conversation's `modelTools` narrows the tools the model is offered. Tools can still
call the others. `Agent.callable` lists the tools nested calls resolve among.
A task created with `abandonOnRestart` is aborted with reason `restart`, with its owned
work, when a later Harness starts scheduling. Such a task waits for a missing definition
instead of becoming orphaned. `runtime.abortOwned` aborts an owned task and waits for it.

Busy input defaults to a follow-up. `.steer` joins after the tool round.
`.reject` rejects busy admission. Writes append without a model call. Example 20 checks
steering, follow-ups, and queued withdrawal. Tasks can wait for children with `.failFast`
or `.allSettled`. Example 24 checks fail-fast, abort propagation, and restart.

## Watching

A watch starts with its current value. `start` receives later committed frames.
It does not send the initial value again. Supply `root` and `context` from an open Harness.
Import Synchronization for `Mutex`.

```swift
let observed = Mutex<[ConversationView]>([])
let watch = try await root.watch(context: context)
let initial = watch.value
try watch.start { value, ops, _ in
    // A UI can render value. A remote observer can apply the exact ops.
    observed.withLock { $0.append(value) }
    print(ops.count)
}
```

Call `await watch.stop()` when observation ends. Callbacks are async, Sendable, and serial
for each watch. Operations are the exact committed Chord operations. A slow watch holds
at most 100 pending frames. Overflow replaces them with a current snapshot.
A late observer starts at current state (example 21). `viewState` supplies an attached
read-only Chord state. Call `dispose` when finished. `watchEvents` and task-graph watches
supply other committed views. Use `Submission.wait` for a submission's exact outcome.

## Storage

| Backend | Persistence | Tests |
| --- | --- | --- |
| `MemoryStorage` | In memory | Integration and storage conformance |
| `SqliteStorage.open(path:)` | SQLite file, or `:memory:` | Reopen, recovery, migration, conformance |
| `JsonlStorage.open(directory:)` | Recoverable JSONL files | Reopen, recovery, conformance, TypeScript replay |
| Custom `DurableStorage` | Host-defined | Reusable storage conformance cases |

One process must own each storage's files. Use one open storage per file or directory.
There is no cross-process lock. Keep commits serialized through Session.
Preparation alone does not reserve a future commit. SQLite uses the Apple SDK library
and requires SQLite 3.37 or later. The port reads the upstream SQLite schema.
JSONL shares the valid format-1 files with TypeScript. JSON text bytes can differ.
It holds full state in memory and replays `main.jsonl` on open. Open can repair file tails.

Supply a fresh writable `sessionDirectory` and `context` for this storage example.

```swift
let storage = try await JsonlStorage.open(directory: sessionDirectory,
    options: .init(fsync: true), context: context)
let rootID = rootConversationID
_ = try await storage.commit([.conversation(value: ConversationRecord(id: rootID))],
    context: context)
try await storage.close(context: context)
let reopened = try await JsonlStorage.open(directory: sessionDirectory, context: context)
let saved = try await reopened.conversation(rootID, context: context)
try await reopened.close(context: context)
```

`fsync: true` flushes sidecars before each commit marker. The local adapter tries
`F_FULLFSYNC`, then uses `fsync` if full sync is unsupported. Ordinary main markers
are not flushed. An acknowledged tail marker can be lost after power failure.
A main-file flush permits destructive reclamation. These rules match upstream JSONL.
Run `storageConformanceCases` from PiSwiftDurableTesting to check a custom backend.

## Coding Tools

Install `CodingTools` to offer `read`, `write`, `edit`, and `bash`.
The extension is not installed by default. Each call uses its conversation's environment.
Supply `models` and a writable `projectDirectory`. The test supplies a fake edit call
and a `notes.txt` file that contains `hello world\n`.

```swift
let registry = createRegistry()
try registry.install(try CodingTools)
let harness = try await Harness.open(storage: MemoryStorage(),
    options: .init(models: models, registry: registry,
        env: { target, _ in LocalExecutionEnv(cwd: target.cwd ?? projectDirectory) }),
    context: .background)
let root = try await harness.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")),
    cwd: .set(projectDirectory))), context: .background)
let submission = try await root.submit(
    .input(content: .text("Edit notes.txt: replace world with durable.")),
    context: .background)
let settled = try await submission.wait(context: .background)
try await harness.close(context: .background)
```

`read` uses bounded memory and reports truncation and continuation diagnostics.
It returns an image file as one image block, which programs calling it get as an
`ImageContent`. Limits are the model's `inputLimits.images.resize`, by default
2000x2000 pixels and 4.5 MB of base64 (`defaultImageLimits`). Without an image
processor it sends PNG, JPEG, GIF, and WebP files within them as they are, without
decoding them, and refuses larger ones and other formats. With one, it decodes every
image, turns it upright by its EXIF orientation, converts BMP to PNG, and shrinks it
to fit. `createImageIOImages()` is that processor on ImageIO and Core Graphics:

```swift
try registry.install(try createCodingTools(options: .init(images: createImageIOImages())))
```

A model without image input sees a placeholder instead of the image, and `read` says
so in a diagnostic. An image must be read whole: one that changes while it is read is
read again. `write` keeps the supplied content.
`edit` matches replacements against the original file. It rejects missing, duplicate,
and overlapping targets. Details contain a display diff, a unified patch, and the first
changed line. It preserves BOM and uniform CRLF. Upstream and Swift normalize mixed
line endings to the first detected style. Unchanged fuzzy-match lines keep their text.

`bash` streams raw output. The Harness keeps its tail. The environment saves full output
to a spill file when needed. The host owns spill files. A nonzero exit is an error result
with an `exit_code` diagnostic. `structuredOutput` repeats the retained output and the exit
code for programs. A timeout throws. On iOS, LocalExecutionEnv returns
`shellUnavailable`. The Harness converts this to an error result. A mobile host can
select only the three file tools on an open `root`:

```swift
try await root.configure(change: .init(tools: .set(.exact([
    createReadTool(), createWriteTool(), createEditTool()
]))), context: .background)
```

Factories, `createCodingTools`, and `CodingTools` throw because construction checks their schemas.
`BashToolOptions.prepare` returns a `BashExecution` value. It sets command, cwd,
environment variables, and inheritance for that call. Mutations of one canonical path
in one environment ID run in order. This queue does not lock out shell commands or other processes.

A later same-name tool replaces an earlier tool. `wrapTool` decorates the selected tool.
This checked block uses `commandPrefix` to activate a virtual environment. It records
elapsed time for the selected bash. Supply `registry` and import Synchronization.

```swift
let venv = Extension(name: "venv", tools: [try createBashTool(options: .init(
    commandPrefix: "source .venv/bin/activate"))])
let durations = Mutex<[Duration]>([])
let timing = Extension(name: "timing", wraps: [wrapTool(try createBashTool()) { bash in
    var wrapped = bash
    wrapped.execute = { args, api, context in
        let start = ContinuousClock.now
        defer { durations.withLock { $0.append(start.duration(to: .now)) } }
        return try await bash.execute(args, api, context)
    }
    return wrapped
}])
try registry.install(venv)
try registry.install(timing)
```

## Environment

`HarnessOptions.env` builds an `ExecutionEnv` for each tool call, prompt section, or
`runtime.env()` call. It receives the conversation ID, agent cwd, and committed reads.
The Coding Tools block constructs LocalExecutionEnv from each conversation's cwd.
A fresh object per use is valid. Equal environment IDs must see the same files at the
same paths. All LocalExecutionEnv instances have ID `local`. Custom containers need
distinct IDs if they see different files. A missing or failed environment gives tools an error result.

Hosts can use the environment directly. Readers and watchers belong to the caller.
Close each handle when finished. `.argv` runs a program without shell parsing.
This block requires macOS and a writable `projectDirectory`:

```swift
let env = LocalExecutionEnv(cwd: projectDirectory)
let output = Mutex("")
let result = await env.exec(.argv(["/usr/bin/printf", "%s", "literal $text"]),
    options: .init(timeout: .seconds(3), onOutput: { text, _, info in
        if info.stream == .stdout { output.withLock { $0 += text } }
    }), context: .background)
await env.cleanup(context: .background)
```

Abort a command's ChordContext to stop that command. `cleanup` stops active local processes.
It does not close caller-owned handles or delete temporary directories and spill files.
iOS has local file operations and polling watches. It has no local shell.

Custom hosts can run `envConformanceCases` from PiSwiftDurableTesting. Supply a fresh,
empty, writable cwd for every case. Select the capabilities your host supports.
This runnable block selects eight reader cases. Enable `exec`, `watch`, and `symlinks`
for the complete suite. Symlink cases also require a `makeSymlink` callback.

```swift
let cases = envConformanceCases(capabilities: .init(exec: false, symlinks: false, watch: false)) { use in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let env = LocalExecutionEnv(cwd: directory.path)
    do {
        try await use(env)
        await env.cleanup(context: .background)
    } catch {
        await env.cleanup(context: .background)
        throw error
    }
}
for testCase in cases { try await testCase.run() }
```

## Errors

A storage error ends the Harness. The call that hit it throws the error. Every later call
and every pending wait throws `SessionFailed`, whose `cause` is that error. Watches and
event streams end with `.sessionFailed`. Running tasks get their abort signal. `onReport`
gets the error once. The Harness then closes itself, and `closed` returns
`.failed(error)`. After `close()`, `closed` returns `.closed`. Nothing retries: a custom
storage retries its own transient failures. Reopen to recover. Commits are atomic, and a
repeated `requestId` finds a submission that was already admitted.

An invalid read fails only that call. Storages throw `StorageRequestError` for a bad
cursor, an unknown conversation, or history a document does not keep. A read whose caller
cancelled it also fails only itself. User code fails only its unit: a task phase faults
its task, a tool gets an error result, and a hook is reported and skipped. A throwing
commit or close listener is reported, and the other listeners still run. A throw in the
Harness's own bookkeeping, such as a scheduler commit, fails the Harness.

## Swift Differences and Scope

- Typed IDs, enums, optionals, errors, and Codable/Sendable values replace TypeScript
  brands, unions, `undefined`, and dynamic casts. Some bad inputs fail at decoding.
  IDs and sequences stay within the JavaScript safe integer range.
- Chord drafts use explicit JSONDraft methods. Swift values replace proxy,
  freeze/clone, and object-identity rules. Equal document values can be silent.
  Tool content mutation counts as replacement for retained-content tracking.
- Swift String cannot hold lone UTF-16 surrogates. JSON rejects them.
  A compaction cut through a surrogate pair uses a replacement character.
  Integer arguments omit JavaScript coercion and sparse arrays.
- Observation callbacks are async and serial per watch. Different subscribers can
  run together. Source forwarding is synchronous. Default observation error handling
  ignores errors. Disposal does not throw.
- Contexts are values. Keys have object identity. Cancellation reasons are Swift Error
  values. Abort listeners have separate tokens. Late listeners do not run.
  Swift task cancellation bridges to Chord cancellation where the Harness supports it.
- Tool schemas are explicit JSON. Typed `defineTool` decodes arguments.
  Metadata is separate from tools. Hooks follow the declared upstream API.
  Bash preparation returns a value instead of changing a shared object.
- Models and live settings are injected services. Fakes are per instance.
  File and command failures use Result values. POSIX error text can differ from Node.
  File timestamps drop sub-millisecond precision. Pre-abort rejects zero-line reads.
  AI estimation and validation retain the port's JSON formatting and error text.
  Copy/session errors omit JavaScript cause chains. Snapshot decoding has typed errors.
- Timeouts use Duration. Positive deadlines below one nanosecond use one nanosecond.
  Sub-attosecond seconds can round to zero and fail validation. Node timer rounding differs.
- Local flush uses F_FULLFSYNC with an unsupported-operation fsync fallback.
  macOS watches use scoped FSEvents and snapshots. Native failure selects polling.
  iOS always uses polling. macOS shell collection uses kqueue, POSIX spawn, and secure
  spill creation. The host owns spills. Local execution reports all output chunks.
- The JSONL operation gate stays held across suspended I/O and includes reads and close.
  It protects one storage instance. Typed decoding can reject corrupt state sooner.
  Edit normalization of mixed line endings is shared upstream behavior.
- `StorageRequestError` wraps the built-in backends' `DurableStorageError` reason.
  Listeners and `onReport` are synchronous, and `now()` cannot throw. Upstream containment
  of rejected promises, foreign realms, unformattable values, and a throwing clock has no
  Swift counterpart. `ToolHookCall` reads `ToolCall` members by dynamic member lookup.
  Tool events carry a `DurableToolEventCall`. Nested summaries cut error text at 500 UTF-16
  code units and repair a cut surrogate pair. Default nested-call keys follow the order in
  which `executeTool` calls start running. Concurrent calls start in no fixed order, so a
  replay-safe caller that runs them concurrently passes explicit keys.
- `createImageIOImages()` replaces upstream's Photon processor (`createPhotonImages`, with its
  `/images/node` and `/images/cloudflare` loaders). It uses the system codecs, so it is part of
  this library rather than a separate entry and exists where ImageIO does. JPEG qualities 80 to
  40 map to ImageIO's 0.8 to 0.4, and Core Graphics' high-quality interpolation replaces Lanczos3,
  so re-encoded bytes differ. Foundation encodes base64.
- This library has no CLI or TUI code. PowerShell and Windows process support are outside scope.

Upstream examples 00–31 have Swift integration tests with assertions for the library
scenarios. Example 16 requires `PI_DURABLE_REAL_MODEL=1` and `OPENAI_API_KEY`.
Examples 18 and 19 retain their library print and event scenarios without CLI executables.
Most tests use fake models and temporary directories. The compile-only spec-usage test
checks public Swift API shapes and marks TypeScript-only forms.

The [v1.1.0 spec](https://github.com/earendil-works/pi/blob/v1.1.0/packages/durable/docs/spec.md)
is the design reference. This README describes the tested Swift surface.
