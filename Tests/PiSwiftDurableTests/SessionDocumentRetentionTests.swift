// The Session's document cache is bounded by use: unattached documents leave it after the retention period and load
// from Storage again; documents with a watch or a document state never leave it (upstream
// session-document-retention.test.ts).
import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

private struct RetentionCounter: Codable, Sendable, Equatable { var count: Int }
private struct RetentionEvent: Codable, Sendable, Equatable { var seq: Int }
private struct RetentionMigrated: Codable, Sendable, Equatable { var count: Int; var migrated: Bool }
private struct RetentionVersioned: Codable, Sendable, Equatable { var count: Int; var v2: Bool? }
private enum RetentionFailure: Error { case checkpoint }

private let CounterDoc = try! ConversationDocToken<RetentionCounter>(kind: "test.retention.counter", version: 1, fork: .initial,
    initial: { RetentionCounter(count: 0) })
private let RewindableDoc = try! RewindableConversationDocToken<RetentionCounter>(kind: "test.retention.rewindable", version: 1,
    fork: .asOf, initial: { RetentionCounter(count: 0) })
/// A third-party conversation family: one member per event.
private let EventDoc = try! ConversationDocFamilyToken<RetentionEvent, Int>(kind: "test.retention.event", version: 1, fork: .initial,
    initial: { RetentionEvent(seq: $0) })
private let SessionCounterDoc = try! SessionDocToken<RetentionCounter>(kind: "test.retention.session-counter", version: 1,
    initial: { RetentionCounter(count: 0) })
/// A session document whose checkpoint predicate throws, so the commit that changes it fails while it settles.
private let Failing = try! SessionDocToken<RetentionCounter>(kind: "test.retention.failing", version: 1,
    initial: { RetentionCounter(count: 0) }, checkpointWhen: { _, _, _ in throw RetentionFailure.checkpoint })
/// A conversation document any Harness test can read.
private let TestDoc = try! ConversationDocToken<RetentionCounter>(kind: "test.retention.harness", version: 1, fork: .initial,
    initial: { RetentionCounter(count: 0) })

/// A controllable millisecond clock.
private final class RetentionClock: Sendable {
    private let state = Mutex<Int64>(1_000)
    var now: Int64 { state.withLock { $0 } }
    func advance(_ ms: Int64) { state.withLock { $0 += ms } }
}
/// A retention a test changes while the Session runs.
private final class RetentionSetting: Sendable {
    private let state: Mutex<DocumentRetention?>
    init(_ value: DocumentRetention?) { state = Mutex(value) }
    var value: DocumentRetention? { state.withLock { $0 } }
    func set(_ value: DocumentRetention?) { state.withLock { $0 = value } }
}

private struct RetentionSession {
    let storage: ControlledStorage
    let session: Session
    let clock: RetentionClock
    var sizes: DocumentCacheSizes { session.documentCacheSizes }
}

/// A Session with a controllable clock and retention.
private func open(_ retention: DocumentRetention?, timer: @escaping SessionTimer = sessionTaskTimer) -> RetentionSession {
    let clock = RetentionClock(), storage = ControlledStorage()
    let session = Session(storage: storage, now: { clock.now }, documentRetention: { retention }, timer: timer)
    return RetentionSession(storage: storage, session: session, clock: clock)
}

/// Let the line run what is queued on it: an eviction job, then return.
private func settleLine(_ session: Session) async throws {
    try await session.readOnLine {}
}

private func bump(_ session: Session, _ conversationId: ConversationID, by: Int = 1) async throws {
    try await session.commit({ tx in
        let draft = try await tx.doc(CounterDoc, conversationId: conversationId)
        try draft.set("count", .number(Double((try draft.get("count")?.intValue ?? 0) + by)))
    }, context: .background)
}

/// Until the cache holds no document, letting each queued eviction run.
private func untilEvicted(_ session: Session) async throws {
    try await eventually {
        try await settleLine(session)
        return session.documentCacheSizes.cached == 0
    }
}

@Suite struct SessionDocumentRetentionTests {
    // session-document-retention.test.ts:108
    @Test("evicts an unattached document once its retention passed, and loads it again with the same value")
    func evictsAfterRetention() async throws {
        let opened = open(60_000), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId, by: 3)
        #expect(opened.sizes.cached > 0)
        // Not yet: inside the retention period.
        opened.clock.advance(59_000)
        try await bump(session, conversationId, by: 0)
        try await settleLine(session)
        #expect(opened.sizes.cached > 0)
        // Past it, with no use since: the next commit evicts it.
        opened.clock.advance(61_000)
        try await session.commit({ _ in }, context: .background)
        try await session.commit({ tx in _ = try await tx.doc(SessionCounterDoc) }, context: .background)
        try await settleLine(session)
        let reads = await opened.storage.documentReadCount
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 3))
        #expect(await opened.storage.documentReadCount > reads)
        try await session.close(context: .background)
    }

    // :131
    @Test("evicts with retention 0 right after use, on the line") func evictsAtOnce() async throws {
        let session = open(0).session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        try await untilEvicted(session)
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 1))
        try await session.close(context: .background)
    }

    // :143
    @Test("never evicts a document a watch or a document state observes, and evicts it once the last detaches")
    func observersPin() async throws {
        let opened = open(1_000), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        let watch = try #require(try await session.watchDoc(CounterDoc, conversationId: conversationId, context: .background))
        let state = try #require(try await session.documentState(CounterDoc, conversationId: conversationId, context: .background))
        let seen = SessionTestLog<Int>()
        try watch.start { value, _, _ in seen.append(value?.count ?? -1) }
        opened.clock.advance(1_000_000)
        try await bump(session, conversationId)
        try await settleLine(session)
        // Still cached: a read long after its retention passed loads nothing from Storage.
        await state.waitUntilIdle()
        #expect(state.value?.count == 2)
        try await eventually { seen.values.contains(2) }
        let reads = await opened.storage.documentReadCount
        opened.clock.advance(1_000_000)
        try await session.commit({ tx in _ = try await tx.doc(SessionCounterDoc) }, context: .background)
        try await settleLine(session)
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 2))
        #expect(await opened.storage.documentReadCount == reads)
        _ = await watch.stop()
        opened.clock.advance(1_000_000)
        try await bump(session, conversationId)
        try await settleLine(session)
        await state.waitUntilIdle()
        #expect(state.value?.count == 3)
        state.dispose()
        opened.clock.advance(1_000_000)
        try await session.commit({ _ in }, context: .background)
        try await session.commit({ tx in _ = try await tx.doc(SessionCounterDoc) }, context: .background)
        try await settleLine(session)
        // The session document was just used; the counter is gone.
        #expect(opened.sizes.cached == 1)
        try await session.close(context: .background)
    }

    // :180
    @Test("never takes a tracker from a transaction that holds it") func transactionKeepsTracker() async throws {
        let opened = open(0), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        let inside = SessionTestGate(), release = SessionTestGate()
        let commit = Task {
            try await session.commit({ tx in
                let draft = try await tx.doc(CounterDoc, conversationId: conversationId)
                inside.release()
                await release.wait()
                try draft.set("count", .number(Double((try draft.get("count")?.intValue ?? 0) + 10)))
            }, context: .background)
        }
        await inside.wait()
        // Retention passes while the transaction holds the document; eviction waits on the line behind it.
        opened.clock.advance(1_000_000)
        release.release()
        try await commit.value
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 11))
        try await bump(session, conversationId)
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 12))
        try await session.close(context: .background)
    }

    // :204
    @Test("writes after a reload continue the stored deltas and bases") func reloadContinuesDeltas() async throws {
        let opened = open(0), session = opened.session
        let conversationId = try await createConversation(session)
        let before = await opened.storage.commits.count
        for _ in 0..<5 {
            try await bump(session, conversationId)
            try await settleLine(session)
        }
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 5))
        // Every bump after the first is a change of the same incarnation, never a second creation.
        let creations = await opened.storage.commits.dropFirst(before).flatMap { $0 }.filter { write in
            guard case .documentCreate(let record, _, _) = write else { return false }
            return record.kind == CounterDoc.definition.kind
        }
        #expect(creations.count == 1)
        try await session.close(context: .background)
        // And a fresh Session over the same storage reads the same value.
        let reopened = Session(storage: await opened.storage.reopen(), now: { 1_000 }, documentRetention: { 0 })
        #expect(try await reopened.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 5))
        try await reopened.close(context: .background)
    }

    // :230
    @Test("keeps history and forks of rewindable documents after eviction") func rewindableAfterEviction() async throws {
        let session = open(0).session
        let conversationId = try await createConversation(session)
        let first = try await session.commit({ tx in
            try await tx.doc(RewindableDoc, conversationId: conversationId).set("count", 1)
            return try await tx.appendEntry(conversationId, value: EntryDraft(kind: "note")).id
        }, context: .background)
        try await settleLine(session)
        let second = try await session.commit({ tx in
            try await tx.doc(RewindableDoc, conversationId: conversationId).set("count", 2)
            return try await tx.appendEntry(conversationId, value: EntryDraft(kind: "note")).id
        }, context: .background)
        try await settleLine(session)
        #expect(try await session.snapshotAsOf(RewindableDoc, conversationId: conversationId, at: first, context: .background) == RetentionCounter(count: 1))
        #expect(try await session.snapshotAsOf(RewindableDoc, conversationId: conversationId, at: second, context: .background) == RetentionCounter(count: 2))
        let fork = try await session.commit({ tx in
            try await tx.forkConversation(conversationId, at: first, ownership: .ownerless()).id
        }, context: .background)
        try await settleLine(session)
        #expect(try await session.snapshot(RewindableDoc, conversationId: fork, context: .background) == RetentionCounter(count: 1))
        #expect(try await session.snapshot(RewindableDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 2))
        try await session.close(context: .background)
    }

    // :256
    @Test("bounds a third-party family with a member per event") func boundsFamily() async throws {
        let session = open(0).session
        let conversationId = try await createConversation(session)
        for seq in 0..<200 {
            try await session.commit({ tx in _ = try await tx.doc(EventDoc, conversationId: conversationId, key: String(seq), seed: seq) },
                                     context: .background)
        }
        try await untilEvicted(session)
        #expect(try await session.snapshot(EventDoc, conversationId: conversationId, key: "123", context: .background) == RetentionEvent(seq: 123))
        try await session.close(context: .background)
    }

    // :272
    @Test("keeps the cache of a long-lived Session bounded across many conversations") func boundsManyConversations() async throws {
        let opened = open(10_000), session = opened.session
        for _ in 0..<300 {
            let conversationId = try await createConversation(session)
            try await bump(session, conversationId)
            opened.clock.advance(1_000)
        }
        try await settleLine(session)
        // Only what was used in the last 10 s, about ten conversations' worth.
        #expect(opened.sizes.cached <= 12)
        try await session.close(context: .background)
    }

    // :303. Upstream's "never changes the outcome of a commit when the clock throws" has no counterpart: `now` cannot throw.
    @Test("evicts after a commit whose settlement fails") func evictsAfterFailedSettlement() async throws {
        let opened = open(10_000), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        // Created first: the predicate runs only for changes to an existing document.
        try await session.commit({ tx in _ = try await tx.doc(Failing) }, context: .background)
        try await settleLine(session)
        // Retention passes inside a commit whose checkpoint predicate throws while it settles.
        await #expect(throws: RetentionFailure.self) {
            try await session.commit({ tx in
                let draft = try await tx.doc(Failing)
                try draft.set("count", .number(Double((try draft.get("count")?.intValue ?? 0) + 1)))
                opened.clock.advance(1_000_000)
            }, context: .background)
        }
        #expect(opened.sizes.cached == 0)
        try await session.close(context: .background)
    }

    // Swift only: the other outcome upstream sweeps after, a commit whose callback throws.
    @Test("evicts after a commit whose callback throws") func evictsAfterRejectedCommit() async throws {
        let opened = open(10_000), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        await #expect(throws: RetentionFailure.self) {
            try await session.commit({ tx in
                _ = try await tx.doc(SessionCounterDoc)
                opened.clock.advance(1_000_000)
                throw RetentionFailure.checkpoint
            }, context: .background)
        }
        #expect(opened.sizes.cached == 0)
        try await session.close(context: .background)
    }

    // :320
    @Test("evicts promptly once the retention is shortened") func shortenedRetention() async throws {
        let retention = RetentionSetting(600_000), clock = RetentionClock()
        let session = Session(storage: ControlledStorage(), now: { clock.now }, documentRetention: { retention.value })
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        retention.set(0)
        clock.advance(2_000)
        // A read, no commit: the sweep pending for ten minutes from now moves up.
        _ = try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background)
        try await untilEvicted(session)
        try await session.close(context: .background)
    }

    // :342
    @Test("does not keep a replacement cached for an observer of the retired incarnation") func retiredObserverPinsNothing() async throws {
        let session = open(0).session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        let state = try #require(try await session.documentState(CounterDoc, conversationId: conversationId, context: .background))
        try await session.commit({ tx in try await tx.retireDoc(CounterDoc, conversationId: conversationId) }, context: .background)
        await state.waitUntilIdle()
        #expect(state.value == nil)
        // A retired incarnation never changes again: its observer keeps its last value but pins nothing.
        #expect(session.documentCacheSizes.attached == 0)
        try await bump(session, conversationId, by: 5)
        try await untilEvicted(session)
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 5))
        state.dispose()
        try await session.close(context: .background)
    }

    // :358
    @Test("leaves no pin behind when an observer's load loses a race with close") func attachRacesClose() async throws {
        let opened = open(0), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        try await untilEvicted(session)
        let gate = await opened.storage.holdFindDocument()
        let attaching = Task { try await session.documentState(CounterDoc, conversationId: conversationId, context: .background) }
        await gate.waitUntilEntered()
        let closing = Task { try await session.close(context: .background) }
        try await eventually { session.isClosing }
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await attaching.value }
        try await closing.value
        let sizes = session.documentCacheSizes
        #expect(sizes.cached == 0 && sizes.idle == 0 && sizes.attached == 0)
    }

    // :375
    @Test("evicts on its timer without a commit, and tolerates a detach called twice") func evictsOnTimer() async throws {
        let session = Session(storage: ControlledStorage(), now: { Int64(Date().timeIntervalSince1970 * 1000) },
                              documentRetention: { 20 })
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        let state = try #require(try await session.documentState(CounterDoc, conversationId: conversationId, context: .background))
        state.dispose()
        state.dispose()
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while session.documentCacheSizes.cached > 0, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.documentCacheSizes.cached == 0)
        try await session.close(context: .background)
    }

    // :390
    @Test("migrates a document again after its eviction") func migratesAgain() async throws {
        let v1 = try SessionDocToken<RetentionCounter>(kind: "test.retention.migrating", version: 1, initial: { RetentionCounter(count: 1) })
        let migrations = SessionTestLog<Int>()
        let v2 = try SessionDocToken<RetentionMigrated>(kind: "test.retention.migrating", version: 2,
            initial: { RetentionMigrated(count: 0, migrated: true) },
            migrate: { value, _ in
                migrations.append(1)
                return ["count": value["count"] ?? 0, "migrated": true]
            })
        let session = open(0).session
        try await session.commit({ tx in _ = try await tx.doc(v1) }, context: .background)
        try await settleLine(session)
        #expect(try await session.snapshot(v2, context: .background) == RetentionMigrated(count: 1, migrated: true))
        try await settleLine(session)
        #expect(try await session.snapshot(v2, context: .background) == RetentionMigrated(count: 1, migrated: true))
        // Not written back, so each cold load migrates again.
        #expect(migrations.count == 2)
        try await session.close(context: .background)
    }

    // :420. Swift's `DocumentRetention` holds no NaN or string; a negative count is what is not a number of milliseconds.
    // Tests run in parallel in one process, so this one does not swap the process-wide default as upstream does: it
    // expects whatever this run's default keeps.
    @Test("treats a retention that is not a number of milliseconds as the default, and forever as never")
    func invalidAndForeverRetention() async throws {
        // The suite's second run sets the default through the environment (FLEET_FORK.md).
        let forced = ProcessInfo.processInfo.environment["PI_DURABLE_DOCUMENT_RETENTION_MS"].flatMap { Int64($0) }
        #expect(defaultDocumentRetention == .milliseconds(forced ?? 600_000))
        #expect(documentRetention(nil) == defaultDocumentRetention)
        #expect(documentRetention(.milliseconds(-5)) == defaultDocumentRetention)
        #expect(documentRetention(.forever) == .forever)
        #expect(documentRetention(0) == .milliseconds(0))
        // Used at 1 000, checked at 61 000: the default keeps it past 60 s (ten minutes, unless this run forces another).
        let keptByDefault = defaultDocumentRetention.ms.map { $0 > 60_000 } ?? true
        let opened = open(.milliseconds(-5)), session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        opened.clock.advance(60_000)
        try await session.commit({ _ in }, context: .background)
        try await settleLine(session)
        #expect(opened.sizes.cached == (keptByDefault ? 1 : 0))
        try await session.close(context: .background)
        let forever = open(.forever)
        let id = try await createConversation(forever.session)
        try await bump(forever.session, id)
        forever.clock.advance(1_000_000_000_000_000)
        try await forever.session.commit({ _ in }, context: .background)
        try await settleLine(forever.session)
        #expect(forever.sizes.cached == 1)
        try await forever.session.close(context: .background)
    }

    // :446. Upstream replaces `setTimeout` with one whose timers have no `unref`; here the Session's timer declines.
    @Test("keeps no timer where the host declines timers, and evicts on commits") func declinedTimers() async throws {
        let timers = SessionTestLog<Int64>()
        let opened = open(1_000, timer: { delay, _ in timers.append(delay); return nil })
        let session = opened.session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        try await bump(session, conversationId)
        // Tried once, then never again.
        #expect(timers.count <= 1)
        opened.clock.advance(10_000)
        try await session.commit({ _ in }, context: .background)
        try await settleLine(session)
        #expect(opened.sizes.cached == 0)
        #expect(timers.count <= 1)
        try await session.close(context: .background)
    }

    // :472. Upstream pins the process-wide default to ten minutes first; here the setting starts at ten minutes.
    @Test("follows a Harness settings change at the next use") func followsHarnessSettings() async throws {
        let setup = HarnessChatSetup(settings: HarnessSettings(documentRetentionMs: 600_000))
        let opened = try await openChat(setup: setup)
        try await opened.root.commit({ tx in
            let draft = try await tx.doc(TestDoc, conversationId: opened.root.id)
            try draft.set("count", .number(Double((try draft.get("count")?.intValue ?? 0) + 1)))
        }, context: .background)
        let session = opened.harness.session
        #expect(session.documentCacheSizes.cached > 0)
        setup.updateSettings { $0.documentRetentionMs = 0 }
        _ = try await opened.harness.snapshot(TestDoc, conversationId: opened.root.id, context: .background)
        try await untilEvicted(session)
        try await opened.harness.close(context: .background)
    }

    // :491. Each step waits for its own update event instead of 5 ms, so the outputs never coalesce.
    @Test("gives the same events with documents evicted right after use as with documents kept") func sameEvents() async throws {
        func run(_ retention: DocumentRetention) async throws -> [JSONValue] {
            let setup = HarnessChatSetup(settings: HarnessSettings(progress: .init(outputIntervalMs: 0), documentRetentionMs: retention))
            let log = HarnessEventLog()
            try installHarnessTool(harnessTestTool("steps", execute: { _, api, _ in
                for (index, step) in ["a\n", "b\n", "c\n"].enumerated() {
                    try api.output(.text(step), nil)
                    try await eventually { log.types.filter { $0 == "tool_execution_update" }.count > index }
                }
                return .init(output: [])
            }), setup: setup)
            setup.models.setResponses([.message(try toolCalls([("steps", [:], "s1")])), .message(chatAssistant("done"))])
            let opened = try await openChat(setup: setup)
            let stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
            try log.start(stream)
            let input = try await generationSubmit(opened, "go")
            _ = try await input.wait(context: .background)
            try await log.waitForDone(input.id)
            try await opened.harness.waitForIdle(context: .background)
            _ = await stream.stop()
            try await opened.harness.close(context: .background)
            // Ids and times differ between runs; the sequence of event types and tool outputs must not.
            return log.events.map { event in
                event["type"] == "tool_execution_update" ? .object(["update": event["output"] ?? .null]) : event["type"] ?? .null
            }
        }
        let evicting = try await run(0), keeping = try await run(600_000)
        #expect(evicting.filter { $0["update"] != nil }.count == 3)
        #expect(evicting == keeping)
    }

    // :540
    @Test("keeps a reloaded newer version cached while an observer of the older one is attached") func olderObserverPins() async throws {
        let v1 = try SessionDocToken<RetentionCounter>(kind: "test.retention.versioned", version: 1, initial: { RetentionCounter(count: 3) })
        let v2 = try SessionDocToken<RetentionVersioned>(kind: "test.retention.versioned", version: 2,
            initial: { RetentionVersioned(count: 0, v2: true) },
            migrate: { value, _ in ["count": value["count"] ?? 0, "v2": true] })
        let opened = open(0), session = opened.session
        try await session.commit({ tx in _ = try await tx.doc(v1) }, context: .background)
        let state = try #require(try await session.documentState(v1, context: .background))
        #expect(try await session.snapshot(v2, context: .background) == RetentionVersioned(count: 3, v2: true))
        try await settleLine(session)
        #expect(opened.sizes.cached == 1)
        state.dispose()
        try await untilEvicted(session)
        try await session.close(context: .background)
    }

    // :567. Each load yields instead of a zero-delay timer.
    @Test("queues one sweep job, not one per document, while a commit holds the line") func oneSweepJob() async throws {
        let session = open(0).session
        var conversationIds: [ConversationID] = []
        for _ in 0..<50 {
            let id = try await createConversation(session)
            try await bump(session, id)
            conversationIds.append(id)
        }
        try await untilEvicted(session)
        let before = session.documentCacheSizes.sweeps
        // One commit loads 50 evicted documents from storage, each touched as it loads; the sweep job stays pending while
        // the line is held.
        let ids = conversationIds
        try await session.commit({ tx in
            for id in ids {
                let draft = try await tx.doc(CounterDoc, conversationId: id)
                try draft.set("count", .number(Double((try draft.get("count")?.intValue ?? 0) + 1)))
                await Task.yield()
            }
        }, context: .background)
        try await settleLine(session)
        #expect(session.documentCacheSizes.cached == 0)
        #expect(session.documentCacheSizes.sweeps - before <= 2)
        try await session.close(context: .background)
    }

    // Swift only: snapshots read the cache off the line and note their use while commits and sweeps run on it.
    @Test("keeps every value when snapshots off the line race commits and evictions") func concurrentUse() async throws {
        let session = open(0).session
        let conversationId = try await createConversation(session)
        try await bump(session, conversationId)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<100 { try await bump(session, conversationId) } }
            for _ in 0..<4 {
                group.addTask {
                    var last = 0
                    for _ in 0..<200 {
                        let count = try #require(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background)).count
                        #expect(count >= last)
                        last = count
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await session.snapshot(CounterDoc, conversationId: conversationId, context: .background) == RetentionCounter(count: 101))
        try await untilEvicted(session)
        try await session.close(context: .background)
    }
}
