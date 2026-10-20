import PiSwiftChord
import Synchronization

/// The Session's Storage behind its failure guard; every component of the Session reads and writes through it. Before a
/// call, a failed Session gets `SessionFailed` without reaching the backend. A call that throws fails the Session and
/// rethrows the backend's error, unless it is a `StorageRequestError` from a read or a read whose caller's context was
/// aborted: neither says the Storage is broken. `close()` always reaches the backend, so a failed Session still closes it.
internal final class GuardedStorage: DurableStorage {
    private struct State {
        var failure: (any Error)?
        var onFailure: (@Sendable (any Error) -> Void)?
        var closing = false
        /// Backend calls underway, also those off the Session line, which close waits for before it closes the backend.
        var underway = 0
        var drained: [CheckedContinuation<Void, Never>] = []
    }
    private let storage: any DurableStorage
    private let state = Mutex(State())

    init(_ storage: any DurableStorage) { self.storage = storage }

    /// The error that failed the Session, if one did.
    var failure: (any Error)? { state.withLock { $0.failure } }
    /// Whether close has reached the backend's guard; new calls are refused from then on.
    var isClosing: Bool { state.withLock { $0.closing } }
    /// Installs the Session's reaction to its first failure.
    func onFailure(_ handler: @escaping @Sendable (any Error) -> Void) { state.withLock { $0.onFailure = handler } }
    /// Records `error` when it is the first failure, without the Session's reaction; returns whether it was the first.
    func recordFailure(_ error: any Error) -> Bool {
        state.withLock { state in
            guard state.failure == nil else { return false }
            state.failure = error
            return true
        }
    }
    /// Records the first failure and hands it to the Session; later failures are ignored.
    func fail(_ error: any Error) {
        let handler = state.withLock { state -> (@Sendable (any Error) -> Void)?? in
            guard state.failure == nil else { return nil }
            state.failure = error
            return .some(state.onFailure)
        }
        if let handler { handler?(error) }
    }

    /// Never exempt, whatever it throws: once admitted, whether a failed batch committed is unknown.
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        try await call(nil) { try await storage.commit(writes, context: context) }
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await call(nil) { try await storage.mintId() }
    }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await call(context) { try await storage.conversation(id, context: context) }
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await call(context) { try await storage.scanConversations(query, limit: limit, cursor: cursor, context: context) }
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await call(context) { try await storage.entry(id, context: context) }
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await call(context) { try await storage.entry(conversationId, id: id, context: context) }
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await call(context) { try await storage.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context) }
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await call(context) { try await storage.scanEntries(query, limit: limit, cursor: cursor, context: context) }
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await call(context) { try await storage.task(id, context: context) }
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await call(context) { try await storage.scanTasks(query, limit: limit, cursor: cursor, context: context) }
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await call(context) { try await storage.submission(id, context: context) }
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await call(context) { try await storage.scanSubmissions(query, limit: limit, cursor: cursor, context: context) }
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await call(context) { try await storage.submissionByRequest(conversationId, requestId: requestId, context: context) }
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await call(context) { try await storage.findDocument(address, at: at, context: context) }
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await call(context) { try await storage.document(id, at: at, context: context) }
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await call(context) { try await storage.scanDocuments(query, limit: limit, cursor: cursor, context: context) }
    }

    /// Close the backend once every call underway has settled, so none outlives it or fails after `closed` settles. New
    /// calls are refused from here on: a paged read must not start its next page while the backend closes.
    func close(context: ChordContext) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                state.closing = true
                if state.underway == 0 { return true }
                state.drained.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        try await storage.close(context: context)
    }

    /// Run one backend call under the guard. `read` is a read's context; `commit()` and `mintId()` pass none, so nothing
    /// exempts their errors: once a batch is admitted, whether it committed is unknown. A call still underway when
    /// another fails the Session ends with `SessionFailed` too, whatever it returns: nothing it read or wrote is used.
    private func call<T>(_ read: ChordContext?, _ run: () async throws -> T) async throws -> T {
        try state.withLock { state in
            if let failure = state.failure { throw SessionFailed(failure) }
            if state.closing { throw SessionError.closed }
            state.underway += 1
        }
        defer { settle() }
        let result: T
        do { result = try await run() }
        catch {
            try assertHealthy()
            // An invalid read, or one its caller cancelled, says nothing about the Storage; it fails that call only.
            let exempt = read != nil && (error is StorageRequestError || read?.abortSignal?.aborted == true)
            if !exempt { fail(error) }
            throw error
        }
        try assertHealthy()
        return result
    }
    private func settle() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.underway -= 1
            guard state.underway == 0 else { return [] }
            let waiters = state.drained; state.drained = []; return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func assertHealthy() throws {
        if let failure { throw SessionFailed(failure) }
    }
}
