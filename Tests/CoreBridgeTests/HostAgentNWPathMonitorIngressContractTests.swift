import Foundation
import XCTest

final class HostAgentNWPathMonitorIngressContractTests: XCTestCase {
    func testProductMonitorOwnsInitialCallbackAndSerialDelivery() throws {
        let source = try productSource(
            "HostAgentNWPathMonitorIngress.swift"
        )

        XCTAssertTrue(source.contains("import Network"))
        XCTAssertTrue(source.contains("monitor: NWPathMonitor()"))
        XCTAssertTrue(source.contains(
            "label: \"io.farpane.host-agent.network-path\""
        ))
        XCTAssertTrue(source.contains(
            "HostAgentNetworkPathDeliveryOwner("
        ))
        try assertOrder(
            in: source,
            "monitor.pathUpdateHandler = { [weak self] path in",
            "monitor.start(queue: queue)"
        )
        XCTAssertFalse(source.contains("currentPath"))
    }

    func testNWPathFieldsAreStrictlyNormalized() throws {
        let source = try productSource(
            "HostAgentNWPathMonitorIngress.swift"
        )

        for mapping in [
            "case .satisfied:\n            availability = .satisfied",
            "case .requiresConnection:\n            availability = .requiresConnection",
            "case .unsatisfied:\n            availability = .unsatisfied",
            "case .other:\n                return .other",
            "case .wifi:\n                return .wifi",
            "case .cellular:\n                return .cellular",
            "case .wiredEthernet:\n                return .wiredEthernet",
            "case .loopback:\n                return .loopback",
        ] {
            XCTAssertTrue(source.contains(mapping), "missing \(mapping)")
        }
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "@unknown default:").count - 1,
            2
        )
        XCTAssertTrue(source.contains(
            "guard path.usesInterfaceType(interface.type) else { return nil }"
        ))
        for field in [
            "supportsIPv4: path.supportsIPv4",
            "supportsIPv6: path.supportsIPv6",
            "supportsDNS: path.supportsDNS",
            "isExpensive: path.isExpensive",
            "isConstrained: path.isConstrained",
        ] {
            XCTAssertTrue(source.contains(field), "missing \(field)")
        }
    }

    func testRejectedDeliveryTerminatesAsynchronouslyButClosedIsSilent() throws {
        let source = try productSource(
            "HostAgentNWPathMonitorIngress.swift"
        )

        XCTAssertTrue(source.contains(
            "case .accepted, .closed:\n            return"
        ))
        XCTAssertTrue(source.contains(
            "case .rejected:"
        ))
        XCTAssertTrue(source.contains(
            "let shouldTerminate = state == .running"
        ))
        try assertOrder(
            in: source,
            "DispatchQueue.global(qos: .utility).async",
            ".async(execute: onFailure)"
        )
    }

    func testMonitorCancellationPrecedesDeliveryAndCompositionDrain() throws {
        let ingress = try productSource(
            "HostAgentNWPathMonitorIngress.swift"
        )
        let owner = try productSource(
            "HostAgentNetworkPathRecoveryProcessOwner.swift"
        )

        try assertOrder(
            in: ingress,
            "monitor.pathUpdateHandler = nil",
            "monitor.cancel()"
        )
        try assertOrder(
            in: ingress,
            "monitor.cancel()",
            "deliveryOwner.cancelAndWait()"
        )
        XCTAssertTrue(ingress.contains("while state == .cancelling"))
        XCTAssertTrue(ingress.contains("state = .cancelled"))

        try assertOrder(
            in: owner,
            "pathIngress?.cancelAndWait()",
            "composition?.cancelAndWait()"
        )
        XCTAssertTrue(owner.contains(
            "composition.consume(path) != .rejected"
        ))
        XCTAssertTrue(owner.contains(
            "lifetime?.requestTermination(reason: .error)"
        ))
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

    private func assertOrder(
        in source: String,
        _ earlier: String,
        _ later: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let earlierRange = try XCTUnwrap(
            source.range(of: earlier),
            "missing earlier source marker",
            file: file,
            line: line
        )
        let laterRange = try XCTUnwrap(
            source.range(of: later),
            "missing later source marker",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            earlierRange.lowerBound,
            laterRange.lowerBound,
            file: file,
            line: line
        )
    }
}
