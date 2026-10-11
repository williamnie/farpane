import CoreBridge
import ViewerInput
import XCTest

final class ViewerTextCommitSenderTests: XCTestCase {
    func testDisabledCompatibilityOnlySendsOriginalUnicodeText() {
        var calls: [RecordedCall] = []

        let result = ViewerTextCommitSender.send(
            "中文A🙂", ubuntuPasteCompatibility: false,
            sendText: {
                calls.append(.text($0))
                return 0
            },
            sendKey: {
                calls.append(.key($0))
                return 0
            })

        XCTAssertEqual(result, 0)
        XCTAssertEqual(calls, [.text("中文A🙂")])
    }

    func testEnabledCompatibilityDoesNotPasteASCII() {
        for text in ["FarPane 123", "\t\n", ""] {
            var calls: [RecordedCall] = []
            let result = ViewerTextCommitSender.send(
                text, ubuntuPasteCompatibility: true,
                sendText: {
                    calls.append(.text($0))
                    return 0
                },
                sendKey: {
                    calls.append(.key($0))
                    return 0
                })

            XCTAssertEqual(result, 0)
            XCTAssertEqual(calls, [.text(text)])
        }
    }

    func testUnicodeCommitPrecedesExactlyOneCompletePasteShortcut() {
        for text in ["中文", "🙂", "A中文🙂B", "e\u{301}"] {
            var calls: [RecordedCall] = []
            let result = ViewerTextCommitSender.send(
                text, ubuntuPasteCompatibility: true,
                sendText: {
                    calls.append(.text($0))
                    return 0
                },
                sendKey: {
                    calls.append(.key($0))
                    return 0
                })

            XCTAssertEqual(result, 0)
            XCTAssertEqual(calls, [.text(text), .pasteDown, .pasteUp])
        }
    }

    func testFailedTextCommitDoesNotSendPasteShortcut() {
        for failure: Int32 in [-3, -4, -6] {
            var calls: [RecordedCall] = []
            let result = ViewerTextCommitSender.send(
                "中文", ubuntuPasteCompatibility: true,
                sendText: {
                    calls.append(.text($0))
                    return failure
                },
                sendKey: {
                    calls.append(.key($0))
                    return 0
                })

            XCTAssertEqual(result, failure)
            XCTAssertEqual(calls, [.text("中文")])
        }
    }

    func testFailedPasteDownStillReleasesKeyAndPreservesFirstError() {
        for releaseStatus: Int32 in [0, -3] {
            var calls: [RecordedCall] = []
            let result = ViewerTextCommitSender.send(
                "中文", ubuntuPasteCompatibility: true,
                sendText: {
                    calls.append(.text($0))
                    return 0
                },
                sendKey: {
                    calls.append(.key($0))
                    return $0.isDown ? -6 : releaseStatus
                })

            XCTAssertEqual(result, -6)
            XCTAssertEqual(calls, [.text("中文"), .pasteDown, .pasteUp])
        }
    }

    func testFailedPasteReleaseIsReported() {
        var calls: [RecordedCall] = []
        let result = ViewerTextCommitSender.send(
            "中文", ubuntuPasteCompatibility: true,
            sendText: {
                calls.append(.text($0))
                return 0
            },
            sendKey: {
                calls.append(.key($0))
                return $0.isDown ? 0 : -3
            })

        XCTAssertEqual(result, -3)
        XCTAssertEqual(calls, [.text("中文"), .pasteDown, .pasteUp])
    }
}

private enum RecordedCall: Equatable {
    case text(String)
    case keyTransition(CoreKey, Bool, CoreInputModifiers)

    static func key(_ event: CoreKeyEvent) -> Self {
        .keyTransition(event.key, event.isDown, event.modifiers)
    }

    static let pasteDown = keyTransition(.character("v"), true, [.control, .shift])
    static let pasteUp = keyTransition(.character("v"), false, [])
}
