@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCListenerAdmissionShellTests: XCTestCase {
    func testProductShellStartsConfiguredButInactiveAndSanitized() {
        let shell = HostAgentXPCListenerAdmissionShell.makeProductShell()

        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: 0,
                rejectedPeerIdentityCount: 0,
                rejectedInterfaceUnavailableCount: 0
            )
        )
    }

    func testRejectsEveryIneligiblePeerWithoutInterfaceFallback() {
        let statuses: [HostAgentXPCPeerAdmissionStatus] = [
            .invalidProcess,
            .differentUser,
            .localAuthorityUnavailable,
            .differentAuditSession,
            .executableUnavailable,
            .invalidExecutable,
        ]
        let listener = NSXPCListener.anonymous()
        let recorder = XPCAdmissionStatusRecorder(statuses: statuses)
        let shell = HostAgentXPCListenerAdmissionShell(
            listener: listener,
            assessConnection: recorder.assess
        )

        for _ in statuses {
            XCTAssertFalse(shell.listener(
                listener,
                shouldAcceptNewConnection: NSXPCConnection()
            ))
        }

        XCTAssertEqual(recorder.assessmentCount, statuses.count)
        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: UInt64(statuses.count),
                rejectedPeerIdentityCount: UInt64(statuses.count),
                rejectedInterfaceUnavailableCount: 0
            )
        )
    }

    func testEligiblePeerStillFailsClosedUntilTypedInterfaceExists() {
        let listener = NSXPCListener.anonymous()
        let shell = HostAgentXPCListenerAdmissionShell(
            listener: listener,
            assessConnection: { _ in .eligible }
        )

        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: 1,
                rejectedPeerIdentityCount: 0,
                rejectedInterfaceUnavailableCount: 1
            )
        )
    }

    func testForeignListenerIsRejectedBeforeAssessingConnection() {
        let ownedListener = NSXPCListener.anonymous()
        var assessmentCount = 0
        let shell = HostAgentXPCListenerAdmissionShell(
            listener: ownedListener,
            assessConnection: { _ in
                assessmentCount += 1
                return .eligible
            }
        )

        XCTAssertFalse(shell.listener(
            NSXPCListener.anonymous(),
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(assessmentCount, 0)
        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: 1,
                rejectedPeerIdentityCount: 1,
                rejectedInterfaceUnavailableCount: 0
            )
        )
    }

    func testProductSourceOwnsNoActivationOrWireSurface() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentXPCListenerAdmissionShell.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "HostAgentXPCListenerFactory.makeListener()"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentXPCPeerAdmissionGate.assess"
        ))
        XCTAssertFalse(source.contains(".activate()"))
        XCTAssertFalse(source.contains(".resume()"))
        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("exportedInterface"))
        XCTAssertFalse(source.contains("exportedObject"))
        XCTAssertFalse(source.contains("remoteObjectInterface"))
    }
}

private final class XPCAdmissionStatusRecorder {
    private var statuses: [HostAgentXPCPeerAdmissionStatus]
    private(set) var assessmentCount = 0

    init(statuses: [HostAgentXPCPeerAdmissionStatus]) {
        self.statuses = statuses
    }

    func assess(_ connection: NSXPCConnection)
        -> HostAgentXPCPeerAdmissionStatus
    {
        assessmentCount += 1
        return statuses.removeFirst()
    }
}
