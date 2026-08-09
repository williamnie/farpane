import CoreBridge
import Foundation
import Network

enum HostAgentNWPathMonitorIngressState: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed
    case cancelling
    case cancelled
}

/// Process-owned adapter from Network.framework into the strict normalized
/// Host path contract. NWPathMonitor supplies the initial observation; this
/// owner never synchronously samples or synthesizes an initial baseline.
final class HostAgentNWPathMonitorIngress: @unchecked Sendable {
    private let condition = NSCondition()
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let deliveryOwner: HostAgentNetworkPathDeliveryOwner
    private let onFailure: @Sendable () -> Void
    private var state: HostAgentNWPathMonitorIngressState = .idle

    static func makeProduct(
        deliverPath: @escaping HostAgentNetworkPathDeliveryOwner.Deliver,
        onFailure: @escaping @Sendable () -> Void
    ) -> HostAgentNWPathMonitorIngress {
        HostAgentNWPathMonitorIngress(
            monitor: NWPathMonitor(),
            queue: DispatchQueue(
                label: "io.farpane.host-agent.network-path",
                qos: .utility
            ),
            deliveryOwner: HostAgentNetworkPathDeliveryOwner(
                deliverPath: deliverPath
            ),
            onFailure: onFailure
        )
    }

    private init(
        monitor: NWPathMonitor,
        queue: DispatchQueue,
        deliveryOwner: HostAgentNetworkPathDeliveryOwner,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.monitor = monitor
        self.queue = queue
        self.deliveryOwner = deliveryOwner
        self.onFailure = onFailure
    }

    deinit {
        cancelAndWait()
    }

    func stateSnapshot() -> HostAgentNWPathMonitorIngressState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    func start() -> Bool {
        condition.lock()
        guard state == .idle else {
            condition.unlock()
            return false
        }
        state = .starting
        monitor.pathUpdateHandler = { [weak self] path in
            self?.deliver(path)
        }
        monitor.start(queue: queue)
        state = .running
        condition.broadcast()
        condition.unlock()
        return true
    }

    /// Terminal and idempotent. Product teardown calls this outside the path
    /// callback so monitor admission closes before accepted delivery drains.
    func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle, .starting, .running, .failed:
            state = .cancelling
            monitor.pathUpdateHandler = nil
            monitor.cancel()
            condition.unlock()

            deliveryOwner.cancelAndWait()

            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    private func deliver(_ path: NWPath) {
        switch deliveryOwner.deliver(Self.normalize(path)) {
        case .accepted, .closed:
            return
        case .rejected:
            condition.lock()
            let shouldTerminate = state == .running
            if shouldTerminate {
                state = .failed
                condition.broadcast()
            }
            condition.unlock()
            if shouldTerminate {
                requestProcessTermination()
            }
        }
    }

    private func requestProcessTermination() {
        DispatchQueue.global(qos: .utility).async(execute: onFailure)
    }

    private static func normalize(
        _ path: NWPath
    ) -> HostAgentNetworkPathSnapshot {
        let availability: HostAgentNetworkPathAvailability
        switch path.status {
        case .satisfied:
            availability = .satisfied
        case .requiresConnection:
            availability = .requiresConnection
        case .unsatisfied:
            availability = .unsatisfied
        @unknown default:
            availability = .unsatisfied
        }

        let interfaceKinds = Set(path.availableInterfaces.compactMap {
            interface -> HostAgentNetworkInterfaceKind? in
            guard path.usesInterfaceType(interface.type) else { return nil }
            switch interface.type {
            case .other:
                return .other
            case .wifi:
                return .wifi
            case .cellular:
                return .cellular
            case .wiredEthernet:
                return .wiredEthernet
            case .loopback:
                return .loopback
            @unknown default:
                return .other
            }
        })
        return HostAgentNetworkPathSnapshot(
            availability: availability,
            interfaceKinds: interfaceKinds,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
