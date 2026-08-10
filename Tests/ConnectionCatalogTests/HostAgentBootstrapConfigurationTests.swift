import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapConfigurationTests: XCTestCase {
    func testDecodesExactVersionedImmutableHostBootstrapInput() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(validDocument())

        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(configuration.configRevision, 7)
        XCTAssertEqual(configuration.agentBuildID, "20260808155349")
        XCTAssertEqual(
            configuration.rendezvousServer,
            "hermes.example.invalid:21116"
        )
        XCTAssertEqual(configuration.serverPublicKey, "public-key")
        XCTAssertEqual(
            configuration.clipboardPolicy,
            HostAgentClipboardPolicy(
                allowRemoteRead: true,
                allowRemoteWrite: false,
                allowRemoteRichTextRead: false,
                allowRemoteRichTextWrite: true,
                allowRemoteImageRead: true,
                allowRemoteImageWrite: false
            )
        )
        XCTAssertEqual(configuration.hostConfigAppName, "FarPaneHost")
        XCTAssertEqual(configuration.hostConfigOrganization, "io.rustdesknative")
    }

    func testLegacySchemaOneMigratesToClipboardDisabled() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            legacyDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.clipboardPolicy, .disabled)
    }

    func testSchemaTwoPreservesSmallTextAndDisablesRichText() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            schemaTwoDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 2)
        XCTAssertEqual(
            configuration.clipboardPolicy,
            HostAgentClipboardPolicy(
                allowRemoteRead: true,
                allowRemoteWrite: false,
                allowRemoteRichTextRead: false,
                allowRemoteRichTextWrite: false,
                allowRemoteImageRead: false,
                allowRemoteImageWrite: false
            )
        )
    }

    func testSchemaThreePreservesTextAndDisablesImage() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            schemaThreeDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 3)
        XCTAssertEqual(
            configuration.clipboardPolicy,
            HostAgentClipboardPolicy(
                allowRemoteRead: true,
                allowRemoteWrite: false,
                allowRemoteRichTextRead: false,
                allowRemoteRichTextWrite: true,
                allowRemoteImageRead: false,
                allowRemoteImageWrite: false
            )
        )
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
        future["schemaVersion"] = 5
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(future))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .unsupportedSchema(5))
        }

        var numericClipboard = try object(from: validDocument())
        numericClipboard["clipboard"] = [
            "allowRemoteRead": 1,
            "allowRemoteWrite": false,
            "allowRemoteRichTextRead": false,
            "allowRemoteRichTextWrite": false,
            "allowRemoteImageRead": false,
            "allowRemoteImageWrite": false,
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(numericClipboard))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }

        var numericRichClipboard = try object(from: validDocument())
        numericRichClipboard["clipboard"] = [
            "allowRemoteRead": true,
            "allowRemoteWrite": false,
            "allowRemoteRichTextRead": 1,
            "allowRemoteRichTextWrite": false,
            "allowRemoteImageRead": false,
            "allowRemoteImageWrite": false,
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(numericRichClipboard))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }

        var numericImageClipboard = try object(from: validDocument())
        numericImageClipboard["clipboard"] = [
            "allowRemoteRead": true,
            "allowRemoteWrite": false,
            "allowRemoteRichTextRead": false,
            "allowRemoteRichTextWrite": true,
            "allowRemoteImageRead": 1,
            "allowRemoteImageWrite": false,
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(numericImageClipboard))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
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
            "schemaVersion": 4,
            "configRevision": 7,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": "hermes.example.invalid:21116",
                "serverPublicKey": "public-key",
            ],
            "clipboard": [
                "allowRemoteRead": true,
                "allowRemoteWrite": false,
                "allowRemoteRichTextRead": false,
                "allowRemoteRichTextWrite": true,
                "allowRemoteImageRead": true,
                "allowRemoteImageWrite": false,
            ],
        ])
    }

    private func schemaThreeDocument() -> Data {
        data([
            "schemaVersion": 3,
            "configRevision": 6,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": "hermes.example.invalid:21116",
                "serverPublicKey": "public-key",
            ],
            "clipboard": [
                "allowRemoteRead": true,
                "allowRemoteWrite": false,
                "allowRemoteRichTextRead": false,
                "allowRemoteRichTextWrite": true,
            ],
        ])
    }

    private func schemaTwoDocument() -> Data {
        data([
            "schemaVersion": 2,
            "configRevision": 6,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": "hermes.example.invalid:21116",
                "serverPublicKey": "public-key",
            ],
            "clipboard": [
                "allowRemoteRead": true,
                "allowRemoteWrite": false,
            ],
        ])
    }

    private func legacyDocument() -> Data {
        data([
            "schemaVersion": 1,
            "configRevision": 6,
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
