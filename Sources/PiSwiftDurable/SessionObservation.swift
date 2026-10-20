import PiSwiftChord
import Synchronization

/// Release the Session subscriptions and the document pin, including one installed after release.
private final class ObservationSubscriptions: Sendable {
    private struct State {
        var released = false
        var subscriptions: [SessionSubscription] = []
    }
    private let state = Mutex(State())
    func add(_ subscription: SessionSubscription) {
        let cancel = state.withLock { state in
            if state.released { return true }
            state.subscriptions.append(subscription)
            return false
        }
        if cancel { subscription.cancel() }
    }
    func release() {
        let subscriptions = state.withLock { state in
            state.released = true
            let subscriptions = state.subscriptions
            state.subscriptions.removeAll()
            return subscriptions
        }
        for subscription in subscriptions { subscription.cancel() }
    }
}

/// An observer keeps its own version and value after the tracker cache unloads.
private final class ObservationRevision: Sendable {
    private struct State { var version: Int; var tree: JSONValue }
    private let state: Mutex<State>
    init(version: Int, value: JSONObject) {
        state = Mutex(State(version: version, tree: .object(value)))
    }
    var tree: JSONValue { state.withLock { $0.tree } }
    func operations(_ change: DocumentCommitChange) -> [Delta.Op] {
        state.withLock { state in
            guard let value = change.value else {
                state.tree = .null
                return [.replace(.null)]
            }
            state.tree = .object(value)
            if change.version == state.version { return change.ops }
            state.version = change.version!
            return [.replace(.object(value))]
        }
    }
}

extension Session {
    internal func currentWatch<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress,
        context: ChordContext
    ) async throws -> CommittedWatch<Value?>? {
        let watch: CommittedWatch<Value?>? = try await readOnLine {
            try context.abortSignal?.throwIfAborted()
            guard let loaded = try await loadDocument(definition, address: address, context: context) else {
                try context.abortSignal?.throwIfAborted()
                return nil
            }
            try context.abortSignal?.throwIfAborted()
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            let value = try loaded.snapshot(Value.self)
            let revision = ObservationRevision(version: loaded.valueVersion, value: loaded.tracker.value.objectValue!)
            let subscriptions = ObservationSubscriptions()
            let watch = CommittedWatch<Value?>(value: value, replacement: { _ in revision.tree }, detach: { subscriptions.release() },
                                               report: { [hooks] in hooks.report($0) })
            do {
                try attachObservation(loaded, revision: revision, subscriptions: subscriptions,
                    advance: { change, ops, context in
                        do {
                            let value = try change.value.map { try JSONValue.object($0).decode(Value.self) }
                            watch.advance(value: value, ops: ops, context: context, retired: change.value == nil)
                        } catch { watch.fail(error) }
                    }, close: { [weak self] in watch.closeSession(failure: self?.failure) })
                if let signal = context.abortSignal { try watch.observeCancellation(signal) }
                try context.abortSignal?.throwIfAborted()
                return watch
            } catch {
                watch.cancel()
                subscriptions.release()
                throw error
            }
        }
        do { try context.abortSignal?.throwIfAborted() }
        catch { watch?.cancel(); throw error }
        return watch
    }

    internal func currentDocumentState<Value: Codable & Sendable>(
        _ definition: DocumentDefinition, address: DocumentAddress,
        context: ChordContext
    ) async throws -> AttachedReplicatedState<Value?>? {
        try await readOnLine {
            try context.abortSignal?.throwIfAborted()
            guard let loaded = try await loadDocument(definition, address: address, context: context) else {
                try context.abortSignal?.throwIfAborted()
                return nil
            }
            try context.abortSignal?.throwIfAborted()
            try definition.check(loaded.record)
            try definition.checkVersion(loaded.storedVersion, record: loaded.record)
            let value = try loaded.snapshot(Value.self)
            let revision = ObservationRevision(version: loaded.valueVersion, value: loaded.tracker.value.objectValue!)
            let subscriptions = ObservationSubscriptions()
            let source = CommittedStateSource<Value?>(value: value, release: { subscriptions.release() })
            do {
                try attachObservation(loaded, revision: revision, subscriptions: subscriptions,
                    advance: { change, ops, context in
                        do {
                            let value = try change.value.map { try JSONValue.object($0).decode(Value.self) }
                            source.advance(value: value, ops: ops, context: context, retired: change.value == nil)
                        } catch { source.closeSession() }
                    }, close: { source.closeSession() })
                let state = try replicatedState(source, onError: { [hooks] in hooks.report($0) })
                do { try context.abortSignal?.throwIfAborted() }
                catch { state.dispose(); throw error }
                return state
            } catch {
                source.closeSession()
                subscriptions.release()
                throw error
            }
        }
    }

    /// Attached, the incarnation stays cached; once its last observer detaches, or it retires, it is idle again.
    private func attachObservation(
        _ loaded: LoadedDocument, revision: ObservationRevision, subscriptions: ObservationSubscriptions,
        advance: @escaping @Sendable (DocumentCommitChange, [Delta.Op], ChordContext) -> Void,
        close: @escaping @Sendable () -> Void
    ) throws {
        let recordID = loaded.record.id
        let pin = pinDocument(loaded.address, recordID: recordID)
        subscriptions.add(SessionSubscription { pin.unpin() })
        subscriptions.add(try observeCommits { publication, context in
            for change in publication.changes {
                guard case .document(let document) = change,
                      document.source == nil, document.record.id == recordID else { continue }
                let ops = revision.operations(document)
                guard !ops.isEmpty else { continue }
                // A retired incarnation never changes again: its observers keep their last value but pin nothing.
                if document.value == nil { pin.unpin() }
                advance(document, ops, context.withoutAbortSignal())
            }
        })
        subscriptions.add(try subscribeClose(close))
    }
}
