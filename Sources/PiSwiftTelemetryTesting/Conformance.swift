// Ports upstream `packages/telemetry/src/testing/conformance.ts` at 482c1381a.

import PiSwiftTelemetry
import Synchronization

private typealias ConformanceTest = @Sendable (TelemetryAdapterFixture) async throws -> Void

private func createCase(
    _ factory: @escaping TelemetryAdapterFixtureFactory,
    _ group: String,
    _ name: String,
    _ test: @escaping ConformanceTest
) -> TelemetryAdapterConformanceCase {
    TelemetryAdapterConformanceCase(group: group, name: name) {
        let fixture = try await factory()
        let outcome: Result<Void, any Error>
        do {
            try await test(fixture)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        do {
            try await fixture.dispose()
        } catch {
            if case .success = outcome { throw error }
        }
        try outcome.get()
    }
}

private func ok(_ value: Bool, _ message: String, file: String = #filePath, line: UInt = #line) throws {
    guard value else { throw TelemetryConformanceFailure(message, file: file, line: line) }
}

private func strictEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: UInt = #line) throws {
    try ok(actual == expected, "Expected \(String(describing: expected)); got \(String(describing: actual))",
           file: file, line: line)
}

private func findSpan(
    _ spans: [RecordedTelemetrySpan], _ name: String, file: String = #filePath, line: UInt = #line
) throws -> RecordedTelemetrySpan {
    guard let span = spans.first(where: { $0.name == name }) else {
        throw TelemetryConformanceFailure("Expected recorded span \(name)", file: file, line: line)
    }
    return span
}

private func isError(_ status: SpanStatus) -> Bool {
    if case .error = status { return true }
    return false
}

/// An error compared by identity, for upstream's `strictEqual` on rejection values.
private final class ConformanceError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A result compared by identity.
private final class ConformanceResult: Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private func rejectsWithSameValue(
    _ expected: ConformanceError,
    file: String = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async throws {
    do {
        try await operation()
    } catch {
        try ok((error as? ConformanceError) === expected, "Expected the same error; got \(error)", file: file, line: line)
        return
    }
    throw TelemetryConformanceFailure("Expected operation to reject", file: file, line: line)
}

/// The current task, so a case can tell whether a callback ran in the caller's task.
private func currentTaskHash() -> Int? {
    withUnsafeCurrentTask { $0?.hashValue }
}

private final class ConformanceGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
}

/// Creates runner-independent cases for the callback telemetry adapter contract.
public func createTelemetryAdapterConformance(
    _ factory: @escaping TelemetryAdapterFixtureFactory
) -> [TelemetryAdapterConformanceCase] {
    [
        createCase(factory, "callback lifecycle", "admits once synchronously and preserves the result") { fixture in
            var calls = 0
            var callbackTask: Int?
            let callerTask = currentTaskHash()
            let expected = ConformanceResult(42)
            let result = await fixture.context.startSpan(SpanOptions(name: "success")) { _ in
                calls += 1
                callbackTask = currentTaskHash()
                return expected
            }

            try ok(callbackTask != nil && callbackTask == callerTask, "Expected the callback to run in the caller's task")
            try strictEqual(calls, 1)
            try ok(result === expected, "Expected the callback's result")
            try strictEqual(try findSpan(try await fixture.getSpans(), "success").status, .ok)
            try strictEqual(try findSpan(try await fixture.getSpans(), "success").settled, true)
        },

        createCase(factory, "callback lifecycle", "preserves synchronous and asynchronous rejection values") { fixture in
            let syncError = ConformanceError("sync")
            try await rejectsWithSameValue(syncError) {
                try await fixture.context.startSpan(SpanOptions(name: "sync-error")) { _ in
                    throw syncError
                }
            }

            let asyncError = ConformanceError("async")
            try await rejectsWithSameValue(asyncError) {
                try await fixture.context.startSpan(SpanOptions(name: "async-error")) { _ in
                    await Task.yield()
                    throw asyncError
                }
            }

            let spans = try await fixture.getSpans()
            for name in ["sync-error", "async-error"] {
                try ok(isError(try findSpan(spans, name).status), "Expected \(name) to have an error status")
            }
        },

        createCase(factory, "status", "uses last explicit status without automatic overwrite") { fixture in
            await fixture.context.startSpan(SpanOptions(name: "last-status")) { span in
                span.setStatus(.error(name: "Expected", message: "first"))
                span.setStatus(.ok)
            }

            let thrown = ConformanceError("after explicit status")
            try await rejectsWithSameValue(thrown) {
                try await fixture.context.startSpan(SpanOptions(name: "explicit-before-throw")) { span in
                    span.setStatus(.ok)
                    throw thrown
                }
            }

            let rejected = ConformanceError("after async explicit status")
            try await rejectsWithSameValue(rejected) {
                try await fixture.context.startSpan(SpanOptions(name: "explicit-before-rejection")) { span in
                    span.setStatus(.error(name: "Expected", message: "async failure"))
                    await Task.yield()
                    throw rejected
                }
            }

            _ = await fixture.context.startSpan(SpanOptions(name: "expected-failure")) { span in
                span.setStatus(.error(name: "Expected", message: "returned failure"))
                return false
            }

            let spans = try await fixture.getSpans()
            try strictEqual(try findSpan(spans, "last-status").status, .ok)
            try strictEqual(try findSpan(spans, "explicit-before-throw").status, .ok)
            try strictEqual(try findSpan(spans, "explicit-before-rejection").status,
                            .error(name: "Expected", message: "async failure"))
            try strictEqual(try findSpan(spans, "expected-failure").status,
                            .error(name: "Expected", message: "returned failure"))
        },

        createCase(factory, "recording", "merges attributes and records ordered events") { fixture in
            await fixture.context.startSpan(SpanOptions(
                name: "recording",
                attributes: ["start": "value", "overwrite": "start", "ignored": nil]
            )) { span in
                span.setAttributes(["count": 1, "overwrite": "middle"])
                span.setAttributes(["count": nil, "overwrite": "end"])
                span.addEvent("first", attributes: ["index": 1, "ignored": nil])
                span.addEvent("second", attributes: ["index": 2])
            }

            let span = try findSpan(try await fixture.getSpans(), "recording")
            try strictEqual(span.attributes, ["start": "value", "overwrite": "end", "count": 1])
            try strictEqual(span.events, [
                RecordedTelemetryEvent(name: "first", attributes: ["index": 1]),
                RecordedTelemetryEvent(name: "second", attributes: ["index": 2]),
            ])
        },

        createCase(factory, "recording", "makes calls after settlement inert") { fixture in
            var settledSpan: (any TelemetrySpan)?
            await fixture.context.startSpan(SpanOptions(name: "settled", attributes: ["value": "initial"])) { span in
                settledSpan = span
            }
            guard let capturedSpan = settledSpan else {
                throw TelemetryConformanceFailure("Expected callback span")
            }

            capturedSpan.setAttributes(["value": "late"])
            capturedSpan.addEvent("late", attributes: ["value": true])
            capturedSpan.setStatus(.error(nil))
            var childAdmitted = false
            let childResult = await capturedSpan.startSpan(SpanOptions(name: "late-child")) { _ in
                childAdmitted = true
                return 7
            }
            try strictEqual(childAdmitted, true)
            try strictEqual(childResult, 7)

            let spans = try await fixture.getSpans()
            try strictEqual(spans.count, 1)
            try strictEqual(spans.first?.attributes, ["value": "initial"])
            try strictEqual(spans.first?.events, [])
            try strictEqual(spans.first?.status, .ok)
        },

        createCase(factory, "parentage", "records nested and concurrent child relationships") { fixture in
            let firstEntered = ConformanceGate()
            let releaseFirst = ConformanceGate()

            try await fixture.context.startSpan(SpanOptions(name: "parent")) { parent in
                async let first: Void = parent.startSpan(SpanOptions(name: "first-child")) { _ in
                    firstEntered.open()
                    await releaseFirst.wait()
                }
                // Upstream's first child is open by the time the second starts.
                await firstEntered.wait()
                let second = await parent.startSpan(SpanOptions(name: "second-child")) { _ in "done" }
                try strictEqual(second, "done")
                releaseFirst.open()
                await first
            }

            let spans = try await fixture.getSpans()
            let parent = try findSpan(spans, "parent")
            let first = try findSpan(spans, "first-child")
            let second = try findSpan(spans, "second-child")
            try strictEqual(parent.parentId, nil)
            try strictEqual(first.parentId, parent.id)
            try strictEqual(second.parentId, parent.id)
            guard let secondEnd = second.endSequence, let firstEnd = first.endSequence,
                  let parentEnd = parent.endSequence else {
                throw TelemetryConformanceFailure("Expected every span to have an end sequence")
            }
            try ok(secondEnd < firstEnd, "Expected second-child to end before first-child")
            try ok(firstEnd < parentEnd, "Expected first-child to end before parent")
        },
    ]
}
