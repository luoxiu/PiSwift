import Foundation
import Synchronization

/// How long a loaded document that no watch or document state observes stays in memory after its last read or write;
/// the next access loads it from Storage. Observed documents always stay. An integer literal gives milliseconds.
public enum DocumentRetention: Sendable, Equatable, ExpressibleByIntegerLiteral {
    /// This many milliseconds; `0` drops one right after use. A negative count means the default.
    case milliseconds(Int64)
    /// Keeps loaded documents for the life of the Session (upstream `Infinity`).
    case forever
    /// Milliseconds, as `milliseconds(_:)`.
    public init(integerLiteral value: Int64) { self = .milliseconds(value) }
    /// The milliseconds, or nil for `forever`.
    internal var ms: Int64? { if case .milliseconds(let ms) = self { ms } else { nil } }
}

/// Default document retention: ten minutes, as for kept contexts. `PI_DURABLE_DOCUMENT_RETENTION_MS`, a number of
/// milliseconds, replaces it for every Session that keeps the default, so the test suite can run a second time with each
/// unattached document evicted right after use. Upstream sets it from its test setup file (`setDefaultDocumentRetention`);
/// Swift Testing has no setup that runs before every suite, so the library reads the variable, once.
internal let defaultDocumentRetention: DocumentRetention = {
    if let forced = ProcessInfo.processInfo.environment["PI_DURABLE_DOCUMENT_RETENTION_MS"], let ms = Int64(forced), ms >= 0 {
        return .milliseconds(ms)
    }
    return .milliseconds(600_000)
}()

/// A retention as given, when it is a number of milliseconds, `0` or more, or `forever`; otherwise the default.
internal func documentRetention(_ retention: DocumentRetention?) -> DocumentRetention {
    switch retention {
    case .milliseconds(let ms)? where ms >= 0: .milliseconds(ms)
    case .forever?: .forever
    default: defaultDocumentRetention
    }
}

/// Arms a timer that only frees memory and returns what cancels it, or nil when the host declines it. It must not call
/// `fire` before it returns.
internal typealias SessionTimer = @Sendable (_ delayMs: Int64, _ fire: @escaping @Sendable () async -> Void) -> (@Sendable () -> Void)?

/// The default timer: a task that sleeps and holds nothing else.
internal let sessionTaskTimer: SessionTimer = { delayMs, fire in
    let task = Task {
        do { try await Task.sleep(for: .milliseconds(delayMs)) } catch { return }
        await fire()
    }
    return { task.cancel() }
}

/// Cached documents with no observer attached, by address, oldest use first, with the time of that use. A Swift
/// dictionary keeps no insertion order: `order` lists the uses as they happen, and skips a use that a later one of the
/// same document replaced. Replaced uses are dropped once they outnumber the live ones.
internal struct IdleDocuments: Sendable {
    private struct Use: Sendable { let since: Int64; let stamp: Int }
    private struct Slot: Sendable { let key: [UInt8]; let stamp: Int }
    private var uses: [[UInt8]: Use] = [:]
    private var order: [Slot] = []
    private var head = 0
    private var stamp = 0
    var count: Int { uses.count }
    func since(_ key: [UInt8]) -> Int64? { uses[key]?.since }
    /// Make `key` the newest idle document, used at `now`.
    mutating func use(_ key: [UInt8], at now: Int64) {
        stamp += 1
        uses[key] = Use(since: now, stamp: stamp)
        order.append(Slot(key: key, stamp: stamp))
        compact()
    }
    mutating func remove(_ key: [UInt8]) {
        if uses.removeValue(forKey: key) != nil { compact() }
    }
    mutating func removeAll() { uses.removeAll(); order.removeAll(); head = 0 }
    /// When the oldest idle document was used.
    mutating func oldest() -> Int64? {
        skipReplaced()
        return head < order.count ? uses[order[head].key]?.since : nil
    }
    /// Remove the idle documents used at `expired` or before, oldest first, and return their keys.
    mutating func removeUsed(atOrBefore expired: Int64) -> [[UInt8]] {
        var removed: [[UInt8]] = []
        while true {
            skipReplaced()
            guard head < order.count, let use = uses[order[head].key], use.since <= expired else { break }
            uses.removeValue(forKey: order[head].key)
            removed.append(order[head].key)
            head += 1
        }
        if !removed.isEmpty { compact() }
        return removed
    }
    private mutating func skipReplaced() {
        while head < order.count, uses[order[head].key]?.stamp != order[head].stamp { head += 1 }
    }
    private mutating func compact() {
        guard order.count - head > 2 * uses.count + 32 || (head > 0 && head * 2 > order.count) else { return }
        order = order[head...].filter { uses[$0.key]?.stamp == $0.stamp }
        head = 0
    }
}

/// The pending eviction: when it is due, and what cancels its timer, if it has one.
internal struct PendingDocumentSweep: Sendable {
    let at: Int64
    let id: Int
    var cancel: (@Sendable () -> Void)?
}

/// The Session's loaded document trackers, bounded by use (see `Session`).
internal struct SessionDocumentCache: Sendable {
    var documents: [[UInt8]: LoadedDocument] = [:]
    /// Cached documents with no observer attached, oldest use first, with the time of that use.
    var idle = IdleDocuments()
    /// Observers attached per document incarnation (record ID); a cached incarnation with any is never evicted.
    var attached: [DocumentID: Int] = [:]
    /// The pending eviction: a timer for the oldest idle document, or a line job when it is due.
    var sweep: PendingDocumentSweep?
    var nextSweep = 0
    var sweepJobs = 0
    /// Set once the timer was declined: then none is kept, and the end of each commit evicts what expired.
    var timersUnavailable = false
}

/// Internal, for tests: how many documents the cache holds, how many are idle, how many incarnations are pinned, and how
/// many sweep jobs were queued on the line so far.
internal struct DocumentCacheSizes: Sendable, Equatable {
    let cached: Int
    let idle: Int
    let attached: Int
    let sweeps: Int
}

/// One observer's pin on a cached incarnation. Releasing it again does nothing.
internal final class DocumentPin: Sendable {
    private let release: Mutex<(@Sendable () -> Void)?>
    init(_ release: @escaping @Sendable () -> Void) { self.release = Mutex(release) }
    func unpin() {
        let release = self.release.withLock { release in
            let taken = release
            release = nil
            return taken
        }
        release?()
    }
}

/// `since` plus the retention, or nil when the retention keeps documents or the sum leaves the range of Int64.
internal func documentExpiry(_ since: Int64, _ retention: DocumentRetention) -> Int64? {
    guard let ms = retention.ms else { return nil }
    let (at, overflow) = since.addingReportingOverflow(ms)
    return overflow ? nil : at
}

/// Whether a use `elapsed` after the last one falls in the same granule, a tenth of the retention up to 1 s.
internal func withinDocumentGranule(_ elapsed: Int64, _ retention: DocumentRetention) -> Bool {
    guard elapsed < 1_000 else { return false }
    guard let ms = retention.ms else { return true }
    return elapsed * 10 < ms
}
