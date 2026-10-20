// Ports upstream `packages/telemetry/src/testing/conformance.ts` at 48909d987.

import Foundation
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

/// A carrier sent through JSON, as a transport would.
private func throughJSON(_ carrier: TelemetryCarrier, file: String = #filePath, line: UInt = #line) throws -> TelemetryCarrier {
    do {
        return try JSONDecoder().decode(TelemetryCarrier.self, from: JSONEncoder().encode(carrier))
    } catch {
        throw TelemetryConformanceFailure("Expected the carrier to survive JSON: \(error)", file: file, line: line)
    }
}

/// Runs `body` with a further fresh fixture and disposes it afterwards, also after a failed check
/// (upstream `await using`).
private func withFixture(
    _ factory: TelemetryAdapterFixtureFactory,
    _ body: (TelemetryAdapterFixture) async throws -> Void
) async throws {
    let fixture = try await factory()
    let outcome: Result<Void, any Error>
    do {
        try await body(fixture)
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
        createCase(factory, "metrics", "records ordered measurements and optional histogram exemplars") { fixture in
            guard let metrics = fixture.metrics else { return }
            guard let getMetrics = fixture.getMetrics else {
                throw TelemetryConformanceFailure("Metrics fixtures require a normalized measurement reader")
            }
            metrics.counter("bytes", options: InstrumentOptions(description: "Encoded bytes", unit: "By"))
                .add(12, attributes: ["direction": "out"])
            let active = metrics.upDownCounter("active")
            active.add(1)
            active.add(-1)
            let histogram = metrics.histogram("duration", options: HistogramOptions(unit: "ms", boundaries: [1, 10]))
            await fixture.context.startSpan(SpanOptions(name: "measured")) { span in
                histogram.record(5, attributes: ["method": "read"], context: span)
            }
            let measurements = try await getMetrics()
            try ok(measurements.map { "\($0.kind.rawValue) \($0.name) \($0.value)" } == [
                "counter bytes 12.0", "upDownCounter active 1.0", "upDownCounter active -1.0", "histogram duration 5.0",
            ], "Expected the four measurements in order; got \(measurements)")
            try strictEqual(measurements[0].attributes, ["direction": "out"])
            try strictEqual(measurements[0].description, "Encoded bytes")
            try strictEqual(measurements[0].unit, "By")
            try strictEqual(measurements[3].boundaries, [1, 10])
            try strictEqual(measurements[3].context, try findSpan(try await fixture.getSpans(), "measured").context)
        },

        // Swift: upstream also passes Proxy attributes and options that throw on read. Swift values cannot.
        createCase(factory, "metrics", "copies inputs and suppresses invalid measurements atomically") { fixture in
            guard let metrics = fixture.metrics else { return }
            guard let getMetrics = fixture.getMetrics else {
                throw TelemetryConformanceFailure("Metrics fixtures require a normalized measurement reader")
            }
            var boundaries: [Double] = [1, 10]
            var options = HistogramOptions(description: "Original", boundaries: boundaries)
            let histogram = metrics.histogram("snapshot", options: options)
            boundaries.append(100)
            options.description = "Changed"
            var attributes: SpanAttributes = ["tags": .stringArray(["original"])]
            histogram.record(-1, attributes: attributes)
            attributes["tags"] = .stringArray(["original", "changed"])
            let counter = metrics.counter("invalid")
            for value in [Double.nan, .infinity, -.infinity, -1] { counter.add(value) }
            metrics.histogram("bad-boundaries", options: HistogramOptions(boundaries: [2, 1])).record(1)
            let measurements = try await getMetrics()
            try strictEqual(measurements.count, 1)
            try strictEqual(measurements.first?.attributes, ["tags": .stringArray(["original"])])
            try strictEqual(measurements.first?.boundaries, [1, 10])
            try strictEqual(measurements.first?.description, "Original")
            try strictEqual(measurements.first?.context, nil)
        },

        createCase(factory, "links", "records initial and late links without changing parents") { fixture in
            var target: (any TelemetrySpan)?
            await fixture.context.startSpan(SpanOptions(name: "target")) { span in target = span }
            guard let targetSpan = target else { throw TelemetryConformanceFailure("Expected target span") }
            var attributes: SpanAttributes = ["reason": .stringArray(["initial"])]
            await fixture.context.startSpan(SpanOptions(
                name: "linked", links: [SpanLink(context: targetSpan, attributes: attributes)]
            )) { span in
                attributes["reason"] = .stringArray(["initial", "mutated"])
                span.addLink(SpanLink(context: targetSpan, attributes: ["reason": "late"]))
                span.addLink(SpanLink(context: noopTelemetryContext))
            }
            let spans = try await fixture.getSpans()
            let linked = try findSpan(spans, "linked")
            try strictEqual(linked.parentId, nil)
            try strictEqual(linked.parentContext, nil)
            let targetContext = try findSpan(spans, "target").context
            try strictEqual(linked.links, [
                RecordedTelemetryLink(context: targetContext, attributes: ["reason": .stringArray(["initial"])]),
                RecordedTelemetryLink(context: targetContext, attributes: ["reason": "late"]),
            ])
        },

        // Swift: upstream also adds links and link attributes that throw on read, which Swift values cannot.
        createCase(factory, "links", "suppresses malformed links atomically and ignores settled sources") { fixture in
            var source: (any TelemetrySpan)?
            await fixture.context.startSpan(SpanOptions(name: "link-source")) { span in source = span }
            guard let sourceSpan = source else { throw TelemetryConformanceFailure("Expected source span") }
            sourceSpan.addLink(SpanLink(context: sourceSpan))
            try strictEqual(try findSpan(try await fixture.getSpans(), "link-source").links, [])
        },

        createCase(factory, "propagation", "roundtrips parent identity through JSON without retaining the carrier") { fixture in
            guard let propagation = fixture.propagation else { return }
            try await fixture.context.startSpan(SpanOptions(name: "sender")) { span in
                guard let carrier = propagation.inject(span) else {
                    throw TelemetryConformanceFailure("Expected a carrier for the sender span")
                }
                var wire = try throughJSON(carrier)
                let parent = propagation.extract(wire)
                for key in wire.keys { wire[key] = "mutated" }
                _ = await parent.startSpan(SpanOptions(name: "receiver")) { _ in 42 }
                try strictEqual(propagation.inject(span), carrier)
            }
            let spans = try await fixture.getSpans()
            try strictEqual(try findSpan(spans, "receiver").parentContext, try findSpan(spans, "sender").context)
        },

        // Swift: upstream also extracts a carrier that throws on read, which a Swift dictionary cannot.
        createCase(factory, "propagation", "unknown and unreadable carriers produce recorded roots") { fixture in
            guard let propagation = fixture.propagation else { return }
            try strictEqual(propagation.inject(noopTelemetryContext), nil)
            let carriers: [TelemetryCarrier?] = [nil, [:], ["unknown": "format"]]
            for (index, carrier) in carriers.enumerated() {
                var result = 0
                await propagation.extract(carrier).startSpan(SpanOptions(name: "fallback-\(index)")) { _ in result = 42 }
                try strictEqual(result, 42)
            }
            for span in try await fixture.getSpans() { try strictEqual(span.parentContext, nil) }
        },

        createCase(factory, "propagation", "propagates across fresh adapters and multiple hops") { fixture in
            guard let propagation = fixture.propagation else { return }
            try await withFixture(factory) { receiver in
                try await withFixture(factory) { worker in
                    guard let receiverPropagation = receiver.propagation, let workerPropagation = worker.propagation else {
                        throw TelemetryConformanceFailure("Expected propagation on each fixture")
                    }
                    var senderCarrier: TelemetryCarrier?
                    await fixture.context.startSpan(SpanOptions(name: "sender")) { span in
                        senderCarrier = propagation.inject(span)
                    }
                    guard let sent = senderCarrier else { throw TelemetryConformanceFailure("Expected a sender carrier") }
                    var receiverCarrier: TelemetryCarrier?
                    await receiverPropagation.extract(try throughJSON(sent)).startSpan(SpanOptions(name: "receiver")) { span in
                        receiverCarrier = receiverPropagation.inject(span)
                    }
                    guard let received = receiverCarrier else {
                        throw TelemetryConformanceFailure("Expected a receiver carrier")
                    }
                    await workerPropagation.extract(try throughJSON(received)).startSpan(SpanOptions(name: "worker")) { _ in }
                    try strictEqual(try findSpan(try await receiver.getSpans(), "receiver").parentContext, sent)
                    try strictEqual(try findSpan(try await worker.getSpans(), "worker").parentContext, received)
                }
            }
        },

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
