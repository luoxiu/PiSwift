import Foundation
import PiSwiftChord
import Synchronization

/// Hooks for the harness. Conversation creation runs inside its transaction.
public protocol SessionHooks: Sendable {
    /// Initializes application state inside the new conversation transaction.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws
    /// Runs before the session releases its storage.
    func beforeClose() async
    /// Receives the Session's failure, once, and errors of listeners, which never fail what ran them; `info` says where
    /// each came from.
    func report(_ error: any Error, info: ReportInfo)
}
public extension SessionHooks {
    /// Performs no initialization unless the application supplies an override.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {}
    /// Performs no action unless the application supplies an override.
    func beforeClose() async {}
    /// A plain Session drops reports.
    func report(_ error: any Error, info: ReportInfo) {}
}
/// Session hooks that perform no application initialization.
public struct DefaultSessionHooks: SessionHooks {
    /// Creates hooks with no application callbacks.
    public init() {}
}

/// One mutation line over one storage backend, the loaded document tracker cache, and committed publication.
///
/// The cache is bounded by use: a document with no watch or document state attached leaves it once it was not read or
/// written for the retention period (`DocumentRetention`), and the next access loads it from Storage. Eviction runs on
/// the mutation line, after each commit and when a timer for the next expiry fires, so no transaction ever holds a
/// tracker that leaves.
///
/// Storage failures are final. Every Storage call goes through one guard: the first error a Storage method throws, other
/// than for an invalid read or a cancelled caller, fails the Session, as does a commit it cannot adopt. That call gets the
/// error; every later call and every Storage call still underway gets `SessionFailed`; close listeners run at once, and
/// the Session then closes itself, Storage included, and `closed` settles. Nothing retries: transient errors are the
/// Storage's to retry. Reopening recovers from what was committed.
public final class Session: Sendable {
    internal let storage: any DurableStorage
    internal let now: @Sendable () -> Int64
    internal let hooks: any SessionHooks
    internal let line = SessionLine()
    private let guarded: GuardedStorage
    private struct CommitListener: Sendable {
        let id: Int
        let call: @Sendable (CommitPublication, ChordContext) throws -> Void
    }
    private struct CloseListener: Sendable {
        let id: Int
        let call: @Sendable () throws -> Void
    }
    private struct State: Sendable {
        var closing: Task<Void, any Error>?
        var nextListener = 0
        /// The Session's own listeners, such as its scheduler's: they keep memory in step with storage, so a throw fails it.
        var internalCommits: [CommitListener] = []
        var commits: [CommitListener] = []
        var closes: [CloseListener] = []
        var cache = SessionDocumentCache()
        /// Waits that end with `SessionFailed` the moment the Session fails, before work underway has ended.
        var failureWaits: [UUID: @Sendable (any Error) -> Void] = [:]
    }
    private let state = Mutex(State())
    private let ended = HarnessPromise<SessionEnd>()
    // Capture cached revisions atomically with all adoption, eviction, and installation.
    private let committedRead = Mutex(())
    private let documentRetentionSetting: @Sendable () -> DocumentRetention?
    private let timers: Timers
    /// `documentRetention` is read at each use; nil means the default. `setTimer` arms the eviction timer; nil means
    /// a task that sleeps.
    internal init(storage: any DurableStorage, now: @escaping @Sendable () -> Int64, hooks: any SessionHooks = DefaultSessionHooks(),
                  documentRetention: @escaping @Sendable () -> DocumentRetention? = { nil },
                  setTimer: SetTimer? = nil) {
        let guarded = GuardedStorage(storage)
        self.guarded = guarded; self.storage = guarded; self.now = now; self.hooks = hooks
        self.documentRetentionSetting = documentRetention
        timers = hostTimers(setTimer, report: { [hooks] error in hooks.report(error, info: .hostError(callback: .setTimer, task: nil)) })
        guarded.onFailure { [weak self] error in self?.failed(error) }
    }
    /// Creates a session over the supplied storage without reading persisted records. `now` is the wall clock for task
    /// times. `setTimer` arms the timers that evict idle documents; nil means a task that sleeps (see `HarnessOptions.setTimer`).
    /// The first error a Storage method throws fails the Session (`SessionFailed`). `documentRetentionMs` bounds the
    /// document cache; nil means the default, ten minutes.
    public static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            documentRetentionMs: DocumentRetention? = nil,
                            setTimer: SetTimer? = nil,
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            context: ChordContext) async throws -> Session {
        Session(storage: storage, now: now, hooks: hooks, documentRetention: { documentRetentionMs }, setTimer: setTimer)
    }
    /// Settles once the Session has closed, Storage included: after `close()`, or after the first failed Storage call,
    /// which closes the Session itself. A failed Session is reopened from Storage; nothing else is left to clean up.
    public var closed: SessionEnd {
        get async { (try? await ended.value()) ?? .closed }
    }
    /// The error that failed the Session, if one did.
    internal var failure: (any Error)? { guarded.failure }
    /// Whether close has begun, by `close()` or by a failure.
    internal var isClosing: Bool { state.withLock { $0.closing != nil } }
    /// Fail the Session with `error`, the first wins, and report it once. Admission ends, and close listeners run now;
    /// they read the error from `failure`. The Storage guard calls this; the Harness also calls it for a throw in its
    /// scheduler's own commits.
    internal func fail(_ error: any Error) { guarded.fail(error) }
    /// The first failure: end the waits that race it, close (which runs the close listeners), then report.
    private func failed(_ error: any Error) {
        let waits = state.withLock { state in let waits = state.failureWaits; state.failureWaits = [:]; return waits }
        for wait in waits.values { wait(SessionFailed(error)) }
        // Seal first, so a report handler that calls back finds the Session failed. Closing runs the close listeners
        // synchronously; a failing backend close is the caller's to see, and here nobody waits.
        beginClose(cleanup: .background)
        report(error, info: .sessionFailed)
    }
    /// Internal: the Session's failure, and errors of listeners, which never fail what ran them; `info` defaults to a
    /// listener. A plain Session drops them.
    internal func report(_ error: any Error, info: ReportInfo = .listener) { hooks.report(error, info: info) }
    /// Run `work`, ending the wait with `SessionFailed` the moment the Session fails; the work runs on.
    internal func untilFailed<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let promise = HarnessPromise<T>(), id = UUID()
        try state.withLock { state in
            if let failure = guarded.failure { throw SessionFailed(failure) }
            state.failureWaits[id] = { promise.finish(.failure($0)) }
        }
        Task {
            do { promise.finish(.success(try await work())) } catch { promise.finish(.failure(error)) }
            _ = state.withLock { $0.failureWaits.removeValue(forKey: id) }
        }
        return try await promise.value()
    }
    private func admit() throws -> SessionLine.Ticket {
        try state.withLock {
            if let failure = guarded.failure { throw SessionFailed(failure) }
            if $0.closing != nil { throw SessionError.closed }
            return line.reserve()
        }
    }
    internal func assertHealthy() throws {
        if let failure = guarded.failure { throw SessionFailed(failure) }
    }
    /// Throw `SessionFailed` when failed, else an error when closing.
    internal func assertUsable() throws {
        try assertHealthy()
        if isClosing { throw SessionError.closed }
    }
    /// Commits the supplied changes atomically and publishes them after storage succeeds. Inside the callback read only
    /// through `tx`: `snapshot`, `documentState`, `watchDoc`, `getTask`, and the other Session and runtime reads may
    /// queue on the line the callback holds, and then never return.
    public func commit<T>(_ change: (Transaction) async throws -> T,
                          context: ChordContext) async throws -> T {
        try await commitWith(change, context: context, scope: TransactionScope())
    }
    internal func commitWith<T>(_ change: (Transaction) async throws -> T,
                                context: ChordContext,
                                scope: TransactionScope = TransactionScope()) async throws -> T {
        let ticket = try admit()
        await ticket.wait()
        defer { line.release() }
        try assertHealthy()
        try context.abortSignal?.throwIfAborted()
        let tx = Transaction(session: self, context: context, scope: scope)
        let result: T
        do {
            result = try await change(tx)
            // A callback that caught a failed read must not commit, nor succeed as if it had.
            try assertHealthy()
        }
        catch { await tx.settleFailure(); sweepDocuments(); throw error }
        let writes: [StorageWrite]
        do { writes = try await tx.settleSuccess() }
        catch {
            // Settlement aborted every change already.
            sweepDocuments(); throw error
        }
        if writes.isEmpty { tx.discard(); sweepDocuments(); return result }
        let seq: Seq
        do { seq = try await storage.commit(writes, context: context.withoutAbortSignal()) }
        catch {
            // The guard has failed the Session.
            tx.discard()
            throw error
        }
        let documents: [DocumentCommitChange]
        do { documents = try committedRead.withLock { _ in try tx.adopt(seq) } }
        catch {
            // Storage already committed; a failed adoption leaves memory behind durable state.
            fail(error); throw error
        }
        touchDocuments(documents.map { Array(documentAddressID(DocumentAddress(kind: $0.record.kind, scope: $0.record.scope, key: $0.record.key)).utf8) })
        var changes: [CommitChange] = []
        for write in writes {
            switch write {
            case .conversation(let value, _): changes.append(.conversation(value))
            case .entry(let value, _): changes.append(.entry(value))
            case .task(let value, _): changes.append(.task(value))
            case .submission(let value, _): changes.append(.submission(value))
            default: break
            }
        }
        changes.append(contentsOf: documents.map(CommitChange.document))
        let publication = CommitPublication(seq: seq, changes: changes)
        let (internals, listeners) = state.withLock { ($0.internalCommits, $0.commits) }
        // The commit is durable: a failing listener neither fails the commit nor skips the others.
        for listener in internals {
            do { try listener.call(publication, context) } catch { fail(error) }
        }
        for listener in listeners {
            do { try listener.call(publication, context) } catch { report(error) }
        }
        sweepDocuments()
        return result
    }
    internal func readOnLine<T>(_ job: () async throws -> T) async throws -> T {
        let ticket = try admit()
        await ticket.wait()
        defer { line.release() }
        try assertHealthy()
        return try await job()
    }
    /// Internal, for `beforeClose()`: on the line, after every commit admitted before the seal has settled, write what
    /// `writes()` returns then straight to Storage. Nothing is published, since the Session is closing; a failed Session
    /// writes nothing.
    internal func writeAtClose(_ writes: () -> [StorageWrite]) async throws {
        let ticket = line.reserve()
        await ticket.wait()
        defer { line.release() }
        if failure != nil { return }
        let batch = writes()
        if !batch.isEmpty { _ = try await storage.commit(batch, context: .background) }
    }
    internal func unloadDocuments() async throws {
        // This internal operation also works during harness cleanup.
        let ticket = line.reserve()
        await ticket.wait()
        defer { line.release() }
        state.withLock { $0.cache.documents.removeAll(); $0.cache.idle.removeAll() }
    }
    /// The listener runs on the line after adoption. It must not block or call Session operations; a throw is reported.
    public func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) throws -> Void) throws -> SessionSubscription {
        let id = try addListener { state, id in state.commits.append(CommitListener(id: id, call: listener)) }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.commits.removeAll { $0.id == id } } }
    }
    /// `subscribeCommits()` for the Session's own components, whose state follows each commit. A throw leaves that state
    /// behind storage, so it fails the Session instead of being reported. They run before host listeners.
    internal func observeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) throws -> Void) throws -> SessionSubscription {
        let id = try addListener { state, id in state.internalCommits.append(CommitListener(id: id, call: listener)) }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.internalCommits.removeAll { $0.id == id } } }
    }
    /// The listener runs when close seals admission, also when a failure closes the Session (`failure` is then set). It
    /// must not block or call Session operations; a throw is reported.
    public func subscribeClose(_ listener: @escaping @Sendable () throws -> Void) throws -> SessionSubscription {
        let id = try addListener { state, id in state.closes.append(CloseListener(id: id, call: listener)) }
        return SessionSubscription { [weak self] in self?.state.withLock { $0.closes.removeAll { $0.id == id } } }
    }
    private func addListener(_ add: (inout State, Int) -> Void) throws -> Int {
        try state.withLock { state in
            if let failure = guarded.failure { throw SessionFailed(failure) }
            if state.closing != nil { throw SessionError.closed }
            state.nextListener += 1
            add(&state, state.nextListener)
            return state.nextListener
        }
    }
    /// Releases this object's resources and rejects later operations.
    public func close(context: ChordContext) async throws {
        let task = beginClose(cleanup: context.withoutAbortSignal())
        try await awaitWithContext(task, context)
    }
    /// Seal admission and run the close listeners, each on its own: one that fails is reported, and the rest still run.
    /// The close itself then joins the Harness's work, closes Storage, and settles `closed`.
    @discardableResult
    private func beginClose(cleanup: ChordContext) -> Task<Void, any Error> {
        let begin = SessionLine.Ticket()
        let (task, listeners) = state.withLock { state -> (Task<Void, any Error>, [CloseListener]) in
            if let closing = state.closing { return (closing, []) }
            let task = Task {
                await begin.wait()
                defer { self.ended.finish(.success(self.guarded.failure.map(SessionEnd.failed) ?? .closed)) }
                await self.hooks.beforeClose()
                let ticket = self.line.reserve()
                await ticket.wait()
                defer { self.line.release() }
                self.state.withLock { state in
                    state.commits.removeAll(); state.internalCommits.removeAll()
                    state.cache.documents.removeAll(); state.cache.idle.removeAll(); state.cache.attached.removeAll()
                }
                do { try await self.storage.close(context: cleanup) }
                catch {
                    // A Storage that cannot close is a failed one; an earlier failure stays the cause.
                    if self.guarded.recordFailure(error) { self.report(error, info: .sessionFailed) }
                    throw error
                }
            }
            state.closing = task
            state.cache.sweep?.cancel?(); state.cache.sweep = nil
            let listeners = state.closes; state.closes.removeAll()
            return (task, listeners)
        }
        for listener in listeners {
            do { try listener.call() } catch { report(error) }
        }
        begin.grant()
        return task
    }
    internal func loadDocument(_ definition: DocumentDefinition, address: DocumentAddress,
                               context: ChordContext) async throws -> LoadedDocument? {
        let key = Array(documentAddressID(address).utf8)
        // A tracker serves only tokens of the version its value was materialized for; others reload from Storage.
        if let cached = state.withLock({ $0.cache.documents[key] }) {
            if cached.valueVersion == definition.version { touchDocuments([key]); return cached }
            dropDocument(key)
        }
        guard let record = try await storage.findDocument(address, at: .current, context: context) else { return nil }
        guard let stored = try await storage.document(record.id, at: .current, context: context) else {
            throw SessionError.message("Current document \(record.id.rawValue) (\(record.kind)) cannot be read")
        }
        let value = try definition.materialize(stored)
        let loaded = LoadedDocument(address: address, record: stored.record, storedVersion: stored.version,
                                    valueVersion: definition.version, deltasSinceBase: stored.deltasSinceBase,
                                    tracker: try Delta.track(.object(value)))
        installDocument(loaded)
        return loaded
    }
    internal func currentSnapshot<Value: Decodable & Sendable>(_ definition: DocumentDefinition,
                        address: DocumentAddress, context: ChordContext) async throws -> Value? {
        let now = now(), retention = currentDocumentRetention()
        let captured = try committedRead.withLock { _ -> (LoadedDocument, Int, JSONValue)? in
            let cached = try state.withLock { state -> LoadedDocument? in
                if let failure = guarded.failure { throw SessionFailed(failure) }
                if state.closing != nil { throw SessionError.closed }
                let key = Array(documentAddressID(address).utf8)
                let cached = state.cache.documents[key]
                if cached?.valueVersion == definition.version { touchDocument(key, in: &state, now: now, retention: retention) }
                return cached
            }
            guard let cached, cached.valueVersion == definition.version else { return nil }
            try definition.check(cached.record)
            try definition.checkVersion(cached.storedVersion, record: cached.record)
            return (cached, cached.tracker.revision, cached.tracker.value)
        }
        if let (loaded, revision, tree) = captured {
            return try loaded.snapshot(Value.self, revision: revision, tree: tree)
        }
        return try await readOnLine {
            guard let loaded = try await loadDocument(definition, address: address, context: context) else { return nil }
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            return try loaded.snapshot(Value.self)
        }
    }
    internal func historicalSnapshot<Value: Decodable & Sendable>(_ definition: DocumentDefinition,
                        address: DocumentAddress, at: EntryID, context: ChordContext) async throws -> Value? {
        try await readOnLine {
            guard case .conversation(let conversationID, _) = address.scope else {
                throw SessionError.message("Session.snapshotAsOf() requires a conversation document")
            }
            guard let entry = try await storage.entry(conversationID, id: at, context: context) else {
                throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(conversationID.rawValue)")
            }
            let source = DocumentAddress(kind: address.kind, scope: .conversation(conversationId: entry.entry.conversationId), key: address.key)
            guard let record = try await storage.findDocument(source, at: .sequence(entry.commitSeq), context: context) else { return nil }
            guard let stored = try await storage.document(record.id, at: .sequence(entry.commitSeq), context: context) else {
                throw SessionError.message("Historical document \(record.id.rawValue) (\(record.kind)) cannot be read")
            }
            return try JSONValue.object(definition.materialize(stored)).decode(Value.self)
        }
    }
    internal func conversationDocumentOnLine<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID,
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    internal func conversationDocumentOnLine<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID,
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        try await conversationDocumentOnLine(token.definition, conversationId: conversationId, context: context)
    }
    private func conversationDocumentOnLine(_ definition: DocumentDefinition, conversationId: ConversationID,
                        context: ChordContext) async throws -> (record: DocumentRecord, version: Int, value: JSONObject)? {
        let address = DocumentAddress(kind: definition.kind, scope: .conversation(conversationId: conversationId))
        guard let loaded = try await loadDocument(definition, address: address, context: context) else { return nil }
        try definition.check(loaded.record)
        try definition.checkVersion(loaded.storedVersion, record: loaded.record)
        return (loaded.record, loaded.valueVersion, loaded.tracker.value.objectValue!)
    }
    internal func cachedDocument(_ address: DocumentAddress) -> LoadedDocument? {
        let key = Array(documentAddressID(address).utf8)
        let cached = state.withLock { $0.cache.documents[key] }
        if cached != nil { touchDocuments([key]) }
        return cached
    }
    internal func installDocument(_ document: LoadedDocument) {
        let key = Array(documentAddressID(document.address).utf8)
        state.withLock { $0.cache.documents[key] = document }
        touchDocuments([key])
    }
    internal func evictDocument(_ address: DocumentAddress, recordID: DocumentID) {
        let key = Array(documentAddressID(address).utf8)
        state.withLock { state in
            if state.cache.documents[key]?.record.id == recordID { state.cache.documents.removeValue(forKey: key); state.cache.idle.remove(key) }
        }
    }
    private func dropDocument(_ key: [UInt8]) {
        state.withLock { $0.cache.documents.removeValue(forKey: key); $0.cache.idle.remove(key) }
    }

    /// The document retention in force: the Harness reads its settings at each use.
    private func currentDocumentRetention() -> DocumentRetention { documentRetention(documentRetentionSetting()) }
    /// Internal, for tests: how many documents the cache holds, how many are idle, how many incarnations are pinned, and
    /// how many sweep jobs were queued on the line so far.
    internal var documentCacheSizes: DocumentCacheSizes {
        state.withLock { DocumentCacheSizes(cached: $0.cache.documents.count, idle: $0.cache.idle.count,
                                            attached: $0.cache.attached.count, sweeps: $0.cache.sweepJobs) }
    }
    /// Note uses of cached documents. The clock and the setting are read before the lock: both are host code.
    private func touchDocuments(_ keys: [[UInt8]]) {
        let now = now(), retention = currentDocumentRetention()
        state.withLock { state in for key in keys { touchDocument(key, in: &state, now: now, retention: retention) } }
    }
    /// Note a use of a cached document: an unattached one becomes the newest idle one, and an eviction is scheduled.
    private func touchDocument(_ key: [UInt8], in state: inout State, now: Int64, retention: DocumentRetention) {
        guard let cached = state.cache.documents[key], state.cache.attached[cached.record.id] == nil else { return }
        // A hot document moves to the back at most once per granule, a tenth of the retention up to 1 s: it may then leave
        // up to a granule early, which costs a reload, while a commit-heavy workload skips the reordering.
        if let since = state.cache.idle.since(key), withinDocumentGranule(now - since, retention) { return }
        state.cache.idle.use(key, at: now)
        // A pending sweep for the oldest document comes first unless the retention was shortened since; then it moves up.
        if let pending = state.cache.sweep, !(documentExpiry(now, retention).map { pending.at > $0 } ?? false) { return }
        scheduleDocumentSweep(&state, now: now, retention: retention)
    }
    /// Schedule the eviction of the oldest idle document: on the line at once when it is due, otherwise when it expires,
    /// by a background timer (`HarnessOptions.setTimer`), which never keeps the process alive. Where the host declines it,
    /// none is kept: the end of each commit evicts what expired. `forever` schedules nothing.
    private func scheduleDocumentSweep(_ state: inout State, now: Int64, retention: DocumentRetention) {
        guard state.closing == nil, let oldest = state.cache.idle.oldest(), let at = documentExpiry(oldest, retention) else { return }
        if let pending = state.cache.sweep, pending.at <= at { return }
        state.cache.sweep?.cancel?()
        state.cache.nextSweep += 1
        let id = state.cache.nextSweep
        // The pending sweep stays set until its job runs, so touches while the line is busy queue no more.
        state.cache.sweep = PendingDocumentSweep(at: at, id: id)
        let (delay, overflow) = at.subtractingReportingOverflow(now)
        if !overflow, delay <= 0 { queueDocumentSweep(id, in: &state); return }
        if state.cache.timersUnavailable { state.cache.sweep = nil; return }
        // A timer that fires early sweeps nothing and arms the next one.
        guard let cancel = timers.background({ [weak self] in
            self?.state.withLock { state in
                guard state.closing == nil else { return }
                self?.queueDocumentSweep(id, in: &state)
            }
        }, overflow ? .max : delay) else {
            state.cache.timersUnavailable = true
            state.cache.sweep = nil
            return
        }
        state.cache.sweep?.cancel = cancel
    }
    /// Queue a sweep job on the line now, behind whatever holds it, as upstream enqueues one.
    private func queueDocumentSweep(_ id: Int, in state: inout State) {
        state.cache.sweepJobs += 1
        let ticket = line.reserve()
        Task { [weak self, line] in
            await ticket.wait()
            defer { line.release() }
            self?.sweepOnLine(id)
        }
    }
    /// The sweep job, on the line: evict what expired, then schedule the next eviction.
    private func sweepOnLine(_ id: Int) {
        let now = now(), retention = currentDocumentRetention()
        state.withLock { state in
            if state.cache.sweep?.id == id { state.cache.sweep = nil }
            if state.closing == nil { sweepDocuments(&state, now: now, retention: retention) }
        }
    }
    /// On the line, after each commit outcome: evict what expired.
    private func sweepDocuments() {
        let now = now(), retention = currentDocumentRetention()
        state.withLock { sweepDocuments(&$0, now: now, retention: retention) }
    }
    /// Evict the idle documents whose retention passed, oldest first, then schedule the next eviction.
    private func sweepDocuments(_ state: inout State, now: Int64, retention: DocumentRetention) {
        if let ms = retention.ms {
            let (expired, overflow) = now.subtractingReportingOverflow(ms)
            if !overflow { for key in state.cache.idle.removeUsed(atOrBefore: expired) { state.cache.documents.removeValue(forKey: key) } }
        }
        scheduleDocumentSweep(&state, now: now, retention: retention)
    }
    /// Pin a cached incarnation for one observer; unpinning releases it once, and the last makes it idle again.
    internal func pinDocument(_ address: DocumentAddress, recordID: DocumentID) -> DocumentPin {
        let key = Array(documentAddressID(address).utf8)
        state.withLock { state in
            state.cache.attached[recordID, default: 0] += 1
            state.cache.idle.remove(key)
        }
        return DocumentPin { [weak self] in self?.unpinDocument(key, recordID: recordID) }
    }
    private func unpinDocument(_ key: [UInt8], recordID: DocumentID) {
        let now = now(), retention = currentDocumentRetention()
        state.withLock { state in
            let count = (state.cache.attached[recordID] ?? 1) - 1
            if count > 0 { state.cache.attached[recordID] = count; return }
            state.cache.attached.removeValue(forKey: recordID)
            if state.cache.documents[key]?.record.id == recordID { touchDocument(key, in: &state, now: now, retention: retention) }
        }
    }
}
