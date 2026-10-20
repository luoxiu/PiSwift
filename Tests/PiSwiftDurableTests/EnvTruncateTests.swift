import Testing
import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("Truncate utilities") struct EnvTruncateTests {
    @Test("reports UTF-8 byte counts in truncation results") func utf8Bytes() {
        let content = "aé🙂\nb"; let result = truncateHead(content, options: .init(maxLines: 10, maxBytes: 100))
        #expect(!result.truncated); #expect(result.totalBytes == content.utf8.count)
        #expect(result.outputBytes == content.utf8.count); #expect(result.totalBytes == 9)
    }
    @Test("does not count a trailing newline as an extra line") func trailingNewline() {
        let result = truncateHead("line\nline\nline\n", options: .init(maxLines: 3, maxBytes: 100))
        #expect(!result.truncated); #expect(result.totalLines == 3); #expect(result.outputLines == 3)
    }
    @Test("truncates head by line limits") func lineLimit() {
        let result = truncateHead("one\ntwo\nthree\nfour", options: .init(maxLines: 2, maxBytes: 100))
        #expect(result.content == "one\ntwo"); #expect(result.truncated); #expect(result.truncatedBy == .lines)
        #expect(result.totalLines == 4); #expect(result.outputLines == 2)
    }
    @Test("reports bytes when only a trailing newline exceeds limits at the line cap") func newlineByteCap() {
        let result = truncateHead("hello\nworld\n", options: .init(maxLines: 2, maxBytes: 11))
        #expect(result.content == "hello\nworld"); #expect(result.truncated); #expect(result.truncatedBy == .bytes)
        #expect(result.totalLines == 2); #expect(result.outputLines == 2)
    }
    @Test("truncates head on UTF-8 byte limits without partial lines") func bytesNoPartial() {
        let result = truncateHead("éé\nabc", options: .init(maxLines: 10, maxBytes: 4))
        #expect(result.content == "éé"); #expect(result.truncated); #expect(result.truncatedBy == .bytes)
        #expect(result.outputBytes == 4); #expect(!result.firstLineExceedsLimit)
    }
    @Test("reports head truncation when the first line exceeds the byte limit") func firstLineTooLarge() {
        let result = truncateHead("éé\nabc", options: .init(maxLines: 10, maxBytes: 3))
        #expect(result.content == ""); #expect(result.truncated); #expect(result.truncatedBy == .bytes)
        #expect(result.firstLineExceedsLimit)
    }
    @Test("formats sizes") func sizes() {
        #expect(formatSize(1023) == "1023B"); #expect(formatSize(1536) == "1.5KB"); #expect(formatSize(3 * 1024 * 1024) == "3.0MB")
    }
    @Test("known prefix truncation equals whole text") func knownPrefix() {
        let whole = "one\ntwo\nthree\nfour"
        #expect(truncateHeadOf("one\ntwo\n", totals: .init(lines: 4, bytes: whole.utf8.count), options: .init(maxLines: 2, maxBytes: 100))
            == truncateHead(whole, options: .init(maxLines: 2, maxBytes: 100)))
    }
    @Test("test clock fires due timers and drops disarmed ones") func testClock() throws {
        let clock = TestClock(now: 10), fired = SessionTestLog<String>()
        _ = try clock.setTimer({ fired.append("first") }, 10, TimerOptions(background: false))
        #expect(clock.pendingTimerCount == 1); clock.advance(by: 9); #expect(clock.pendingTimerCount == 1)
        #expect(fired.values.isEmpty)
        clock.advance(by: 1); #expect(fired.values == ["first"]); #expect(clock.now() == 20); #expect(clock.pendingTimerCount == 0)
        let disarm = try clock.setTimer({ fired.append("second") }, 10, TimerOptions(background: true))
        #expect(clock.pendingTimerCount == 0); #expect(clock.pendingBackgroundTimerCount == 1)
        disarm?(); clock.advance(by: 10)
        #expect(fired.values == ["first"]); #expect(clock.pendingBackgroundTimerCount == 0)
    }
}
