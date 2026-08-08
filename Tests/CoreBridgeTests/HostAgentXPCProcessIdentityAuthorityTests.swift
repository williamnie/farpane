@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCProcessIdentityAuthorityTests: XCTestCase {
    func testProductAuthorityGeneratesOneStableCanonicalBootIdentity() throws {
        let authority = try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build"
        )

        XCTAssertEqual(authority.snapshot(), .waitingForHostInstance)
        XCTAssertEqual(authority.bind(hostInstanceID: "host-instance"), .bound)
        guard case .ready(let firstIdentity) = authority.snapshot() else {
            return XCTFail("expected ready identity")
        }
        XCTAssertEqual(firstIdentity.agentBuildID, "agent-build")
        XCTAssertEqual(firstIdentity.hostInstanceID, "host-instance")
        XCTAssertEqual(firstIdentity.agentBootID.utf8.count, 36)
        XCTAssertEqual(
            UUID(uuidString: firstIdentity.agentBootID)?.uuidString.lowercased(),
            firstIdentity.agentBootID
        )

        XCTAssertEqual(
            authority.bind(hostInstanceID: "host-instance"),
            .unchanged
        )
        XCTAssertEqual(authority.snapshot(), .ready(firstIdentity))
    }

    func testRejectsBuildBeforeGeneratingBootIdentityAndRejectsInvalidBoot() {
        var generationCount = 0
        XCTAssertThrowsError(try HostAgentXPCProcessIdentityAuthority(
            agentBuildID: "agent/build",
            generateAgentBootID: {
                generationCount += 1
                return validBootID
            }
        ))
        XCTAssertEqual(generationCount, 0)

        XCTAssertThrowsError(try HostAgentXPCProcessIdentityAuthority(
            agentBuildID: "agent-build",
            generateAgentBootID: { "not-a-uuid" }
        ))
    }

    func testInvalidHostIdentityPermanentlyInvalidatesAuthority() throws {
        let authority = try makeAuthority()

        XCTAssertEqual(
            authority.bind(hostInstanceID: "host/invalid"),
            .rejected(.invalidHostInstance)
        )
        XCTAssertEqual(authority.snapshot(), .invalidated)
        XCTAssertEqual(
            authority.bind(hostInstanceID: "host-instance"),
            .rejected(.invalidated)
        )
        XCTAssertEqual(
            authority.bind(hostInstanceID: "still/invalid"),
            .rejected(.invalidated)
        )
    }

    func testConflictingHostIdentityPermanentlyInvalidatesAuthority() throws {
        let authority = try makeAuthority()

        XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        XCTAssertEqual(
            authority.bind(hostInstanceID: "host-b"),
            .rejected(.conflictingHostInstance)
        )
        XCTAssertEqual(authority.snapshot(), .invalidated)
        XCTAssertEqual(
            authority.bind(hostInstanceID: "host-a"),
            .rejected(.invalidated)
        )
    }

    func testExplicitInvalidationClearsReadyIdentity() throws {
        let authority = try makeAuthority()
        XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)

        authority.invalidate()

        XCTAssertEqual(authority.snapshot(), .invalidated)
        authority.invalidate()
        XCTAssertEqual(authority.snapshot(), .invalidated)
    }

    func testConcurrentSameHostBindingProducesOneStableIdentity() throws {
        let authority = try makeAuthority()
        let resultLock = NSLock()
        var results: [HostAgentXPCProcessIdentityBindResult] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "HostAgentXPCProcessIdentityAuthorityTests.concurrent",
            attributes: .concurrent
        )

        for _ in 0..<64 {
            group.enter()
            queue.async {
                let result = authority.bind(hostInstanceID: "host-a")
                resultLock.lock()
                results.append(result)
                resultLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(results.filter { $0 == .bound }.count, 1)
        XCTAssertEqual(results.filter { $0 == .unchanged }.count, 63)
        guard case .ready(let identity) = authority.snapshot() else {
            return XCTFail("expected ready identity")
        }
        XCTAssertEqual(identity.hostInstanceID, "host-a")
        XCTAssertEqual(identity.agentBootID, validBootID)
    }

    func testProductSourceCannotReadMutableOrExternalIdentityInputs() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCProcessIdentityAuthority.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("UUID().uuidString.lowercased()"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("Bundle.main"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
    }

    private let validBootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeAuthority() throws
        -> HostAgentXPCProcessIdentityAuthority
    {
        try HostAgentXPCProcessIdentityAuthority(
            agentBuildID: "agent-build",
            generateAgentBootID: { validBootID }
        )
    }
}
