@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCHandshakeAdmissionLifecycleTests: XCTestCase {
    func testWaitingIdentityRejectsEligiblePeerWithoutConfiguringConnection() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: false)
        let recorder = HandshakeConnectionRecorder()
        let shell = makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 0)
        XCTAssertEqual(recorder.resumeCount, 0)
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

    func testReadyIdentityInstallsOnlyHandshakeServiceThenResumes() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 1)
        XCTAssertEqual(recorder.resumeCount, 1)
        XCTAssertEqual(
            recorder.interfaceProtocolName,
            "RDNHostAgentXPCHandshakeService"
        )
        let response = try recorder.performValidHandshake()
        XCTAssertEqual(response.agentBuildID, "agent-build")
        XCTAssertEqual(response.hostInstanceID, "host-a")
        XCTAssertEqual(response.agentBootID, validBootID)
        XCTAssertEqual(
            shell.snapshot().activeHandshakeConnectionCount,
            1
        )
    }

    func testInterruptionAndInvalidationCleanupAreIdempotent() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )
        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        recorder.triggerInterruption()
        recorder.triggerInvalidation()

        XCTAssertEqual(recorder.invalidateCount, 1)
        XCTAssertEqual(shell.snapshot().activeHandshakeConnectionCount, 0)
        XCTAssertEqual(shell.snapshot().closedHandshakeConnectionCount, 1)
    }

    func testAuthorityInvalidationClosesConnectionsAndPermanentlyRejectsNewOnes() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )
        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        authority.invalidate()

        XCTAssertEqual(recorder.invalidateCount, 1)
        XCTAssertTrue(shell.snapshot().cancelled)
        XCTAssertEqual(shell.snapshot().activeHandshakeConnectionCount, 0)
        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 1)
        XCTAssertEqual(recorder.resumeCount, 1)
    }

    func testActiveHandshakeConnectionCapacityFailsClosedBeforeConfiguration() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        for _ in 0..<HostAgentXPCListenerAdmissionShell
            .maximumActiveHandshakeConnectionCount
        {
            XCTAssertTrue(shell.listener(
                listener,
                shouldAcceptNewConnection: NSXPCConnection()
            ))
        }
        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        XCTAssertEqual(
            recorder.configureCount,
            HostAgentXPCListenerAdmissionShell
                .maximumActiveHandshakeConnectionCount
        )
        XCTAssertEqual(recorder.resumeCount, recorder.configureCount)
        XCTAssertEqual(
            shell.snapshot().activeHandshakeConnectionCount,
            UInt64(
                HostAgentXPCListenerAdmissionShell
                    .maximumActiveHandshakeConnectionCount
            )
        )
        XCTAssertEqual(shell.snapshot().rejectedHandshakeUnavailableCount, 1)
    }

    private let validBootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeAuthority(
        ready: Bool
    ) throws -> HostAgentXPCProcessIdentityAuthority {
        let authority = try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: validBootID
        )
        if ready {
            XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        }
        return authority
    }

    private func makeShell(
        listener: NSXPCListener,
        authority: HostAgentXPCProcessIdentityAuthority,
        recorder: HandshakeConnectionRecorder
    ) -> HostAgentXPCListenerAdmissionShell {
        HostAgentXPCListenerAdmissionShell(
            listener: listener,
            identityAuthority: authority,
            assessConnection: { _ in .eligible },
            nowUnixMilliseconds: { 20 },
            configureConnection: recorder.configure,
            resumeConnection: recorder.resume,
            invalidateConnection: recorder.invalidate
        )
    }
}

private final class HandshakeConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configuredInterface: NSXPCInterface?
    private var configuredHandler: HostAgentXPCHandshakeHandler?
    private var interruptionHandler: (() -> Void)?
    private var invalidationHandler: (() -> Void)?
    private var configurations = 0
    private var resumes = 0
    private var invalidations = 0

    var configureCount: Int { locked { configurations } }
    var resumeCount: Int { locked { resumes } }
    var invalidateCount: Int { locked { invalidations } }
    var interfaceProtocolName: String? {
        locked {
            configuredInterface.map { NSStringFromProtocol($0.protocol) }
        }
    }

    func configure(
        _ connection: NSXPCConnection,
        _ interface: NSXPCInterface,
        _ handler: HostAgentXPCHandshakeHandler,
        _ lifecycle: HostAgentXPCListenerAdmissionShell
            .ConnectionLifecycleHandlers
    ) {
        lock.lock()
        configurations += 1
        configuredInterface = interface
        configuredHandler = handler
        interruptionHandler = lifecycle.onInterruption
        invalidationHandler = lifecycle.onInvalidation
        lock.unlock()
    }

    func resume(_ connection: NSXPCConnection) {
        lock.lock()
        resumes += 1
        lock.unlock()
    }

    func invalidate(_ connection: NSXPCConnection) {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }

    func triggerInterruption() {
        locked { interruptionHandler }?()
    }

    func triggerInvalidation() {
        locked { invalidationHandler }?()
    }

    func performValidHandshake() throws
        -> HostAgentXPCWireHandshakeResponse
    {
        let handler = try XCTUnwrap(locked { configuredHandler })
        let request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            appBuildID: "app-build",
            knownHostInstanceID: nil,
            knownAgentBootID: nil,
            sentAtUnixMilliseconds: 10
        )
        let response = try XCTUnwrap(handler.response(for: request.encoded()))
        return try HostAgentXPCWireHandshakeResponse.decode(response)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
