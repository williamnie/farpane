@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCListenerAdmissionShellTests: XCTestCase {
    func testProductShellStartsConfiguredButInactiveAndSanitized() throws {
        let shell = HostAgentXPCListenerAdmissionShell.makeProductShell(
            identityAuthority: try makeAuthority()
        )

        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: 0,
                rejectedPeerIdentityCount: 0,
                rejectedHandshakeUnavailableCount: 0,
                acceptedHandshakeConnectionCount: 0,
                activeHandshakeConnectionCount: 0,
                closedHandshakeConnectionCount: 0,
                cancelled: false
            )
        )
    }

    func testRejectsEveryIneligiblePeerWithoutInterfaceFallback() throws {
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
        let shell = makeShell(
            listener: listener,
            identityAuthority: try makeAuthority(),
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
                rejectedHandshakeUnavailableCount: 0,
                acceptedHandshakeConnectionCount: 0,
                activeHandshakeConnectionCount: 0,
                closedHandshakeConnectionCount: 0,
                cancelled: false
            )
        )
    }

    func testEligiblePeerStillFailsClosedUntilIdentityIsReady() throws {
        let listener = NSXPCListener.anonymous()
        let shell = makeShell(
            listener: listener,
            identityAuthority: try makeAuthority(),
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
                rejectedHandshakeUnavailableCount: 1,
                acceptedHandshakeConnectionCount: 0,
                activeHandshakeConnectionCount: 0,
                closedHandshakeConnectionCount: 0,
                cancelled: false
            )
        )
    }

    func testForeignListenerIsRejectedBeforeAssessingConnection() throws {
        let ownedListener = NSXPCListener.anonymous()
        var assessmentCount = 0
        let shell = makeShell(
            listener: ownedListener,
            identityAuthority: try makeAuthority(),
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
                rejectedHandshakeUnavailableCount: 0,
                acceptedHandshakeConnectionCount: 0,
                activeHandshakeConnectionCount: 0,
                closedHandshakeConnectionCount: 0,
                cancelled: false
            )
        )
    }

    func testProductSourceOwnsHandshakeOnlySurfaceWithoutListenerActivation() throws {
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
        XCTAssertTrue(source.contains("connection.resume()"))
        XCTAssertTrue(source.contains(
            "HostAgentXPCHandshakeInterfaceFactory.makeInterface()"
        ))
        XCTAssertTrue(source.contains("connection.exportedInterface"))
        XCTAssertTrue(source.contains("connection.exportedObject"))
        XCTAssertTrue(source.contains("connection.interruptionHandler"))
        XCTAssertTrue(source.contains("connection.invalidationHandler"))
        XCTAssertFalse(source.contains("listener.activate()"))
        XCTAssertFalse(source.contains("listener.resume()"))
        XCTAssertFalse(source.contains("remoteObjectInterface"))
        XCTAssertFalse(source.contains("HostAgentSnapshotProjection"))
        XCTAssertFalse(source.contains("HostCoreEvent"))
        XCTAssertFalse(source.contains("Host command"))
    }

    private func makeAuthority() throws
        -> HostAgentXPCProcessIdentityAuthority
    {
        try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
        )
    }

    private func makeShell(
        listener: NSXPCListener,
        identityAuthority: HostAgentXPCProcessIdentityAuthority,
        assessConnection: @escaping HostAgentXPCListenerAdmissionShell
            .ConnectionAssessor
    ) -> HostAgentXPCListenerAdmissionShell {
        HostAgentXPCListenerAdmissionShell(
            listener: listener,
            identityAuthority: identityAuthority,
            assessConnection: assessConnection,
            nowUnixMilliseconds: { 20 },
            configureConnection: { _, _, _, _ in },
            resumeConnection: { _ in },
            invalidateConnection: { _ in }
        )
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
