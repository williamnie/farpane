@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCProcessIdentityAuthorityTests: XCTestCase {
    func testProductAuthorityConsumesOneStableCanonicalBootstrapIdentity() throws {
        let authority = try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: validBootID
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

    func testRejectsInvalidBuildAndBootIdentity() {
        XCTAssertThrowsError(try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent/build",
            agentBootID: validBootID
        ))

        XCTAssertThrowsError(try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: "not-a-uuid"
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
        let recorder = IdentityInvalidationRecorder()
        XCTAssertTrue(authority.installInvalidationObserver {
            recorder.record()
        })
        XCTAssertEqual(
            authority.bind(hostInstanceID: "host-b"),
            .rejected(.conflictingHostInstance)
        )
        XCTAssertEqual(recorder.fired.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.count, 1)
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

    func testObserverInstalledAfterInvalidationIsDeliveredOnce() throws {
        let authority = try makeAuthority()
        authority.invalidate()
        let recorder = IdentityInvalidationRecorder()

        XCTAssertTrue(authority.installInvalidationObserver {
            recorder.record()
        })

        XCTAssertEqual(recorder.fired.wait(timeout: .now() + 2), .success)
        authority.invalidate()
        XCTAssertEqual(recorder.count, 1)
    }

    func testReadyIdentityAdmissionIsUnavailableBeforeBindAndAfterInvalidation() throws {
        let authority = try makeAuthority()
        var observed: [HostAgentXPCWireAgentIdentity] = []

        XCTAssertNil(authority.withReadyIdentityForAdmission { identity in
            observed.append(identity)
            return true
        })
        XCTAssertTrue(observed.isEmpty)

        XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        XCTAssertEqual(
            authority.withReadyIdentityForAdmission { identity in
                observed.append(identity)
                return identity.hostInstanceID
            },
            "host-a"
        )
        authority.invalidate()
        XCTAssertNil(authority.withReadyIdentityForAdmission { _ in true })
    }

    func testInvalidationObserverFiresOnceOutsideAdmissionCriticalSection() throws {
        let authority = try makeAuthority()
        XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        let recorder = IdentityInvalidationRecorder()
        XCTAssertTrue(authority.installInvalidationObserver {
            recorder.record()
        })
        XCTAssertFalse(authority.installInvalidationObserver({}))
        let admissionEntered = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let admissionReturned = DispatchSemaphore(value: 0)
        let invalidationStarted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = authority.withReadyIdentityForAdmission { _ in
                admissionEntered.signal()
                releaseAdmission.wait()
                return true
            }
            admissionReturned.signal()
        }
        XCTAssertEqual(admissionEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            invalidationStarted.signal()
            authority.invalidate()
        }
        XCTAssertEqual(invalidationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.fired.wait(timeout: .now() + 0.05), .timedOut)

        releaseAdmission.signal()
        XCTAssertEqual(admissionReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.fired.wait(timeout: .now() + 2), .success)
        authority.invalidate()
        XCTAssertEqual(recorder.count, 1)
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

        XCTAssertFalse(source.contains("UUID()"))
        XCTAssertFalse(source.contains("generateAgentBootID"))
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
        try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: validBootID
        )
    }
}

private final class IdentityInvalidationRecorder: @unchecked Sendable {
    let fired = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
        fired.signal()
    }
}
