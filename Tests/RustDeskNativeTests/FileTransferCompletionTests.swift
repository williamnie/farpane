import AppKit
import CoreBridge
import XCTest

@testable import RustDeskNative

final class FileTransferCompletionTests: XCTestCase {
    @MainActor func testOpenFolderButtonUsesCapturedDestination() async throws {
        _ = NSApplication.shared
        let opened = expectation(description: "open selected directory")
        let directory = URL(fileURLWithPath: "/tmp/FarPane Receive", isDirectory: true)
        let presenter = FileTransferCompletionPresenter(openDirectory: { url in
            XCTAssertEqual(url, directory)
            opened.fulfill()
            return true
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        presenter.show(FileTransferCompletion(receiving: true, directory: directory), on: window)
        let alert = try XCTUnwrap(presenter.activeAlert)
        window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        await fulfillment(of: [opened], timeout: 2)
        window.close()
    }

    @MainActor func testReceiveAlertOffersFolderAndSendAlertDoesNot() {
        let directory = URL(fileURLWithPath: "/tmp/FarPane Receive", isDirectory: true)
        let receive = FileTransferCompletionPresenter.makeAlert(
            FileTransferCompletion(receiving: true, directory: directory))
        XCTAssertEqual(receive.messageText, "文件接收成功")
        XCTAssertEqual(receive.buttons.map(\.title), ["打开所在文件夹", "关闭"])
        XCTAssertTrue(receive.informativeText.contains(directory.path))
        let send = FileTransferCompletionPresenter.makeAlert(
            FileTransferCompletion(receiving: false, directory: nil))
        XCTAssertEqual(send.messageText, "文件发送成功")
        XCTAssertEqual(send.buttons.map(\.title), ["好"])
    }

    @MainActor func testSuccessSurvivesRearmAndRepeatedTerminalEventDoesNotNotifyAgain() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.window = window
        delegate.viewerFileTransferActiveTransferID = 1
        delegate.viewerFileTransferActiveDirection = .download
        delegate.viewerFileTransferDestination = URL(fileURLWithPath: "/tmp/FarPane Receive")
        let event = ViewerFileTransferSessionEvent.finished(
            sessionEpoch: 1, transferID: 1, outcome: .completed)
        delegate.handleViewerFileTransferSessionEvent(event)
        let alert = try XCTUnwrap(delegate.fileTransferCompletionPresenter.activeAlert)
        XCTAssertTrue(alert.informativeText.contains("/tmp/FarPane Receive"))
        XCTAssertNil(delegate.viewerFileTransferDestination)
        XCTAssertNil(delegate.viewerFileTransferActiveTransferID)
        delegate.handleViewerFileTransferSessionEvent(event)
        XCTAssertTrue(delegate.fileTransferCompletionPresenter.activeAlert === alert)
        window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        window.close()
    }

    @MainActor func testFailureCancellationAndForeignTransferNeverShowSuccess() {
        let delegate = AppDelegate()
        for outcome: ViewerFileTransferSessionOutcome in [.cancelled, .failed(.connectionClosed)] {
            delegate.viewerFileTransferActiveTransferID = 1
            delegate.viewerFileTransferActiveDirection = .download
            delegate.viewerFileTransferDestination = URL(fileURLWithPath: "/tmp/FarPane Receive")
            delegate.handleViewerFileTransferSessionEvent(
                .finished(sessionEpoch: 1, transferID: 1, outcome: outcome))
            XCTAssertNil(delegate.fileTransferCompletionPresenter.activeAlert)
            XCTAssertNil(delegate.viewerFileTransferDestination)
        }
        delegate.viewerFileTransferActiveTransferID = 2
        delegate.handleViewerFileTransferSessionEvent(
            .finished(sessionEpoch: 1, transferID: 1, outcome: .completed))
        XCTAssertEqual(delegate.viewerFileTransferActiveTransferID, 2)
        XCTAssertNil(delegate.fileTransferCompletionPresenter.activeAlert)
    }
}
