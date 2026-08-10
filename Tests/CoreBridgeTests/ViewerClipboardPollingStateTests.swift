import XCTest
@testable import CoreBridge

final class ViewerClipboardPollingStateTests: XCTestCase {
    private var structurallyValidOnePixelPNG: Data {
        Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01, 0x49, 0x44, 0x41, 0x54,
            0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
            0x00, 0x00, 0x00, 0x00,
        ])
    }

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

    func testChangeDecisionDoesNotRequirePasteboardReadAndRetainsBackoff() {
        var state = ViewerClipboardPollingState()
        XCTAssertEqual(state.begin(sessionEpoch: 5, currentChangeCount: 10), 125)
        XCTAssertEqual(
            state.observeChange(sessionEpoch: 5, changeCount: 10),
            ViewerClipboardChangeDecision(
                didChange: false,
                nextDelayMilliseconds: 250
            )
        )
        XCTAssertEqual(
            state.observeChange(sessionEpoch: 5, changeCount: 11),
            ViewerClipboardChangeDecision(
                didChange: true,
                nextDelayMilliseconds: 125
            )
        )
        XCTAssertNil(
            state.observeChange(sessionEpoch: 4, changeCount: 12)
                .nextDelayMilliseconds
        )
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

    func testRichTextPolicyRequiresBoundedAtomicRichRepresentation() {
        XCTAssertFalse(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(plainText: "plain")
        ))
        XCTAssertTrue(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(
                plainText: "plain",
                rtf: "{\\rtf1 rich}",
                html: "<b>rich</b>"
            )
        ))
        XCTAssertFalse(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(rtf: "bad\0rtf")
        ))
        XCTAssertFalse(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(html: "")
        ))
        XCTAssertFalse(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(
                rtf: String(repeating: "a", count: 1024 * 1024 + 1)
            )
        ))
        XCTAssertFalse(ViewerClipboardRichTextPolicy.accepts(
            CoreClipboardRichTextPayload(
                plainText: String(repeating: "a", count: 64 * 1024 + 1),
                html: "<b>rich</b>"
            )
        ))
    }

    func testImagePolicyRequiresCanonicalBoundedSemanticPayload() {
        XCTAssertTrue(ViewerClipboardImagePolicy.accepts(.rgba(
            width: 1,
            height: 1,
            pixels: Data([1, 2, 3, 255])
        )))
        XCTAssertFalse(ViewerClipboardImagePolicy.accepts(.rgba(
            width: 1,
            height: 1,
            pixels: Data([1, 2, 3])
        )))
        XCTAssertTrue(ViewerClipboardImagePolicy.accepts(
            .png(structurallyValidOnePixelPNG)
        ))
        XCTAssertFalse(ViewerClipboardImagePolicy.accepts(
            .png(Data([0x89, 0x50, 0x4e, 0x47]))
        ))
        XCTAssertTrue(ViewerClipboardImagePolicy.accepts(
            .svg("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
        ))
        XCTAssertFalse(ViewerClipboardImagePolicy.accepts(
            .svg("<!DOCTYPE svg><svg></svg>")
        ))
        XCTAssertTrue(ViewerClipboardImagePolicy.acceptsDimensions(
            width: 7_680,
            height: 4_320
        ))
        XCTAssertFalse(ViewerClipboardImagePolicy.acceptsDimensions(
            width: 8_192,
            height: 8_192
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
