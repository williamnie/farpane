import Foundation
@testable import CoreBridge
import XCTest

final class HostAgentNetworkPathRecoveryTriggerOwnerTests: XCTestCase {
    func testInitialUsablePathEstablishesBaselineWithoutRecovery() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)
        let wifi = usablePath(.wifi)

        XCTAssertEqual(owner.consume(wifi), .baselineEstablished)
        XCTAssertEqual(owner.consume(wifi), .unchanged)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .observing(path: wifi, pathGeneration: 0)
        )
        XCTAssertEqual(recorder.requests, [])
    }

    func testOutageThenSamePathTriggersExactlyOneRecovery() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)
        let wifi = usablePath(.wifi)

        XCTAssertEqual(owner.consume(wifi), .baselineEstablished)
        XCTAssertEqual(owner.consume(unavailablePath()), .unavailableRecorded)
        XCTAssertEqual(owner.consume(unavailablePath()), .unchanged)
        XCTAssertEqual(
            owner.consume(wifi),
            .recoveryTriggered(pathGeneration: 1)
        )
        XCTAssertEqual(owner.consume(wifi), .unchanged)
        XCTAssertEqual(
            recorder.requests,
            [.init(pathGeneration: 1, path: wifi)]
        )
    }

    func testOnlyMaterialUsablePathChangesTriggerMonotonicRecoveries() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)
        let wifi = usablePath(.wifi)
        let ethernet = usablePath(.wiredEthernet)
        let constrainedEthernet = usablePath(
            .wiredEthernet,
            isConstrained: true
        )

        XCTAssertEqual(owner.consume(wifi), .baselineEstablished)
        XCTAssertEqual(
            owner.consume(ethernet),
            .recoveryTriggered(pathGeneration: 1)
        )
        XCTAssertEqual(
            owner.consume(constrainedEthernet),
            .unchanged
        )
        let ipv6OnlyEthernet = HostAgentNetworkPathSnapshot(
            availability: .satisfied,
            interfaceKinds: [.wiredEthernet],
            supportsIPv4: false,
            supportsIPv6: true,
            supportsDNS: true,
            isExpensive: false,
            isConstrained: true
        )
        XCTAssertEqual(
            owner.consume(ipv6OnlyEthernet),
            .recoveryTriggered(pathGeneration: 2)
        )
        XCTAssertEqual(recorder.requests.map(\.pathGeneration), [1, 2])
    }

    func testInitialUnavailableThenUsableTriggersRecovery() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)
        let wifi = usablePath(.wifi)

        XCTAssertEqual(owner.consume(unavailablePath()), .unavailableRecorded)
        XCTAssertEqual(
            owner.consume(wifi),
            .recoveryTriggered(pathGeneration: 1)
        )
        XCTAssertEqual(
            recorder.requests,
            [.init(pathGeneration: 1, path: wifi)]
        )
    }

    func testMalformedSatisfiedPathFailsClosed() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)
        let malformed = HostAgentNetworkPathSnapshot(
            availability: .satisfied,
            interfaceKinds: [],
            supportsIPv4: false,
            supportsIPv6: false,
            supportsDNS: true,
            isExpensive: false,
            isConstrained: false
        )

        XCTAssertEqual(owner.consume(malformed), .rejected)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .failed(pathGeneration: 0, reason: .invalidSatisfiedPath)
        )
        XCTAssertEqual(owner.consume(usablePath(.wifi)), .rejected)
        XCTAssertEqual(recorder.requests, [])

        let loopbackOwner = makeOwner(
            recorder: NetworkPathRecoveryRecorder()
        )
        XCTAssertEqual(
            loopbackOwner.consume(usablePath(.loopback)),
            .rejected
        )
    }

    func testRejectedTriggerIsTerminalAndKeepsExactGeneration() {
        let recorder = NetworkPathRecoveryRecorder(accepts: false)
        let owner = makeOwner(recorder: recorder)
        let wifi = usablePath(.wifi)
        let ethernet = usablePath(.wiredEthernet)

        XCTAssertEqual(owner.consume(wifi), .baselineEstablished)
        XCTAssertEqual(owner.consume(ethernet), .rejected)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .failed(pathGeneration: 1, reason: .triggerRejected)
        )
        XCTAssertEqual(owner.consume(wifi), .rejected)
        XCTAssertEqual(
            recorder.requests,
            [.init(pathGeneration: 1, path: ethernet)]
        )
    }

    func testGenerationExhaustionFailsBeforeTrigger() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = HostAgentNetworkPathRecoveryTriggerOwner(
            initialPathGeneration: .max,
            trigger: { pathGeneration, path in
                recorder.record(
                    pathGeneration: pathGeneration,
                    path: path
                )
            }
        )

        XCTAssertEqual(owner.consume(usablePath(.wifi)), .baselineEstablished)
        XCTAssertEqual(owner.consume(usablePath(.wiredEthernet)), .rejected)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .failed(pathGeneration: .max, reason: .generationExhausted)
        )
        XCTAssertEqual(recorder.requests, [])
    }

    func testConcurrentSampleIsRejectedAndCancellationDrainsTrigger() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = HostAgentNetworkPathRecoveryTriggerOwner { _, _ in
            entered.signal()
            release.wait()
            return true
        }
        let wifi = usablePath(.wifi)
        let ethernet = usablePath(.wiredEthernet)
        XCTAssertEqual(owner.consume(wifi), .baselineEstablished)
        let recoveryFinished = expectation(description: "recovery returned")
        let cancelFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            XCTAssertEqual(
                owner.consume(ethernet),
                .rejected
            )
            recoveryFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(owner.consume(wifi), .rejected)

        DispatchQueue.global().async {
            owner.cancelAndWait()
            cancelFinished.signal()
        }
        XCTAssertEqual(
            cancelFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )
        release.signal()
        wait(for: [recoveryFinished], timeout: 1)
        XCTAssertEqual(
            cancelFinished.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(owner.consume(wifi), .rejected)
    }

    func testCancellationBeforeObservationIsTerminalAndIdempotent() {
        let recorder = NetworkPathRecoveryRecorder()
        let owner = makeOwner(recorder: recorder)

        owner.cancelAndWait()
        owner.cancelAndWait()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(owner.consume(usablePath(.wifi)), .rejected)
        XCTAssertEqual(recorder.requests, [])
    }

    private func makeOwner(
        recorder: NetworkPathRecoveryRecorder
    ) -> HostAgentNetworkPathRecoveryTriggerOwner {
        HostAgentNetworkPathRecoveryTriggerOwner { pathGeneration, path in
            recorder.record(
                pathGeneration: pathGeneration,
                path: path
            )
        }
    }

    private func usablePath(
        _ interface: HostAgentNetworkInterfaceKind,
        isConstrained: Bool = false
    ) -> HostAgentNetworkPathSnapshot {
        HostAgentNetworkPathSnapshot(
            availability: .satisfied,
            interfaceKinds: [interface],
            supportsIPv4: true,
            supportsIPv6: true,
            supportsDNS: true,
            isExpensive: false,
            isConstrained: isConstrained
        )
    }

    private func unavailablePath() -> HostAgentNetworkPathSnapshot {
        HostAgentNetworkPathSnapshot(
            availability: .unsatisfied,
            interfaceKinds: [],
            supportsIPv4: false,
            supportsIPv6: false,
            supportsDNS: false,
            isExpensive: false,
            isConstrained: false
        )
    }
}

private struct NetworkPathRecoveryRequest: Equatable {
    let pathGeneration: UInt64
    let path: HostAgentNetworkPathSnapshot
}

private final class NetworkPathRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let accepts: Bool
    private var requestStorage: [NetworkPathRecoveryRequest] = []

    init(accepts: Bool = true) {
        self.accepts = accepts
    }

    var requests: [NetworkPathRecoveryRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func record(
        pathGeneration: UInt64,
        path: HostAgentNetworkPathSnapshot
    ) -> Bool {
        lock.lock()
        requestStorage.append(.init(
            pathGeneration: pathGeneration,
            path: path
        ))
        lock.unlock()
        return accepts
    }
}
