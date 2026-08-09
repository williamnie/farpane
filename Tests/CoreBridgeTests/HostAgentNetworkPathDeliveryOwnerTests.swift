import Foundation
@testable import CoreBridge
import XCTest

final class HostAgentNetworkPathDeliveryOwnerTests: XCTestCase {
    func testDeliversNormalizedPathsInOrder() {
        let recorder = NetworkPathDeliveryRecorder()
        let owner = HostAgentNetworkPathDeliveryOwner(
            deliverPath: recorder.handler
        )
        let wifi = path(.wifi)
        let unavailable = path(
            availability: .unsatisfied,
            interfaceKinds: [],
            supportsIPv4: false,
            supportsIPv6: false,
            supportsDNS: false
        )

        XCTAssertEqual(owner.deliver(wifi), .accepted)
        XCTAssertEqual(owner.deliver(unavailable), .accepted)
        XCTAssertEqual(recorder.paths, [wifi, unavailable])
        XCTAssertEqual(owner.stateSnapshot(), .accepting)
    }

    func testOperationRejectionFailsClosed() {
        let recorder = NetworkPathDeliveryRecorder(accepts: false)
        let owner = HostAgentNetworkPathDeliveryOwner(
            deliverPath: recorder.handler
        )
        let wifi = path(.wifi)

        XCTAssertEqual(owner.deliver(wifi), .rejected)
        XCTAssertEqual(owner.stateSnapshot(), .failed)
        XCTAssertEqual(owner.deliver(path(.wiredEthernet)), .rejected)
        XCTAssertEqual(recorder.paths, [wifi])
    }

    func testConcurrentDeliveryIsRejectedWithoutEnteringOperation() {
        let recorder = BlockingNetworkPathDeliveryRecorder()
        let owner = HostAgentNetworkPathDeliveryOwner(
            deliverPath: recorder.handler
        )
        let deliveryFinished = expectation(description: "delivery finished")
        let firstResult = NetworkPathDeliveryDispositionBox()
        DispatchQueue.global().async {
            firstResult.value = owner.deliver(self.path(.wifi))
            deliveryFinished.fulfill()
        }
        XCTAssertEqual(recorder.entered.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(owner.deliver(path(.wiredEthernet)), .rejected)
        XCTAssertEqual(owner.stateSnapshot(), .delivering)
        recorder.release.signal()
        wait(for: [deliveryFinished], timeout: 1)

        XCTAssertEqual(firstResult.value, .accepted)
        XCTAssertEqual(owner.stateSnapshot(), .accepting)
        XCTAssertEqual(recorder.count, 1)
    }

    func testCancellationClosesAdmissionAndDrainsAcceptedDelivery() {
        let recorder = BlockingNetworkPathDeliveryRecorder()
        let owner = HostAgentNetworkPathDeliveryOwner(
            deliverPath: recorder.handler
        )
        let deliveryFinished = expectation(description: "delivery finished")
        let deliveryResult = NetworkPathDeliveryDispositionBox()
        DispatchQueue.global().async {
            deliveryResult.value = owner.deliver(self.path(.wifi))
            deliveryFinished.fulfill()
        }
        XCTAssertEqual(recorder.entered.wait(timeout: .now() + 1), .success)

        let cancellationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            owner.cancelAndWait()
            cancellationFinished.signal()
        }
        XCTAssertEqual(
            cancellationFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )
        XCTAssertEqual(owner.deliver(path(.wiredEthernet)), .closed)

        recorder.release.signal()
        wait(for: [deliveryFinished], timeout: 1)
        XCTAssertEqual(
            cancellationFinished.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(deliveryResult.value, .closed)
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
    }

    func testCancellationBeforeDeliveryIsTerminalAndIdempotent() {
        let recorder = NetworkPathDeliveryRecorder()
        let owner = HostAgentNetworkPathDeliveryOwner(
            deliverPath: recorder.handler
        )

        owner.cancelAndWait()
        owner.cancelAndWait()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(owner.deliver(path(.wifi)), .closed)
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    private func path(
        _ interfaceKind: HostAgentNetworkInterfaceKind,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true,
        supportsDNS: Bool = true
    ) -> HostAgentNetworkPathSnapshot {
        path(
            availability: .satisfied,
            interfaceKinds: [interfaceKind],
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            supportsDNS: supportsDNS
        )
    }

    private func path(
        availability: HostAgentNetworkPathAvailability,
        interfaceKinds: Set<HostAgentNetworkInterfaceKind>,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        supportsDNS: Bool
    ) -> HostAgentNetworkPathSnapshot {
        HostAgentNetworkPathSnapshot(
            availability: availability,
            interfaceKinds: interfaceKinds,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            supportsDNS: supportsDNS,
            isExpensive: false,
            isConstrained: false
        )
    }
}

private final class NetworkPathDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let accepts: Bool
    private var storage: [HostAgentNetworkPathSnapshot] = []

    init(accepts: Bool = true) {
        self.accepts = accepts
    }

    var paths: [HostAgentNetworkPathSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var handler: HostAgentNetworkPathDeliveryOwner.Deliver {
        { [self] path in
            lock.lock()
            storage.append(path)
            lock.unlock()
            return accepts
        }
    }
}

private final class BlockingNetworkPathDeliveryRecorder:
    @unchecked Sendable
{
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveryCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveryCount
    }

    var handler: HostAgentNetworkPathDeliveryOwner.Deliver {
        { [self] _ in
            lock.lock()
            deliveryCount += 1
            lock.unlock()
            entered.signal()
            release.wait()
            return true
        }
    }
}

private final class NetworkPathDeliveryDispositionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: HostAgentNetworkPathDeliveryDisposition?

    var value: HostAgentNetworkPathDeliveryDisposition? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
