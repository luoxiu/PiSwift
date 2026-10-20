import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// One Storage call a hook sees: its method, a scan's limit and cursor, and a read's context.
private struct StorageCall: Sendable {
    let method: String
    var limit: Int? = nil
    var cursor: Cursor? = nil
    var context: ChordContext? = nil
}
/// Storage that runs `hook` before each call to `base`, which may hold or fail it.
private final class HookedStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    let hook: @Sendable (StorageCall) async throws -> Void
    init(_ base: any DurableStorage, hook: @escaping @Sendable (StorageCall) async throws -> Void) { self.base = base; self.hook = hook }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        try await hook(.init(method: "commit")); return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { try await hook(.init(method: "mintId")); return try await base.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await hook(.init(method: "conversation", context: context)); return try await base.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await hook(.init(method: "scanConversations", limit: limit, cursor: cursor, context: context))
        return try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await hook(.init(method: "entry", context: context)); return try await base.entry(id, context: context)
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await hook(.init(method: "entry", context: context)); return try await base.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await hook(.init(method: "findLatestHeadMarker", context: context))
        return try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await hook(.init(method: "scanEntries", limit: limit, cursor: cursor, context: context))
        return try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await hook(.init(method: "task", context: context)); return try await base.task(id, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await hook(.init(method: "scanTasks", limit: limit, cursor: cursor, context: context))
        return try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await hook(.init(method: "submission", context: context)); return try await base.submission(id, context: context)
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await hook(.init(method: "scanSubmissions", limit: limit, cursor: cursor, context: context))
        return try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await hook(.init(method: "submissionByRequest", context: context))
        return try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await hook(.init(method: "findDocument", context: context)); return try await base.findDocument(address, at: at, context: context)
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await hook(.init(method: "document", context: context)); return try await base.document(id, at: at, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await hook(.init(method: "scanDocuments", limit: limit, cursor: cursor, context: context))
        return try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws { try await hook(.init(method: "close")); try await base.close(context: context) }
}

/// Fails each Storage method named in `failing` once, with `DiskGone`. A scan of entries with a limit above 1 is the
/// context read's scan of its range, off the Session line; `heldRange` holds it until released.
private final class FailingCalls: Sendable {
    let base = ControlledStorage()
    private let failing = Mutex<Set<String>>([])
    private let held = Mutex<(entered: HarnessChatSignal, release: HarnessChatSignal)?>(nil)
    func fail(_ method: String) { _ = failing.withLock { $0.insert(method) } }
    func holdRange() -> (entered: HarnessChatSignal, release: HarnessChatSignal) {
        let gate = (entered: HarnessChatSignal(), release: HarnessChatSignal())
        held.withLock { $0 = gate }
        return gate
    }
    var storage: HookedStorage {
        HookedStorage(base) { [self] call in
            var method = call.method
            if call.method == "scanEntries" {
                guard (call.limit ?? 0) > 1 else { return }
                if let gate = held.withLock({ $0 }) { gate.entered.signal(); await gate.release.wait() }
                method = "scanRange"
            }
            if failing.withLock({ $0.remove(method) }) != nil { throw DiskGone() }
        }
    }
}

/// Waits for its signal, records that it saw it, and ends `aborted` through its abort handler.
private func waiting(_ signals: SessionTestLog<String>) -> HarnessTestTask {
    harnessOneStep("test.waiting", run: { _, runtime, _ in
        _ = try? await harnessToolAwaitAbort(runtime.context)
        signals.append("aborted")
    }, abort: { _, runtime, context in
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
    })
}
private struct Started {
    let harness: Harness, root: Conversation, reports: HarnessReports, signals: SessionTestLog<String>, task: HarnessTestTask
}
private func started(_ storage: any DurableStorage) async throws -> Started {
    let signals = SessionTestLog<String>(), task = waiting(signals)
    let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(task)])
    return Started(harness: opened.harness, root: try await opened.harness.root(context: .background),
                   reports: opened.reports, signals: signals, task: task)
}
private func note(_ root: Conversation) async throws -> EntryRecord {
    try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "note")) }, context: .background)
}
private func running(_ harness: Harness, _ id: TaskID) async throws {
    try await eventually { try await harness.getTask(id: id, context: .background)?.state.status == "running" }
}
/// Whether `closed` stays pending for a few scheduler turns.
private func stillOpen(_ harness: Harness) async throws -> Bool {
    let ended = Mutex(false)
    let watcher = Task { _ = await harness.closed; ended.withLock { $0 = true } }
    try await Task.sleep(for: .milliseconds(20))
    defer { watcher.cancel() }
    return !ended.withLock { $0 }
}
private func reported(_ reports: HarnessReports) -> [String] { reports.values.map { String(describing: $0) } }

/// Port of upstream `test/harness-storage-failure.test.ts`.
@Suite struct HarnessStorageFailureTests {
    @Test func endsEverythingWithTheFirstErrorTheCallLaterCallsWaitsWatchesStreamsRunningTasks() async throws {
        let storage = ControlledStorage(), opened = try await started(storage), harness = opened.harness, root = opened.root
        let id = try await harnessStart(root, opened.task)
        try harness.resume()
        try await running(harness, id)
        let task = Task { try await harness.waitForTask(id: id, context: .background) }
        let idle = Task { try await harness.waitForIdle(context: .background) }
        let watch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        let stream = try await harness.watchEvents(conversationId: root.id, context: .background)
        try stream.start { _, _ in }

        let failure = DiskGone()
        await storage.failNextCommit(failure)
        // The call that hit it gets the storage error itself.
        await #expect(throws: failure) { _ = try await note(root) }

        await expectSessionFailed(cause: failure) { _ = try await task.value }
        await expectSessionFailed(cause: failure) { try await idle.value }
        #expect(watchFailed(await watch.closed, failure))
        #expect(watchFailed(await stream.closed, failure))
        // Every later call, and a wait that starts now.
        await expectSessionFailed(cause: failure) { _ = try await harness.getTask(id: id, context: .background) }
        await expectSessionFailed(cause: failure) { try await harness.waitForIdle(context: .background) }
        await expectSessionFailed(cause: failure) { _ = try await root.submit(.input(content: .text("x")), context: .background) }
        #expect(endedFailed(await harness.closed, failure))
        #expect(opened.signals.values == ["aborted"])
        #expect(reported(opened.reports) == ["disk gone"])
        try await harness.close(context: .background)
    }

    @Test func failsItFromAReadOffTheSessionLineAsAContextReadMakes() async throws {
        let calls = FailingCalls(), opened = try await started(calls.storage)
        _ = try await note(opened.root)
        calls.fail("scanRange")
        await #expect(throws: DiskGone()) { _ = try await opened.root.context(context: .background) }
        #expect(endedFailed(await opened.harness.closed, DiskGone()))
        #expect(reported(opened.reports) == ["disk gone"])
        try await opened.harness.close(context: .background)
    }

    @Test func endsStorageCallsUnderwayWithSessionFailedAndClosesOnceTheyHaveSettled() async throws {
        let calls = FailingCalls(), opened = try await started(calls.storage), root = opened.root
        _ = try await note(root)
        let gate = calls.holdRange()
        let reading = Task { try await root.context(context: .background) }
        await gate.entered.wait()
        // Another call fails the Session while the context read is underway.
        calls.fail("mintId")
        await #expect(throws: DiskGone()) { _ = try await note(root) }
        #expect(try await stillOpen(opened.harness))
        // The read succeeds at the backend, yet its caller gets the failure: nothing it read is used.
        gate.release.signal()
        await expectSessionFailed(cause: DiskGone()) { _ = try await reading.value }
        #expect(endedFailed(await opened.harness.closed, DiskGone()))
        try await opened.harness.close(context: .background)
    }

    @Test func closesTheBackendOnlyAfterAPagedReadUnderwayWhichCannotStartAnotherPage() async throws {
        let pages = SessionTestLog<String>(), firstPage = HarnessChatSignal(), releaseFirst = HarnessChatSignal()
        let storage = HookedStorage(ControlledStorage()) { call in
            if call.method == "scanEntries", (call.limit ?? 0) > 1 {
                pages.append(call.cursor == nil ? "first" : "next")
                if call.cursor == nil { firstPage.signal(); await releaseFirst.wait() }
            }
            if call.method == "close" { pages.append("close") }
        }
        let opened = try await started(storage), root = opened.root, harness = opened.harness
        // More entries than one page of the context read.
        _ = try await root.commit({ tx in for _ in 0..<300 { _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "note")) } }, context: .background)
        let reading = Task { try await root.context(context: .background) }
        await firstPage.wait()
        let closing = Task { try await harness.close(context: .background) }
        // Release the page once close has reached the guard, which then refuses the next page.
        try await eventually { (harness.storage as? GuardedStorage)?.isClosing == true }
        releaseFirst.signal()
        do { _ = try await reading.value; Issue.record("The read survived close") }
        catch { #expect(String(describing: error).contains("is closed")) }
        try await closing.value
        #expect(pages.values == ["first", "close"])
        #expect(endedClosed(await harness.closed))
    }

    @Test func failsItWhenStorageCannotCloseAndAnEarlierFailureStaysTheCause() async throws {
        let closeError = TestFailure("close failed")
        let healthy = try await started(HarnessFailingCloseStorage(base: ControlledStorage()))
        await #expect(throws: closeError) { try await healthy.harness.close(context: .background) }
        #expect(endedFailed(await healthy.harness.closed, closeError))
        #expect(reported(healthy.reports) == ["close failed"])

        let base = ControlledStorage(), failed = try await started(HarnessFailingCloseStorage(base: base))
        await base.failNextCommit(DiskGone())
        await #expect(throws: DiskGone()) { _ = try await note(failed.root) }
        #expect(endedFailed(await failed.harness.closed, DiskGone()))
        #expect(reported(failed.reports) == ["disk gone"])
    }

    @Test func rejectsTheHarnessesOwnCallsWithSessionFailedAfterAFailure() async throws {
        let storage = ControlledStorage(), opened = try await started(storage), harness = opened.harness
        await storage.failNextCommit(DiskGone())
        await #expect(throws: DiskGone()) { _ = try await note(opened.root) }
        await expectSessionFailed(cause: DiskGone()) { try harness.resume() }
        await expectSessionFailed(cause: DiskGone()) { _ = try await harness.root(context: .background) }
        await expectSessionFailed(cause: DiskGone()) { _ = try await harness.conversation(id: opened.root.id, context: .background) }
        await expectSessionFailed(cause: DiskGone()) {
            _ = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        }
        try await harness.close(context: .background)
    }

    @Test func endsWhatATaskHoldsWithSessionFailedNotAsCancelledByItsSignal() async throws {
        let ends = SessionTestLog<String>(), watching = HarnessChatSignal()
        let watcher = harnessOneStep("test.watcher", run: { _, runtime, context in
            let doc = try #require(try await runtime.watchDoc(LiveDoc, conversationId: runtime.conversationId, context: context))
            let handle = try #require(try await runtime.conversation(runtime.conversationId, context: context))
            let idle = Task { () -> String in
                do { try await handle.waitForIdle(context: context); return "resolved" }
                catch { return error is SessionFailed ? "SessionFailed" : String(describing: error) }
            }
            watching.signal()
            let end = await doc.closed
            ends.append(watchFailed(end, DiskGone()) ? "session_failed" : "\(end)")
            ends.append(await idle.value)
        }, abort: { _, _, _ in })
        let storage = ControlledStorage()
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(watcher)])
        let root = try await opened.harness.root(context: .background)
        _ = try await harnessStart(root, watcher)
        try opened.harness.resume()
        await watching.wait()
        await storage.failNextCommit(DiskGone())
        await #expect(throws: DiskGone()) { _ = try await note(root) }
        _ = await opened.harness.closed
        #expect(ends.values == ["session_failed", "SessionFailed"])
        try await opened.harness.close(context: .background)
    }

    @Test func failsItFromAFailedIDMint() async throws {
        let calls = FailingCalls(), opened = try await started(calls.storage)
        calls.fail("mintId")
        await #expect(throws: DiskGone()) { _ = try await note(opened.root) }
        #expect(endedFailed(await opened.harness.closed, DiskGone()))
        try await opened.harness.close(context: .background)
    }

    @Test func doesNotCommitWhatACallbackDidAfterItCaughtAFailedRead() async throws {
        let calls = FailingCalls(), opened = try await started(calls.storage), root = opened.root
        let written = await calls.base.admittedCommits.count
        calls.fail("task")
        await expectSessionFailed(cause: DiskGone()) {
            _ = try await root.commit({ tx in
                _ = try? await tx.task(try TaskID(1))
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "note"))
            }, context: .background)
        }
        #expect(await calls.base.admittedCommits.count == written)
        try await opened.harness.close(context: .background)
    }

    @Test func failsItForAStorageRequestErrorFromACommitWhoseEffectIsUnknown() async throws {
        let storage = ControlledStorage(), opened = try await started(storage)
        let rejection = StorageRequestError("bad batch")
        await storage.failNextCommit(rejection)
        await #expect(throws: rejection) { _ = try await note(opened.root) }
        #expect(endedFailed(await opened.harness.closed, rejection))
        try await opened.harness.close(context: .background)
    }

    @Test func failsOnlyTheCallForAnInvalidRequest() async throws {
        let opened = try await started(MemoryStorage()), root = opened.root, harness = opened.harness
        let entry = try await note(root)
        let requests: [@Sendable () async throws -> Void] = [
            { _ = try await root.entries(limit: 10, cursor: ["after": "x"], context: .background) },
            {
                let page = try await root.entries(order: .ascending, limit: 1, context: .background)
                _ = try await root.entries(order: .descending, limit: 1, cursor: page.next ?? ["after": 1, "order": "ascending"], context: .background)
            },
            { _ = try await root.commit({ tx in try await tx.scanEntries(.init(conversationId: try ConversationID(999_999)), limit: 10) }, context: .background) },
            // `pi.live` keeps no history.
            { _ = try await documentReader(session: harness.session, storage: harness.storage).snapshotAsOf("pi.live", root.id, entry.id, .background) },
        ]
        for request in requests {
            do { try await request(); Issue.record("Expected StorageRequestError") }
            catch { #expect(error is StorageRequestError, "\(error)") }
        }
        _ = try await note(root)
        #expect(try await stillOpen(harness))
        #expect(opened.reports.values.isEmpty)
        try await harness.close(context: .background)
    }

    @Test func failsItForAThrowInItsOwnCommitListenersWhichWouldLeaveMemoryBehindStorage() async throws {
        let opened = try await started(ControlledStorage()), bug = TestFailure("listener bug")
        _ = try opened.harness.session.observeCommits { _, _ in throw bug }
        // The commit itself is durable and returns; the Session fails behind it.
        _ = try await note(opened.root)
        #expect(endedFailed(await opened.harness.closed, bug))
        #expect(reported(opened.reports) == ["listener bug"])
        try await opened.harness.close(context: .background)
    }

    @Test func failsItForAStorageErrorDuringAHostCloseBeforeTheBackendCloses() async throws {
        let storage = ControlledStorage(), opened = try await started(storage), harness = opened.harness, root = opened.root
        let held = await storage.holdCommits()
        await storage.failNextCommit(DiskGone())
        let committing = Task { try await note(root) }
        await held.waitUntilEntered()
        let closing = Task { try await harness.close(context: .background) }
        try await eventually { harness.tasks.closing }
        await held.release()
        await #expect(throws: DiskGone()) { _ = try await committing.value }
        try await closing.value
        #expect(endedFailed(await harness.closed, DiskGone()))
        #expect(reported(opened.reports) == ["disk gone"])
    }

    @Test func endsAnAbortThatJoinsARunIgnoringItsSignalAndAReentrantReportFindsTheSessionFailed() async throws {
        let release = HarnessChatSignal(), entered = HarnessChatSignal()
        let stubborn = harnessOneStep("test.stubborn", run: { _, _, _ in entered.signal(); await release.wait() }, abort: { _, _, _ in })
        let storage = ControlledStorage(), registry = Registry()
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(stubborn)]))
        let box = Mutex<Harness?>(nil), reentered = Mutex<Task<Void, any Error>?>(nil)
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
            onReport: { _ in
                reentered.withLock { task in
                    if task == nil, let harness = box.withLock({ $0 }) { task = Task { try await harness.waitForIdle(context: .background) } }
                }
            }), context: .background)
        box.withLock { $0 = harness }
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, stubborn)
        try harness.resume()
        await entered.wait()
        let held = await storage.holdCommits()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        await held.waitUntilEntered(); await held.release()
        // The abort mark commits and the abort joins the run, which ignores its signal; then the Session fails.
        try await eventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        await storage.failNextCommit(DiskGone())
        await #expect(throws: DiskGone()) { _ = try await note(root) }
        await expectSessionFailed(cause: DiskGone()) { _ = try await aborting.value }
        let reentry = try #require(reentered.withLock { $0 })
        await expectSessionFailed(cause: DiskGone()) { try await reentry.value }
        release.signal()
        try await harness.close(context: .background)
    }

    @Test func doesNotFailItForAReadItsCallerCancelled() async throws {
        let controller = AbortController(), cancelled = TestFailure("caller gave up")
        // The caller's context is marked by a value; wrappers may combine its signal with others.
        let marker = ChordContextKey<Bool>("cancelled read")
        let storage = HookedStorage(MemoryStorage()) { call in
            if call.method == "scanEntries", call.context?.value(marker) == true {
                controller.abort(cancelled)
                throw cancelled
            }
        }
        let opened = try await started(storage)
        let cancelling = ChordContext.background.withValue(true, for: marker).withAbortSignal(controller.signal)
        do { _ = try await opened.root.context(context: cancelling); Issue.record("Expected cancellation") }
        catch { #expect(error as? TestFailure == cancelled, "\(error)") }
        _ = try await note(opened.root)
        try await opened.harness.close(context: .background)
    }
}

/// Port of upstream `test/harness-storage-failure.test.ts` "listener and report errors", for the parts Swift can express:
/// listeners and `onReport` are synchronous and `now()` cannot throw, so promise rejection, foreign realms, thenables,
/// unformattable values, and a throwing clock have no Swift counterpart.
@Suite struct HarnessListenerReportTests {
    @Test func reportsAThrowingCommitOrCloseListenerAndRunsTheOthersTheCommitStands() async throws {
        let opened = try await started(MemoryStorage()), seen = SessionTestLog<String>()
        _ = try opened.harness.subscribeCommits { _, _ in throw TestFailure("commit listener") }
        _ = try opened.harness.subscribeCommits { _, _ in seen.append("commit") }
        _ = try opened.harness.subscribeClose { throw TestFailure("close listener") }
        _ = try opened.harness.subscribeClose { seen.append("close") }
        _ = try await note(opened.root)
        try await opened.harness.close(context: .background)
        #expect(seen.values == ["commit", "close"])
        #expect(reported(opened.reports) == ["commit listener", "close listener"])
    }

    @Test func reportsAThrowingWatchListenerWhichEndsThatWatch() async throws {
        let opened = try await started(MemoryStorage()), failure = TestFailure("listener broke")
        let watch = try #require(try await opened.harness.watchDoc(LiveDoc, conversationId: opened.root.id, context: .background))
        try watch.start { _, _, _ in throw failure }
        try await opened.root.commit({ tx in try await tx.doc(LiveDoc, conversationId: opened.root.id).set("compactions", .array([])) }, context: .background)
        guard case .listenerError(let error) = await watch.closed else { Issue.record("Watch did not end with listener_error"); return }
        #expect(error as? TestFailure == failure)
        #expect(reported(opened.reports) == ["listener broke"])
        try await opened.harness.close(context: .background)
    }
}
