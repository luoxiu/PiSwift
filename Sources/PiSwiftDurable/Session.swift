import Foundation
import PiSwiftChord
import Synchronization

/// Hooks for the harness. Conversation creation runs inside its transaction.
public protocol SessionHooks: Sendable {
    /// Initializes application state inside the new conversation transaction.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws
    /// Runs before the session releases its storage.
    func beforeClose() async
    /// Receives the Session's failure, once, and errors of listeners, which never fail what ran them.
    func report(_ error: any Error)
}
public extension SessionHooks {
    /// Performs no initialization unless the application supplies an override.
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {}
    /// Performs no action unless the application supplies an override.
    func beforeClose() async {}
    /// A plain Session drops reports.
    func report(_ error: any Error) {}
}
/// Session hooks that perform no application initialization.
public struct DefaultSessionHooks: SessionHooks {
    /// Creates hooks with no application callbacks.
    public init() {}
}

/// One mutation line over one storage backend.
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
        var documents: [[UInt8]: LoadedDocument] = [:]
        /// Waits that end with `SessionFailed` the moment the Session fails, before work underway has ended.
        var failureWaits: [UUID: @Sendable (any Error) -> Void] = [:]
    }
    private let state = Mutex(State())
    private let ended = HarnessPromise<SessionEnd>()
    // Capture cached revisions atomically with all adoption, eviction, and installation.
    private let committedRead = Mutex(())
    private init(storage: any DurableStorage, now: @escaping @Sendable () -> Int64, hooks: any SessionHooks) {
        let guarded = GuardedStorage(storage)
        self.guarded = guarded; self.storage = guarded; self.now = now; self.hooks = hooks
        guarded.onFailure { [weak self] error in self?.failed(error) }
    }
    /// Creates a session over the supplied storage without reading persisted records. The first error a Storage method
    /// throws fails the Session (`SessionFailed`).
    public static func open(storage: any DurableStorage,
                            now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                            hooks: any SessionHooks = DefaultSessionHooks(),
                            context: ChordContext) async throws -> Session {
        Session(storage: storage, now: now, hooks: hooks)
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
        hooks.report(error)
    }
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
        catch { await tx.settleFailure(); throw error }
        let writes = try await tx.settleSuccess()
        if writes.isEmpty { tx.discard(); return result }
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
            do { try listener.call(publication, context) } catch { hooks.report(error) }
        }
        return result
    }
    internal func readOnLine<T>(_ job: () async throws -> T) async throws -> T {
        let ticket = try admit()
        await ticket.wait()
        defer { line.release() }
        try assertHealthy()
        return try await job()
    }
    internal func unloadDocuments() async throws {
        // This internal operation also works during harness cleanup.
        let ticket = line.reserve()
        await ticket.wait()
        defer { line.release() }
        state.withLock { $0.documents.removeAll() }
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
                self.state.withLock { $0.commits.removeAll(); $0.internalCommits.removeAll(); $0.documents.removeAll() }
                do { try await self.storage.close(context: cleanup) }
                catch {
                    // A Storage that cannot close is a failed one; an earlier failure stays the cause.
                    if self.guarded.recordFailure(error) { self.hooks.report(error) }
                    throw error
                }
            }
            state.closing = task
            let listeners = state.closes; state.closes.removeAll()
            return (task, listeners)
        }
        for listener in listeners {
            do { try listener.call() } catch { hooks.report(error) }
        }
        begin.grant()
        return task
    }
    internal func loadDocument(_ definition: DocumentDefinition, address: DocumentAddress,
                               context: ChordContext) async throws -> LoadedDocument? {
        if let cached = cachedDocument(address) {
            if cached.valueVersion == definition.version { return cached }
            evictDocument(address, recordID: cached.record.id)
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
        let captured = try committedRead.withLock { _ -> (LoadedDocument, Int, JSONValue)? in
            let cached = try state.withLock { state -> LoadedDocument? in
                if let failure = guarded.failure { throw SessionFailed(failure) }
                if state.closing != nil { throw SessionError.closed }
                return state.documents[Array(documentAddressID(address).utf8)]
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
        state.withLock { $0.documents[Array(documentAddressID(address).utf8)] }
    }
    internal func installDocument(_ document: LoadedDocument) {
        state.withLock { $0.documents[Array(documentAddressID(document.address).utf8)] = document }
    }
    internal func evictDocument(_ address: DocumentAddress, recordID: DocumentID) {
        state.withLock {
            let key = Array(documentAddressID(address).utf8)
            if $0.documents[key]?.record.id == recordID { $0.documents.removeValue(forKey: key) }
        }
    }
}
