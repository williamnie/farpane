import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentXPCHandshakeServiceTests: XCTestCase {
    func testFactoryConstructsClangBackedSingleMethodInterface() throws {
        let interface = HostAgentXPCHandshakeInterfaceFactory.makeInterface()

        XCTAssertEqual(NSStringFromProtocol(interface.protocol), "RDNHostAgentXPCHandshakeService")
        XCTAssertEqual(
            HostAgentXPCHandshakeInterfaceFactory.handshakeSelectorName,
            "performHandshakeWithRequestData:reply:")
    }

    func testHandlerRepliesOnceWithCorrelatedCompatibleResponse() throws {
        let handler = try makeHandler(now: 20)
        let request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610", appBuildID: "app-build",
            knownHostInstanceID: nil, knownAgentBootID: nil, sentAtUnixMilliseconds: 10)
        var replies: [Data?] = []

        handler.performHandshake(requestData: try request.encoded()) { replies.append($0) }

        XCTAssertEqual(replies.count, 1)
        let responseData = try XCTUnwrap(replies[0])
        let response = try HostAgentXPCWireHandshakeResponse.decode(responseData)
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.compatibility, .compatible)
        XCTAssertEqual(response.selectedWireVersion, 2)
        XCTAssertEqual(response.agentBuildID, "agent-build")
        XCTAssertEqual(response.hostInstanceID, "host-instance")
        XCTAssertEqual(response.agentBootID, "6973cef9-a610-4183-ac81-287fd5f298b7")
        XCTAssertEqual(response.agentProcessID, 4_321)
        XCTAssertEqual(response.agentProcessStartIdentitySHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(response.sentAtUnixMilliseconds, 20)
    }

    func testHandlerReturnsTypedIncompatibleResponseForUnsupportedOffer() throws {
        let handler = try makeHandler(now: 20)
        let request = try HostAgentXPCWireHandshakeRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610", supportedWireVersions: [1],
            appBuildID: "app-build", knownHostInstanceID: nil, knownAgentBootID: nil,
            sentAtUnixMilliseconds: 10)

        let responseData = try XCTUnwrap(handler.response(for: request.encoded()))
        let response = try HostAgentXPCWireHandshakeResponse.decode(responseData)

        XCTAssertEqual(response.compatibility, .incompatible)
        XCTAssertNil(response.selectedWireVersion)
    }

    func testHandlerFailsClosedWithoutLeakingDocumentErrors() throws {
        let validHandler = try makeHandler(now: 20)
        let invalidClockHandler = try makeHandler(now: 0)
        let inputs = [
            Data(), Data("{}".utf8),
            Data(
                repeating: 0x20, count: HostAgentXPCWireHandshakeContract.maximumDocumentBytes + 1),
        ]

        for input in inputs {
            var replies: [Data?] = []
            validHandler.performHandshake(requestData: input) { replies.append($0) }
            XCTAssertEqual(replies.count, 1)
            XCTAssertNil(replies[0])
        }

        let request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610", appBuildID: "app-build",
            knownHostInstanceID: nil, knownAgentBootID: nil, sentAtUnixMilliseconds: 10)
        XCTAssertNil(invalidClockHandler.response(for: try request.encoded()))
    }

    func testAgentIdentityRejectsInvalidOrUnboundedValues() {
        let invalidValues = [
            ("agent/build", "host-instance", validBootID), ("agent-build", "", validBootID),
            ("agent-build", String(repeating: "a", count: 129), validBootID),
            ("agent-build", "host-instance", "not-a-uuid"),
        ]

        for value in invalidValues {
            XCTAssertThrowsError(
                try HostAgentXPCWireAgentIdentity.test(
                    agentBuildID: value.0, hostInstanceID: value.1, agentBootID: value.2))
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build", hostInstanceID: "host-instance",
                agentBootID: validBootID, agentProcessID: 1))
        XCTAssertThrowsError(
            try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build", hostInstanceID: "host-instance",
                agentBootID: validBootID,
                agentProcessStartIdentitySHA256: String(repeating: "A", count: 64)))
    }

    private let validBootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeHandler(now: UInt64) throws -> HostAgentXPCHandshakeHandler {
        try HostAgentXPCHandshakeHandler(
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build", hostInstanceID: "host-instance",
                agentBootID: validBootID), nowUnixMilliseconds: { now })
    }
}
