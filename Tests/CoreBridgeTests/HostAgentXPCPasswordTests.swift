@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCPasswordTests: XCTestCase {
    private let hostID = "host-password"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let requestID = "151db9a9-7dd3-4fea-93af-1b6c10840676"

    func testWireKeepsPermanentSecretOutsideMetadata() throws {
        let secret = Data("not-in-json-1234".utf8)
        let request = try makeRequest(
            action: .setPermanentPassword,
            secretLength: UInt64(secret.count)
        )
        let encoded = try request.encoded()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains("not-in-json-1234"))
        XCTAssertEqual(
            try HostAgentXPCWirePasswordRequest.decode(encoded),
            request
        )

        let response = try HostAgentXPCWirePasswordResponse(
            request: request,
            status: .ok,
            detail: .none,
            secretLength: 0
        )
        let decoded = try HostAgentXPCWirePasswordResponse.decode(
            response.encoded()
        )
        XCTAssertTrue(decoded.isCorrelated(to: request))
        XCTAssertEqual(decoded.status, .ok)
    }

    func testServiceReceivesBoundedPermanentSecretAndReturnsOnlyMetadata() throws {
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "build-password",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let secret = Data("strong-password-123".utf8)
        let expectedRequestID = requestID
        let executed = expectation(description: "password executed")
        let service = HostAgentXPCPasswordService(
            identity: identity,
            execute: { action, receivedSecret, commandID in
                XCTAssertEqual(action, .setPermanentPassword)
                XCTAssertEqual(receivedSecret, secret)
                XCTAssertEqual(commandID, expectedRequestID)
                executed.fulfill()
                return nil
            }
        )
        let request = try makeRequest(
            action: .setPermanentPassword,
            secretLength: UInt64(secret.count)
        )
        let replied = expectation(description: "password replied")
        service.perform(
            requestData: try request.encoded(),
            secretData: secret
        ) { data, returnedSecret in
            XCTAssertNil(returnedSecret)
            guard let data,
                  let response = try? HostAgentXPCWirePasswordResponse.decode(data)
            else {
                XCTFail("missing password response")
                replied.fulfill()
                return
            }
            XCTAssertEqual(response.status, .ok)
            replied.fulfill()
        }

        wait(for: [executed, replied], timeout: 2)
    }

    func testRevealReturnsSecretOnlyInDedicatedSlot() throws {
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "build-password",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let password = Data("123456789".utf8)
        let service = HostAgentXPCPasswordService(
            identity: identity,
            execute: { action, secret, _ in
                XCTAssertEqual(action, .revealTemporaryPassword)
                XCTAssertTrue(secret.isEmpty)
                return password
            }
        )
        let request = try makeRequest(
            action: .revealTemporaryPassword,
            secretLength: 0
        )
        let replied = expectation(description: "reveal replied")
        service.perform(
            requestData: try request.encoded(),
            secretData: nil
        ) { data, returnedSecret in
            guard let data,
                  let response = try? HostAgentXPCWirePasswordResponse.decode(data)
            else {
                XCTFail("missing reveal response")
                replied.fulfill()
                return
            }
            XCTAssertEqual(response.secretLength, UInt64(password.count))
            XCTAssertEqual(returnedSecret, password)
            XCTAssertFalse(
                String(data: data, encoding: .utf8)?
                    .contains("123456789") ?? true
            )
            replied.fulfill()
        }

        wait(for: [replied], timeout: 2)
    }

    func testInvalidatedServiceDoesNotExecuteQueuedPasswordOperation() throws {
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "build-password",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let request = try makeRequest(
            action: .clearPermanentPassword,
            secretLength: 0
        )
        let requestData = try request.encoded()
        let queue = DispatchQueue(label: "password-invalidation-test")
        let executed = expectation(description: "password not executed")
        executed.isInverted = true
        let replied = expectation(description: "invalidated reply")
        let service = HostAgentXPCPasswordService(
            identity: identity,
            queue: queue,
            execute: { _, _, _ in
                executed.fulfill()
                return nil
            }
        )

        queue.suspend()
        service.perform(requestData: requestData, secretData: nil) {
            response, secret in
            XCTAssertNil(response)
            XCTAssertNil(secret)
            replied.fulfill()
        }
        service.invalidate()
        queue.resume()

        wait(for: [replied, executed], timeout: 1)
    }

    private func makeRequest(
        action: HostAgentXPCPasswordAction,
        secretLength: UInt64
    ) throws -> HostAgentXPCWirePasswordRequest {
        try HostAgentXPCWirePasswordRequest(
            wireVersion: HostAgentXPCWireHandshakeContract.currentWireVersion,
            requestID: requestID,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 10,
            action: action,
            secretLength: secretLength
        )
    }
}
