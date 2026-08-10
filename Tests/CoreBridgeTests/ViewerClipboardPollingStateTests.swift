import XCTest
@testable import CoreBridge

final class ViewerClipboardPollingStateTests: XCTestCase {
    func testProductBackoffIsBoundedAndResetsOnChange() {
        var state = ViewerClipboardPollingState()
        XCTAssertEqual(
            state.begin(sessionEpoch: 7, currentChangeCount: 10),
            125
        )

        var delay: UInt64?
        for _ in 0..<10 {
            delay = state.observePoll(
                sessionEpoch: 7,
                changeCount: 10,
                text: "ignored"
            ).nextDelayMilliseconds
        }
        XCTAssertEqual(delay, 4_000)

        let changed = state.observePoll(
            sessionEpoch: 7,
            changeCount: 11,
            text: "local text"
        )
        XCTAssertEqual(changed.textToSend, "local text")
        XCTAssertEqual(changed.nextDelayMilliseconds, 125)
    }

    func testPasteboardTextIsReadOnlyAfterChangeCountChanges() {
        var state = ViewerClipboardPollingState()
        XCTAssertNotNil(state.begin(sessionEpoch: 4, currentChangeCount: 10))
        var reads = 0
        func readText() -> String? {
            reads += 1
            return "changed"
        }

        XCTAssertNil(state.observePoll(
            sessionEpoch: 4,
            changeCount: 10,
            text: readText()
        ).textToSend)
        XCTAssertEqual(reads, 0)

        XCTAssertEqual(state.observePoll(
            sessionEpoch: 4,
            changeCount: 11,
            text: readText()
        ).textToSend, "changed")
        XCTAssertEqual(reads, 1)
    }

    func testInitialClipboardIsNotSentAndOwnedRemoteWriteIsSuppressed() {
        var state = ViewerClipboardPollingState()
        XCTAssertEqual(
            state.begin(sessionEpoch: 1, currentChangeCount: 40),
            125
        )
        XCTAssertNil(state.observePoll(
            sessionEpoch: 1,
            changeCount: 40,
            text: "pre-session secret"
        ).textToSend)

        XCTAssertEqual(
            state.observeOwnedWrite(
                sessionEpoch: 1,
                resultingChangeCount: 41
            ),
            125
        )
        XCTAssertNil(state.observePoll(
            sessionEpoch: 1,
            changeCount: 41,
            text: "remote text"
        ).textToSend)

        XCTAssertEqual(
            state.observePoll(
                sessionEpoch: 1,
                changeCount: 42,
                text: "remote text"
            ).textToSend,
            "remote text"
        )
    }

    func testTextPolicyRejectsEmptyNULAndOversizeText() {
        XCTAssertFalse(ViewerClipboardTextPolicy.accepts(""))
        XCTAssertFalse(ViewerClipboardTextPolicy.accepts("a\0b"))
        XCTAssertTrue(ViewerClipboardTextPolicy.accepts(
            String(repeating: "a", count: 64 * 1024)
        ))
        XCTAssertFalse(ViewerClipboardTextPolicy.accepts(
            String(repeating: "a", count: 64 * 1024 + 1)
        ))
        XCTAssertFalse(ViewerClipboardTextPolicy.accepts(
            String(repeating: "你", count: 22_000)
        ))
    }

    func testStaleEpochCannotSendOrMutateCurrentSession() {
        var state = ViewerClipboardPollingState()
        XCTAssertNotNil(state.begin(sessionEpoch: 9, currentChangeCount: 1))
        XCTAssertNil(state.observePoll(
            sessionEpoch: 8,
            changeCount: 2,
            text: "stale"
        ).nextDelayMilliseconds)
        XCTAssertNil(state.observeOwnedWrite(
            sessionEpoch: 8,
            resultingChangeCount: 3
        ))
        XCTAssertFalse(state.stop(sessionEpoch: 8))
        XCTAssertEqual(
            state.observePoll(
                sessionEpoch: 9,
                changeCount: 2,
                text: "current"
            ).textToSend,
            "current"
        )
    }

    func testStopAllowsSameEpochToRestartWithoutLeakingClipboard() {
        var state = ViewerClipboardPollingState()
        XCTAssertNotNil(state.begin(sessionEpoch: 3, currentChangeCount: 1))
        XCTAssertTrue(state.stop(sessionEpoch: 3))
        XCTAssertNotNil(state.begin(sessionEpoch: 3, currentChangeCount: 9))
        XCTAssertNil(state.observePoll(
            sessionEpoch: 3,
            changeCount: 9,
            text: "copied while disconnected"
        ).textToSend)
    }
}
