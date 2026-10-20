import Foundation
import Synchronization

/// The clock and timer progress commits pace on, in epoch milliseconds. Tests supply a manual clock.
public protocol ProgressClock: Sendable {
    /// Returns the clock time in milliseconds.
    func now() -> Int64
    /// Call `callback` once after about `delayMs`; returns a function that disarms it.
    func setTimer(_ callback: @escaping @Sendable () -> Void, delayMs: Int64) -> @Sendable () -> Void
}

/// The default clock: the system time, and a task that sleeps for each timer (upstream `Date.now` and `setTimeout`).
public struct SystemProgressClock: ProgressClock {
    /// Creates a wall clock backed by the system time source.
    public init() {}
    /// Returns the current system time in epoch milliseconds.
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Calls `callback` once after `delayMs` unless disarmed first.
    public func setTimer(_ callback: @escaping @Sendable () -> Void, delayMs: Int64) -> @Sendable () -> Void {
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(max(0, delayMs))) } catch { return }
            callback()
        }
        return { task.cancel() }
    }
}

/// The byte rate used to delay progress writes after a large publication.
public let progressBytesPerSecond = 100 * 1024

/// A waiter that the final output commit must settle after progress stops.
public final class ProgressWaiter: Sendable {
    private let continuation: Mutex<(@Sendable (Result<Void, any Error>) -> Void)?>
    internal init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex({ continuation.resume(with: $0) })
    }
    package init(notify: @escaping @Sendable (Result<Void, any Error>) -> Void) { continuation = Mutex(notify) }
    /// Completes this progress wait successfully once. Later resolve or reject calls have no effect.
    public func resolve() { take()?(.success(())) }
    /// Completes this progress wait with an error once. Later resolve or reject calls have no effect.
    public func reject(_ error: any Error) { take()?(.failure(error)) }
    private func take() -> (@Sendable (Result<Void, any Error>) -> Void)? {
        continuation.withLock { value in let result = value; value = nil; return result }
    }
}
/// Adaptive progress commits: the first change after an idle period commits at once; each commit then delays the next
/// by at least `minIntervalMs` and by its written size at 100 KiB/s. At most one commit is in flight; changes made
/// meanwhile coalesce into the next one. Paces on `clock`, by default the system time and a sleeping task.
public actor Progress {
    private let write: @Sendable () async throws -> Int
    private let onError: @Sendable (any Error) -> Void
    private let minIntervalMs: Int64
    private let clock: any ProgressClock
    private var waiters: [ProgressWaiter] = []
    /// The armed timer, by ID: a callback that arrives after it was disarmed or replaced does nothing.
    private var timer: (id: Int, disarm: @Sendable () -> Void)?
    private var nextTimer = 0
    private var inFlight: Task<Void, Never>?
    private var nextAt: Int64 = 0
    private var dirty = false
    private var stopped = false
    // Internal probes let tests observe registration and stop without timer delays.
    var pendingWaiterCount: Int { waiters.count }
    var isStopped: Bool { stopped }
    var hasCommitInFlight: Bool { inFlight != nil }
    /// Creates a rate-limited writer with error reporting and a replaceable clock and timer.
    public init(write: @escaping @Sendable () async throws -> Int, onError: @escaping @Sendable (any Error) -> Void,
                minIntervalMs: Int64, clock: any ProgressClock = SystemProgressClock()) {
        self.write = write; self.onError = onError; self.minIntervalMs = minIntervalMs; self.clock = clock
    }
    /// Marks output as changed and schedules a progress write when the rate limit permits.
    public func mark() { dirty = true; schedule() }
    /// Marks output as changed; `waiter` settles with the commit that includes this change.
    package func mark(waiter: ProgressWaiter) { waiters.append(waiter); mark() }
    /// Marks output as changed and waits for the progress write that includes this mark.
    public func markAndWait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(ProgressWaiter(continuation)); mark()
        }
    }
    /// Stops future writes, waits for the active write, and returns unresolved waiters for final settlement.
    public func stop() async -> [ProgressWaiter] {
        stopped = true; timer?.disarm(); timer = nil
        await inFlight?.value
        let pending = waiters; waiters = []; return pending
    }
    private func schedule() {
        guard !stopped, timer == nil, inFlight == nil else { return }
        let wait = nextAt - clock.now()
        if wait <= 0 { flush() }
        else {
            nextTimer += 1
            let id = nextTimer
            // The callback hops onto the actor; `fired` drops it once this timer was disarmed or replaced.
            let disarm = clock.setTimer({ [weak self] in Task { await self?.fired(id) } }, delayMs: wait)
            timer = (id, disarm)
        }
    }
    private func fired(_ id: Int) {
        guard timer?.id == id else { return }
        timer = nil; flush()
    }
    private func flush() {
        guard !stopped, dirty else { return }
        dirty = false
        let covered = waiters; waiters = []
        let started = clock.now()
        inFlight = Task {
            do {
                let bytes = try await write()
                let sizeDelay = Int64((Double(bytes) * 1000 / Double(progressBytesPerSecond)).rounded(.up))
                nextAt = started + max(minIntervalMs, sizeDelay)
                for waiter in covered { waiter.resolve() }
            } catch {
                nextAt = started + minIntervalMs
                for waiter in covered { waiter.reject(error) }
                onError(error)
            }
            inFlight = nil
            if dirty { schedule() }
        }
    }
}
