import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapConfigurationTests: XCTestCase {
    func testDecodesExactVersionedImmutableHostBootstrapInput() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(validDocument())

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.configRevision, 7)
        XCTAssertEqual(configuration.agentBuildID, "20260808155349")
        XCTAssertEqual(
            configuration.rendezvousServer,
            "hermes.example.invalid:21116"
        )
        XCTAssertEqual(configuration.serverPublicKey, "public-key")
        XCTAssertEqual(configuration.hostConfigAppName, "FarPaneHost")
        XCTAssertEqual(configuration.hostConfigOrganization, "io.rustdesknative")
    }

    func testRejectsUnknownCredentialAndAmbiguousRevisionFields() throws {
        var credential = try object(from: validDocument())
        credential["password"] = "must-not-enter-bootstrap"
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(credential))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        var booleanRevision = try object(from: validDocument())
        booleanRevision["configRevision"] = true
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(booleanRevision))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        var zeroRevision = try object(from: validDocument())
        zeroRevision["configRevision"] = 0
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(zeroRevision))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }
    }

    func testRejectsUnsupportedSchemaUnsafeStringsAndOversizedInput() throws {
        var future = try object(from: validDocument())
        future["schemaVersion"] = 2
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(future))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .unsupportedSchema(2))
        }

        var paddedServer = try object(from: validDocument())
        var server = try XCTUnwrap(paddedServer["server"] as? [String: Any])
        server["rendezvousServer"] = " hermes.example.invalid:21116"
        paddedServer["server"] = server
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(paddedServer))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        var controlBuild = try object(from: validDocument())
        controlBuild["agentBuildID"] = "build\n2"
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(controlBuild))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        let oversized = Data(
            repeating: 0x20,
            count: HostAgentBootstrapConfiguration.maximumDocumentBytes + 1
        )
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(oversized)) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .documentTooLarge)
        }
    }

    private func validDocument() throws -> Data {
        data([
            "schemaVersion": 1,
            "configRevision": 7,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": "hermes.example.invalid:21116",
                "serverPublicKey": "public-key",
            ],
        ])
    }

    private func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
