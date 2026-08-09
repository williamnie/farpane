import Foundation
import XCTest

final class HostAgentNSWorkspaceSleepWakeIngressContractTests: XCTestCase {
    func testProductIngressUsesExactNSWorkspacePowerNotifications() throws {
        let source = try productSource(
            "HostAgentNSWorkspaceSleepWakeIngress.swift"
        )

        XCTAssertTrue(source.contains("import AppKit"))
        XCTAssertTrue(source.contains(
            "NSWorkspace.shared.notificationCenter"
        ))
        XCTAssertTrue(source.contains(
            "NSWorkspace.willSleepNotification"
        ))
        XCTAssertTrue(source.contains(
            "NSWorkspace.didWakeNotification"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentSleepWakeNotificationDeliveryOwner("
        ))
        XCTAssertTrue(source.contains("composition.systemWillSleep()"))
        XCTAssertTrue(source.contains("composition.systemDidWake()"))
        XCTAssertFalse(source.contains("NSWorkspace.screensDidSleepNotification"))
        XCTAssertFalse(source.contains("NSWorkspace.screensDidWakeNotification"))
    }

    func testIngressOwnsRunLoopAndDrainsBeforeObserverThreadExit() throws {
        let source = try productSource(
            "HostAgentNSWorkspaceSleepWakeIngress.swift"
        )

        XCTAssertTrue(source.contains("Thread { [weak self] in"))
        XCTAssertTrue(source.contains("RunLoop.current.add(keepAlivePort"))
        XCTAssertTrue(source.contains("CFRunLoopRun()"))
        XCTAssertTrue(source.contains("CFRunLoopStop(runLoop)"))
        XCTAssertTrue(source.contains("CFRunLoopWakeUp(runLoop)"))
        XCTAssertTrue(source.contains("removeObservers(tokens)"))
        XCTAssertTrue(source.contains("deliveryOwner.cancelAndWait()"))
        XCTAssertTrue(source.contains(
            "case .failed = deliveryOwner.stateSnapshot()"
        ))
        XCTAssertTrue(source.contains("requestProcessTermination()"))
        XCTAssertFalse(source.contains("NSApplication.shared"))
        XCTAssertFalse(source.contains("DispatchQueue.main"))

        let cancelStart = try XCTUnwrap(source.range(
            of: "case .starting, .running:"
        ))
        let cancelTail = source[cancelStart.lowerBound...]
        let observerRemoval = try XCTUnwrap(cancelTail.range(
            of: "removeObservers(tokens)"
        ))
        let drain = try XCTUnwrap(cancelTail.range(
            of: "deliveryOwner.cancelAndWait()"
        ))
        let stop = try XCTUnwrap(cancelTail.range(
            of: "CFRunLoopStop(runLoop)"
        ))
        XCTAssertLessThan(observerRemoval.lowerBound, drain.lowerBound)
        XCTAssertLessThan(drain.lowerBound, stop.lowerBound)
    }

    func testProcessOwnerStartsAndCancelsIngressWithComposition() throws {
        let source = try productSource(
            "HostAgentSleepWakeRecoveryProcessOwner.swift"
        )

        XCTAssertTrue(source.contains(
            "HostAgentNSWorkspaceSleepWakeIngress.makeProduct("
        ))
        XCTAssertTrue(source.contains("guard notificationIngress.start()"))
        let cancelStart = try XCTUnwrap(source.range(
            of: "case .installed:"
        ))
        let cancelTail = source[cancelStart.lowerBound...]
        let ingressCancel = try XCTUnwrap(cancelTail.range(
            of: "notificationIngress?.cancelAndWait()"
        ))
        let compositionCancel = try XCTUnwrap(cancelTail.range(
            of: "composition?.cancel()"
        ))
        XCTAssertLessThan(ingressCancel.lowerBound, compositionCancel.lowerBound)
    }

    private func productSource(_ name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/\(name)"
            ),
            encoding: .utf8
        )
    }
}
