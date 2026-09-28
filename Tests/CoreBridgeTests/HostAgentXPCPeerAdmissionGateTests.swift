import Darwin
import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentXPCPeerAdmissionGateTests: XCTestCase {
    func testEligiblePeerRequiresEveryKernelIdentityFactAndExactPath() {
        let recorder = XPCPeerPathRecorder(identity: productExecutableIdentity)

        XCTAssertEqual(
            HostAgentXPCPeerAdmissionGate.assess(
                processIdentifier: 4_242, effectiveUserIdentifier: 501,
                auditSessionIdentifier: 100_001, localProcessIdentifier: 4_241,
                localEffectiveUserIdentifier: 501, localAuditSessionIdentifier: 100_001,
                resolveExecutable: recorder.resolve), .eligible)
        XCTAssertEqual(recorder.processIdentifiers, [4_242])
    }

    func testRejectsInvalidOrSelfProcessBeforeResolvingPath() {
        for processIdentifier in [pid_t(-1), 0, 1, 4_241] {
            let recorder = XPCPeerPathRecorder(identity: productExecutableIdentity)
            XCTAssertEqual(
                HostAgentXPCPeerAdmissionGate.assess(
                    processIdentifier: processIdentifier, effectiveUserIdentifier: 501,
                    auditSessionIdentifier: 100_001, localProcessIdentifier: 4_241,
                    localEffectiveUserIdentifier: 501, localAuditSessionIdentifier: 100_001,
                    resolveExecutable: recorder.resolve), .invalidProcess)
            XCTAssertTrue(recorder.processIdentifiers.isEmpty)
        }
    }

    func testRejectsDifferentUserBeforeSessionAndPath() {
        let recorder = XPCPeerPathRecorder(identity: productExecutableIdentity)

        XCTAssertEqual(
            HostAgentXPCPeerAdmissionGate.assess(
                processIdentifier: 4_242, effectiveUserIdentifier: 502,
                auditSessionIdentifier: 100_001, localProcessIdentifier: 4_241,
                localEffectiveUserIdentifier: 501, localAuditSessionIdentifier: 100_001,
                resolveExecutable: recorder.resolve), .differentUser)
        XCTAssertTrue(recorder.processIdentifiers.isEmpty)
    }

    func testRejectsUnavailableOrDifferentAuditSessionBeforePath() {
        let sessions: [(peer: au_asid_t, local: au_asid_t)] = [
            (0, 100_001), (100_001, 0), (100_002, 100_001),
        ]

        for session in sessions {
            let recorder = XPCPeerPathRecorder(identity: productExecutableIdentity)
            XCTAssertEqual(
                HostAgentXPCPeerAdmissionGate.assess(
                    processIdentifier: 4_242, effectiveUserIdentifier: 501,
                    auditSessionIdentifier: session.peer, localProcessIdentifier: 4_241,
                    localEffectiveUserIdentifier: 501, localAuditSessionIdentifier: session.local,
                    resolveExecutable: recorder.resolve), .differentAuditSession)
            XCTAssertTrue(recorder.processIdentifiers.isEmpty)
        }
    }

    func testRejectsUnavailableAndNonCanonicalExecutablePaths() {
        let identities: [HostAgentXPCExecutableIdentity?] = [
            nil,
            HostAgentXPCExecutableIdentity(
                reportedPath: "/Users/test/Applications/FarPane.app/Contents/MacOS/RustDeskNative",
                resolvedPath: "/Users/test/Applications/FarPane.app/Contents/MacOS/RustDeskNative"),
            HostAgentXPCExecutableIdentity(
                reportedPath: productExecutablePath,
                resolvedPath: "/private/tmp/FarPane.app/Contents/MacOS/RustDeskNative"),
            HostAgentXPCExecutableIdentity(
                reportedPath: productExecutablePath + "-helper",
                resolvedPath: productExecutablePath + "-helper"),
        ]

        for identity in identities {
            let recorder = XPCPeerPathRecorder(identity: identity)
            let expectedStatus: HostAgentXPCPeerAdmissionStatus =
                identity == nil ? .executableUnavailable : .invalidExecutable
            XCTAssertEqual(
                HostAgentXPCPeerAdmissionGate.assess(
                    processIdentifier: 4_242, effectiveUserIdentifier: 501,
                    auditSessionIdentifier: 100_001, localProcessIdentifier: 4_241,
                    localEffectiveUserIdentifier: 501, localAuditSessionIdentifier: 100_001,
                    resolveExecutable: recorder.resolve), expectedStatus)
        }
    }

    func testProductResolversUseCurrentKernelAndProcessAuthorities() throws {
        let auditSession = try XCTUnwrap(
            HostAgentXPCPeerAdmissionGate.currentAuditSessionIdentifier())
        XCTAssertGreaterThan(auditSession, 0)

        let executable = try XCTUnwrap(
            HostAgentXPCPeerAdmissionGate.resolveExecutable(processIdentifier: getpid()))
        XCTAssertFalse(executable.reportedPath.isEmpty)
        XCTAssertTrue(executable.reportedPath.hasPrefix("/"))
        XCTAssertFalse(executable.resolvedPath.isEmpty)
    }

    private var productExecutableIdentity: HostAgentXPCExecutableIdentity {
        HostAgentXPCExecutableIdentity(
            reportedPath: productExecutablePath, resolvedPath: productExecutablePath)
    }

    private var productExecutablePath: String {
        "/Applications/FarPane.app/Contents/MacOS/RustDeskNative"
    }
}

private final class XPCPeerPathRecorder {
    private let identity: HostAgentXPCExecutableIdentity?
    private(set) var processIdentifiers: [pid_t] = []

    init(identity: HostAgentXPCExecutableIdentity?) { self.identity = identity }

    func resolve(_ processIdentifier: pid_t) -> HostAgentXPCExecutableIdentity? {
        processIdentifiers.append(processIdentifier)
        return identity
    }
}
