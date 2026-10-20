import Testing
import Synchronization
@testable import PiSwiftChord

/// A manually advanced clock with timers that fire as it passes their deadline, in place of upstream's fake timers.
private final class OutputTestClock: ProgressClock, Sendable {
    private struct Timer: Sendable { let deadline: Int64; let callback: @Sendable () -> Void }
    private struct State: Sendable { var now: Int64 = 0; var nextID = 0; var timers: [Int: Timer] = [:] }
    private let state = Mutex(State())
    func now() -> Int64 { state.withLock { $0.now } }
    var pendingTimerCount: Int { state.withLock { $0.timers.count } }
    func advance(by milliseconds: Int64) {
        let due = state.withLock { state in
            state.now += milliseconds
            let due = state.timers.filter { $0.value.deadline <= state.now }.sorted { $0.key < $1.key }
            for (id, _) in due { state.timers.removeValue(forKey: id) }
            return due.map(\.value)
        }
        for timer in due { timer.callback() }
    }
    func setTimer(_ callback: @escaping @Sendable () -> Void, delayMs: Int64) -> @Sendable () -> Void {
        let id = state.withLock { state in
            state.nextID += 1
            state.timers[state.nextID] = Timer(deadline: state.now + delayMs, callback: callback)
            return state.nextID
        }
        return { [weak self] in _ = self?.state.withLock { $0.timers.removeValue(forKey: id) } }
    }
}

// upstream chord output.test.ts (durable harness-output.test.ts before 4a5d37291).
@Suite("Output") struct OutputTests {
    private func head(_ lines: Int, _ bytes: Int = 1000) -> OutputLimits { .init(maxBytes: bytes, maxLines: lines, retain: .head) }
    private func tail(_ lines: Int, _ bytes: Int = 1000) -> OutputLimits { .init(maxBytes: bytes, maxLines: lines, retain: .tail) }
    private func check(_ input: String, _ limits: OutputLimits, _ text: String, _ bytes: Int, _ lines: Int) {
        let value = boundOutput(input, limits: limits)
        #expect(value.text == text); #expect(value.droppedBytes == bytes); #expect(value.droppedLines == lines)
    }
    @Test("removes control characters but keeps tabs, newlines, and other text") func sanitize() {
        #expect(sanitizeOutput("a\0b\tc\nd\re\u{7}f\u{fff9}g\u{fffb}h😀") == "ab\tc\ndefgh😀")
    }
    @Test("keeps output within the limits unchanged") func unchanged() {
        check("a\nb\n", head(2), "a\nb\n", 0, 0); check("a\nb", tail(2), "a\nb", 0, 0); check("", tail(2), "", 0, 0)
    }
    @Test("keeps nothing with a zero limit") func zero() {
        check("ab\ncd\n", head(10, 0), "", 6, 2); check("ab\ncd\n", tail(0), "", 6, 2)
    }
    @Test("keeps exact slices of whole lines, trailing newline included") func wholeLines() {
        check("a\nb\nc\n", head(2), "a\nb\n", 2, 1); check("a\nb\nc\n", tail(2), "b\nc\n", 2, 1)
        check("a\nb\nc", tail(2), "b\nc", 2, 1); check("a\nb\nc\n\n", tail(3), "b\nc\n\n", 2, 1)
    }
    @Test("cuts at the byte limit on whole lines when possible") func byteLines() {
        check("aa\nbb\ncc\n", head(10, 7), "aa\nbb\n", 3, 1); check("aa\nbb\ncc\n", tail(10, 7), "bb\ncc\n", 3, 1)
    }
    @Test("cuts a single line longer than the byte limit on a character boundary") func byteCharacters() {
        check("ééé\n", head(10, 5), "éé", 3, 0); check("x\néééé", tail(10, 5), "éé", 6, 1)
    }
    @Test("keeps a U+FEFF at the start of a kept slice") func sliceBOM() {
        check("x\u{feff}a", tail(10, 4), "\u{feff}a", 1, 0)
    }
    @Test("cuts tails exactly like UTF-8 byte oracle across deterministic fuzz cases") func fuzzUTF8() {
        // Swift UTF-8 bytes replace the Node Buffer oracle. Lone surrogate inputs cannot exist in a Swift String.
        let alphabet = ["a", "\u{7f}", "\u{80}", "é", "\u{7ff}", "\u{800}", "中", "\u{d7ff}", "🙂", "\u{e000}", "\u{ffff}"]
        func verify(_ input: String) {
            let bytes = Array(input.utf8)
            let candidates = Set([0, 1, 2, 3, 4, bytes.count / 2, bytes.count - 4, bytes.count - 1, bytes.count, bytes.count + 1].filter { $0 >= 0 })
            for limit in candidates {
                var start = max(0, bytes.count - limit)
                while start < bytes.count && bytes[start] & 0xc0 == 0x80 { start += 1 }
                let expected = String(decoding: bytes[start...], as: UTF8.self)
                #expect(boundOutput(input, limits: tail(1000, limit)).text == expected)
            }
        }
        func exhaustive(_ prefix: String, _ depth: Int) {
            verify(prefix)
            if depth > 0 { for character in alphabet { exhaustive(prefix + character, depth - 1) } }
        }
        exhaustive("", 3)
        var seed: UInt32 = 0x12345678
        func next() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed) / 4294967296 }
        for _ in 0..<1000 {
            let length = Int(next() * 80)
            var input = ""
            for _ in 0..<length { input += alphabet[Int(next() * Double(alphabet.count))] }
            verify(input)
        }
    }
    @Test("keeps exact totals across chunks and decodes UTF-8 split across byte chunks") func splitBytes() throws {
        let buffer = OutputBuffer(tail(2)); let bytes = Array("😀\n".utf8)
        try buffer.push("a\nb\n"); try buffer.push(Array(bytes.prefix(2))); try buffer.push(Array(bytes.dropFirst(2)))
        #expect(buffer.snapshot() == .init(text: "b\n😀\n", droppedBytes: 2, droppedLines: 1))
    }
    @Test("sanitizes the retained text but counts the raw stream") func rawCounts() throws {
        let buffer = OutputBuffer(tail(1)); try buffer.push("a\u{7}\n")
        #expect(buffer.snapshot() == .init(text: "a\n", droppedBytes: 0, droppedLines: 0))
        try buffer.push("b\u{1b}\n")
        #expect(buffer.snapshot() == .init(text: "b\n", droppedBytes: 3, droppedLines: 1))
    }
    @Test("drops a byte-order mark only at the start of the output") func streamBOM() throws {
        let buffer = OutputBuffer(tail(10))
        try buffer.push([0xef]); try buffer.push([0xbb, 0xbf, 0x61]); try buffer.push("b")
        try buffer.push([0xef, 0xbb, 0xbf, 0x63]); buffer.end()
        #expect(buffer.snapshot().text == "ab\u{feff}c")
    }
    @Test("flushes an incomplete character before a string chunk and at the end") func flushIncomplete() throws {
        let buffer = OutputBuffer(tail(10)); let euro = Array("€".utf8)
        try buffer.push(Array(euro.prefix(1))); try buffer.push("x"); try buffer.push(Array(euro.prefix(2))); buffer.end()
        #expect(buffer.snapshot().text == "\u{fffd}x\u{fffd}")
    }
    @Test("matches bounding the whole stream when several chunks arrive between snapshots") func snapshots() throws {
        for limits in [head(3, 40), tail(3, 40), head(50, 25), tail(50, 25)] {
            let buffer = OutputBuffer(limits); var stream = ""
            for index in 0..<300 {
                let chunk = index % 7 == 0 ? String(repeating: "é", count: index % 30) + "\n" : "line \(index)\n"
                stream += chunk; try buffer.push(chunk)
                if index % 5 != 4 { continue }
                let expected = boundOutput(stream, limits: limits)
                #expect(buffer.snapshot() == .init(text: expected.text, droppedBytes: expected.droppedBytes, droppedLines: expected.droppedLines))
            }
        }
    }
    @Test("stops storing head output once the window is full") func boundedHead() throws {
        let buffer = OutputBuffer(head(2))
        for index in 0..<1000 { try buffer.push("line \(index)\n") }
        #expect(buffer.storedBytes < 20)
        #expect(buffer.snapshot() == .init(text: "line 0\nline 1\n", droppedBytes: 8876, droppedLines: 998))
    }
    @Test("stores only the tail window after each snapshot") func boundedTail() throws {
        let buffer = OutputBuffer(tail(3, 100)); var stream = ""
        for index in 0..<2000 {
            let chunk = "line \(index)\n\n"; stream += chunk; try buffer.push(chunk)
            let snapshot = buffer.snapshot()
            #expect(buffer.storedBytes <= 100); #expect(snapshot.text == boundOutput(stream, limits: tail(3, 100)).text)
        }
    }
    @Test("commits the first change at once, then waits at least 100 ms and the written size at 100 KiB/s") func adaptiveProgress() async {
        let clock = OutputTestClock(); let state = Mutex((commits: [Int64](), size: 50 * 1024))
        let progress = Progress(write: { state.withLock { $0.commits.append(clock.now()); return $0.size } }, onError: { _ in }, minIntervalMs: 100, clock: clock)
        await progress.mark(); await eventually { state.withLock { $0.commits == [0] } }
        state.withLock { $0.size = 10 }
        await progress.mark(); await progress.mark(); await eventually { clock.pendingTimerCount == 1 }
        clock.advance(by: 499); #expect(state.withLock { $0.commits } == [0])
        clock.advance(by: 1); await eventually { state.withLock { $0.commits == [0, 500] } }
        await progress.mark(); await eventually { clock.pendingTimerCount == 1 }
        clock.advance(by: 99); #expect(state.withLock { $0.commits } == [0, 500])
        clock.advance(by: 1); await eventually { state.withLock { $0.commits == [0, 500, 600] } }
        _ = await progress.stop()
    }
    @Test("waits the configured minimum interval between small commits") func minimumProgress() async {
        let clock = OutputTestClock(); let commits = Mutex<[Int64]>([])
        let progress = Progress(write: { commits.withLock { $0.append(clock.now()) }; return 10 }, onError: { _ in }, minIntervalMs: 500, clock: clock)
        await progress.mark(); await eventually { commits.withLock { $0 == [0] } }
        await progress.mark(); await eventually { clock.pendingTimerCount == 1 }
        clock.advance(by: 499); #expect(commits.withLock { $0 } == [0])
        clock.advance(by: 1); await eventually { commits.withLock { $0 == [0, 500] } }
        _ = await progress.stop()
    }
    @Test("paces on the clock it is given") func progressClock() async throws {
        let clock = PacingClock(now: 1_000)
        let commits = Mutex<[Int64]>([])
        let progress = Progress(write: { commits.withLock { $0.append(clock.now()) }; return 10 }, onError: { _ in },
                                minIntervalMs: 100, clock: clock)
        try await progress.markAndWait()
        #expect(commits.withLock { $0 } == [1_000])
        // Let the first commit finish settling.
        try #require(await outputEventuallyAsync { await !progress.hasCommitInFlight })
        clock.set(1_040)
        let second = Task { try await progress.markAndWait() }
        try #require(await outputEventuallyAsync { clock.timers.count == 1 })
        #expect(clock.timers.map(\.delayMs) == [60])
        clock.set(1_100)
        clock.timers[0].callback()
        try await second.value
        #expect(commits.withLock { $0 } == [1_000, 1_100])
        try #require(await outputEventuallyAsync { await !progress.hasCommitInFlight })
        await progress.mark()
        #expect(clock.timers.map(\.delayMs) == [60, 100])
        _ = await progress.stop()
        #expect(clock.timers[1].disarmed)
    }
    @Test("rejects the waiters of a failed commit and reports its error") func failedProgress() async {
        let errors = Mutex<[String]>([])
        let progress = Progress(write: { throw OutputTestFailure.commit }, onError: { error in errors.withLock { $0.append(String(describing: error)) } }, minIntervalMs: 100)
        do { try await progress.markAndWait(); Issue.record("Commit must fail") } catch { #expect(error is OutputTestFailure) }
        await eventually { errors.withLock { $0.count == 1 } }
        _ = await progress.stop()
    }
    @Test("stops: waits for the commit in flight and hands back waiters no commit covered yet") func stoppedProgress() async throws {
        let clock = OutputTestClock(); let gate = OutputTestGate(); let entered = Mutex(false)
        let progress = Progress(write: { entered.withLock { $0 = true }; await gate.wait(); return 0 }, onError: { _ in }, minIntervalMs: 100, clock: clock)
        let first = Task { try await progress.markAndWait() }
        await eventually { entered.withLock { $0 } }
        // A mark made during the write must coalesce into the next commit.
        let second = Task { try await progress.markAndWait() }
        try #require(await outputEventuallyAsync { await progress.pendingWaiterCount == 1 })
        let stopped = Task { await progress.stop() }
        try #require(await outputEventuallyAsync { await progress.isStopped })
        await gate.release()
        let pending = await stopped.value; try await first.value
        #expect(pending.count == 1)
        for waiter in pending { waiter.resolve() }
        try await second.value
    }
}
private enum OutputTestFailure: Error { case commit }
/// A clock the test sets, recording each timer it arms, as upstream's "paces on the clock it is given" does.
private final class PacingClock: ProgressClock, Sendable {
    final class Timer: Sendable {
        let delayMs: Int64
        let callback: @Sendable () -> Void
        private let state = Mutex(false)
        init(delayMs: Int64, callback: @escaping @Sendable () -> Void) { self.delayMs = delayMs; self.callback = callback }
        var disarmed: Bool { state.withLock { $0 } }
        func disarm() { state.withLock { $0 = true } }
    }
    private let state: Mutex<(now: Int64, timers: [Timer])>
    init(now: Int64) { state = Mutex((now, [])) }
    var timers: [Timer] { state.withLock { $0.timers } }
    func set(_ now: Int64) { state.withLock { $0.now = now } }
    func now() -> Int64 { state.withLock { $0.now } }
    func setTimer(_ callback: @escaping @Sendable () -> Void, delayMs: Int64) -> @Sendable () -> Void {
        let timer = Timer(delayMs: delayMs, callback: callback)
        state.withLock { $0.timers.append(timer) }
        return { timer.disarm() }
    }
}
private actor OutputTestGate {
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private func eventually(_ predicate: @Sendable () -> Bool) async {
    for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
    #expect(predicate())
}

private func outputEventuallyAsync(_ predicate: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10000 { if await predicate() { return true }; await Task.yield() }
    return await predicate()
}
