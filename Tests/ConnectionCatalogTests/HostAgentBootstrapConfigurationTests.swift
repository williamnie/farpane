import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapConfigurationTests: XCTestCase {
    func testDecodesExactVersionedImmutableHostBootstrapInput() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(validDocument())

        XCTAssertEqual(configuration.schemaVersion, 7)
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
        XCTAssertEqual(
            configuration.fileTransferPolicy,
            HostAgentFileTransferPolicy(
                enabled: true,
                receiveRoot: "/Users/example/FarPane Receive"
            )
        )
        XCTAssertEqual(
            configuration.audioPolicy,
            HostAgentAudioPolicy(
                enabled: true,
                inputDeviceName: "BlackHole 2ch"
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
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
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
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
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
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
    }

    func testSchemaFourPreservesClipboardAndDisablesFileTransfer() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            schemaFourDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 4)
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
    }

    func testSchemaFivePreservesFileTransferAndDisablesAudio() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            schemaFiveDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 5)
        XCTAssertTrue(configuration.fileTransferPolicy.enabled)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
    }

    func testSchemaSixPreservesAudioAndMigratesToNativeSystemAudio() throws {
        let configuration = try HostAgentBootstrapConfiguration.decode(
            schemaSixDocument()
        )

        XCTAssertEqual(configuration.schemaVersion, 6)
        XCTAssertEqual(
            configuration.audioPolicy,
            HostAgentAudioPolicy(enabled: true, inputDeviceName: nil)
        )
        XCTAssertFalse(
            configuration.audioPolicy.requiresMicrophoneAuthorization
        )
    }

    func testOnlyExplicitAudioInputRequiresMicrophoneAuthorization() {
        XCTAssertFalse(
            HostAgentAudioPolicy.disabled.requiresMicrophoneAuthorization
        )
        XCTAssertFalse(
            HostAgentAudioPolicy(enabled: true)
                .requiresMicrophoneAuthorization
        )
        XCTAssertTrue(
            HostAgentAudioPolicy(
                enabled: true,
                inputDeviceName: "BlackHole 2ch"
            ).requiresMicrophoneAuthorization
        )
    }

    func testAudioInputPolicyIsStrictAndFailClosed() throws {
        var disabledWithInput = try object(from: validDocument())
        disabledWithInput["audio"] = [
            "enabled": false,
            "inputDeviceName": "BlackHole 2ch",
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(disabledWithInput))
        )

        for invalidName in ["", " BlackHole 2ch", "BlackHole\n2ch", String(repeating: "a", count: 513)] {
            var invalid = try object(from: validDocument())
            invalid["audio"] = [
                "enabled": true,
                "inputDeviceName": invalidName,
            ]
            XCTAssertThrowsError(
                try HostAgentBootstrapConfiguration.decode(data(invalid))
            )
        }

        var defaultInput = try object(from: validDocument())
        defaultInput["audio"] = [
            "enabled": true,
            "inputDeviceName": NSNull(),
        ]
        XCTAssertNil(
            try HostAgentBootstrapConfiguration.decode(data(defaultInput))
                .audioPolicy.inputDeviceName
        )
    }

    func testAudioInputCatalogOnlyExposesValidUniqueExactNames() {
        let catalog = HostAudioInputDeviceCatalog(reportedNames: [
            "Mac mini Microphone",
            "BlackHole 2ch",
            "BlackHole 2ch",
            " padded",
            "Loopback Audio",
            "bad\nname",
        ])

        XCTAssertEqual(
            catalog.uniqueNames,
            ["Loopback Audio", "Mac mini Microphone"]
        )
        XCTAssertTrue(catalog.containsUnique("Loopback Audio"))
        XCTAssertFalse(catalog.containsUnique("BlackHole 2ch"))
    }

    func testRejectsFileTransferPairMismatchAndUnsafeReceiveRoot() throws {
        var enabledWithoutRoot = try object(from: validDocument())
        enabledWithoutRoot["fileTransfer"] = [
            "enabled": true,
            "receiveRoot": NSNull(),
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(enabledWithoutRoot))
        ) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        var disabledWithRoot = try object(from: validDocument())
        disabledWithRoot["fileTransfer"] = [
            "enabled": false,
            "receiveRoot": "/Users/example/FarPane Receive",
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(disabledWithRoot))
        ) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }

        for root in ["relative/path", "/Users/example/../escape", "/"] {
            var unsafe = try object(from: validDocument())
            unsafe["fileTransfer"] = ["enabled": true, "receiveRoot": root]
            XCTAssertThrowsError(
                try HostAgentBootstrapConfiguration.decode(data(unsafe))
            ) { error in
                XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
            }
        }

        var numericEnabled = try object(from: validDocument())
        numericEnabled["fileTransfer"] = [
            "enabled": 1,
            "receiveRoot": "/Users/example/FarPane Receive",
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(numericEnabled))
        ) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .invalidDocument)
        }
    }

    func testBuildsOnlyCanonicalEnabledFileTransferPolicy() {
        XCTAssertEqual(
            HostAgentFileTransferPolicy.validatedEnabled(
                receiveRoot: "/Users/example/FarPane Receive"
            ),
            HostAgentFileTransferPolicy(
                enabled: true,
                receiveRoot: "/Users/example/FarPane Receive"
            )
        )
        for root in ["", "relative", "/", "/Users/example/../escape"] {
            XCTAssertNil(
                HostAgentFileTransferPolicy.validatedEnabled(
                    receiveRoot: root
                )
            )
        }
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
        future["schemaVersion"] = 8
        XCTAssertThrowsError(try HostAgentBootstrapConfiguration.decode(data(future))) { error in
            XCTAssertEqual(error as? HostAgentBootstrapConfigurationError, .unsupportedSchema(8))
        }

        var missingAudio = try object(from: validDocument())
        missingAudio.removeValue(forKey: "audio")
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(missingAudio))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }

        var downgradedAudio = try object(from: schemaFiveDocument())
        downgradedAudio["audio"] = ["enabled": true]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(downgradedAudio))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }

        var numericAudio = try object(from: validDocument())
        numericAudio["audio"] = [
            "enabled": 1,
            "inputDeviceName": NSNull(),
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(numericAudio))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }

        var extraAudioKey = try object(from: validDocument())
        extraAudioKey["audio"] = [
            "enabled": true,
            "inputDeviceName": NSNull(),
            "source": "microphone",
        ]
        XCTAssertThrowsError(
            try HostAgentBootstrapConfiguration.decode(data(extraAudioKey))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
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
            "schemaVersion": 7,
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
            "fileTransfer": [
                "enabled": true,
                "receiveRoot": "/Users/example/FarPane Receive",
            ],
            "audio": [
                "enabled": true,
                "inputDeviceName": "BlackHole 2ch",
            ],
        ])
    }

    private func schemaSixDocument() -> Data {
        data([
            "schemaVersion": 6,
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
            "fileTransfer": [
                "enabled": true,
                "receiveRoot": "/Users/example/FarPane Receive",
            ],
            "audio": [
                "enabled": true,
            ],
        ])
    }

    private func schemaFiveDocument() -> Data {
        data([
            "schemaVersion": 5,
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
                "allowRemoteImageRead": true,
                "allowRemoteImageWrite": false,
            ],
            "fileTransfer": [
                "enabled": true,
                "receiveRoot": "/Users/example/FarPane Receive",
            ],
        ])
    }

    private func schemaFourDocument() -> Data {
        data([
            "schemaVersion": 4,
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
