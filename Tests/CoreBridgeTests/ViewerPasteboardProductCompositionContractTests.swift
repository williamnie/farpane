import Foundation
import XCTest

final class ViewerPasteboardProductCompositionContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAppKitOwnerIsTheOnlySwiftPasteboardBoundary() throws {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let ownerURL = sources.appendingPathComponent(
            "RustDeskNative/ViewerPasteboardOwner.swift"
        )
        let owner = try String(contentsOf: ownerURL, encoding: .utf8)
        XCTAssertTrue(owner.contains("private let pasteboard: NSPasteboard"))
        XCTAssertTrue(owner.contains("pasteboard: NSPasteboard = .general"))
        XCTAssertTrue(owner.contains("ViewerClipboardTextPolicy.accepts(text)"))
        XCTAssertTrue(owner.contains("ViewerClipboardRichTextPolicy.accepts(payload)"))
        XCTAssertTrue(owner.contains("pasteboard.pasteboardItems?.count == 1"))
        XCTAssertTrue(owner.contains("pasteboard.writeObjects([item])"))
        XCTAssertTrue(owner.contains("resultingChangeCount: pasteboard.changeCount"))
        XCTAssertTrue(owner.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertFalse(owner.contains("print("))

        let swiftFiles = try FileManager.default.subpathsOfDirectory(
            atPath: sources.path
        ).filter { $0.hasSuffix(".swift") }
        let pasteboardOwners = try swiftFiles.filter { relativePath in
            let contents = try String(
                contentsOf: sources.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            return contents.contains("import AppKit")
                && contents.contains("NSPasteboard")
        }.sorted()
        XCTAssertEqual(
            pasteboardOwners,
            ["RustDeskNative/ViewerPasteboardOwner.swift"]
        )
    }

    func testProductExplicitlyEnablesBothDirectionsAcrossRecovery() throws {
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(app.components(separatedBy: "receiveClipboardText: true").count - 1, 3)
        XCTAssertEqual(app.components(separatedBy: "sendClipboardText: true").count - 1, 3)
        XCTAssertEqual(app.components(separatedBy: "receiveClipboardRichText: true").count - 1, 3)
        XCTAssertEqual(app.components(separatedBy: "sendClipboardRichText: true").count - 1, 3)
        XCTAssertTrue(app.contains("receiveTextEnabled: configuration.receiveClipboardText"))
        XCTAssertTrue(app.contains("sendTextEnabled: configuration.sendClipboardText"))
        XCTAssertTrue(app.contains("receiveRichTextEnabled: configuration.receiveClipboardRichText"))
        XCTAssertTrue(app.contains("sendRichTextEnabled: configuration.sendClipboardRichText"))
        XCTAssertTrue(app.contains("onClipboardText: { [weak self] text in"))
        XCTAssertTrue(app.contains("onClipboardRichText: { [weak self] payload in"))
        XCTAssertTrue(app.contains("coreGeneration == viewerCoreGeneration"))
        XCTAssertTrue(app.contains("clipboardSessionEpoch == viewerClipboardSessionEpoch"))
    }

    func testStreamingAndTeardownBoundPasteboardLifecycle() throws {
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("viewerPasteboardOwner.activate("))
        XCTAssertTrue(app.contains("viewerPasteboardOwner.suspend("))
        XCTAssertTrue(app.contains("viewerPasteboardOwner.receiveRemoteText("))
        XCTAssertTrue(app.contains("viewerPasteboardOwner.receiveRemoteRichText("))

        let homeStart = try XCTUnwrap(app.range(of: "private func showHomeUI("))
        let homeTail = app[homeStart.lowerBound...]
        let homeStop = try XCTUnwrap(homeTail.range(of: "stopViewerClipboard()"))
        let homeDisconnect = try XCTUnwrap(homeTail.range(of: "coreClient?.disconnect()"))
        XCTAssertLessThan(homeStop.lowerBound, homeDisconnect.lowerBound)

        let finishStart = try XCTUnwrap(app.range(of: "private func finish()"))
        let finishTail = app[finishStart.lowerBound...]
        let finishStop = try XCTUnwrap(finishTail.range(of: "stopViewerClipboard()"))
        let finishDisconnect = try XCTUnwrap(finishTail.range(of: "coreClient?.disconnect()"))
        XCTAssertLessThan(finishStop.lowerBound, finishDisconnect.lowerBound)
    }
}
