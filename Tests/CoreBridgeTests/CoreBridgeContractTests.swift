import CoreBridge
import XCTest

final class CoreBridgeContractTests: XCTestCase {
    private func hostEvent(
        payload: [String: Any], eventType: String = "mediaControl", schemaVersion: Int = 1
    ) throws -> HostCoreEvent? {
        let envelope: [String: Any] = [
            "schemaVersion": schemaVersion, "eventId": 0, "eventType": eventType,
            "hostInstanceId": "test-host-instance", "sentAt": 1, "payload": payload,
        ]
        return HostCoreEvent(rawJSON: try JSONSerialization.data(withJSONObject: envelope))
    }

    func testPinsRustDesk149Commit() {
        XCTAssertEqual(RustDeskCoreClient.abiVersion, 18)
        XCTAssertEqual(
            RustDeskCoreClient.expectedUpstreamCommit, "6c578292e8ebbbec708b76986ba8c4bc7c509747")
    }

    func testConnectionConfigDoesNotPersistPassword() {
        let config = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            password: "one-time-password")
        XCTAssertEqual(config.password, "one-time-password")
        XCTAssertFalse(config.forceRelay)
        XCTAssertFalse(config.receiveAudio)
        XCTAssertFalse(config.receiveClipboardText)
        XCTAssertFalse(config.sendClipboardText)
        XCTAssertFalse(config.receiveClipboardRichText)
        XCTAssertFalse(config.sendClipboardRichText)
        XCTAssertFalse(config.receiveClipboardImage)
        XCTAssertFalse(config.fileTransferEnabled)
        XCTAssertEqual(config.fileTransferSessionEpoch, 0)
        XCTAssertFalse(config.sendClipboardImage)
    }

    func testHostClipboardDirectionsDefaultOffAndRemainIndependent() {
        let disabled = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key")
        XCTAssertFalse(disabled.clipboardReadEnabled)
        XCTAssertFalse(disabled.clipboardWriteEnabled)
        XCTAssertFalse(disabled.clipboardRichTextReadEnabled)
        XCTAssertFalse(disabled.clipboardRichTextWriteEnabled)
        XCTAssertFalse(disabled.clipboardImageReadEnabled)
        XCTAssertFalse(disabled.clipboardImageWriteEnabled)
        XCTAssertFalse(disabled.audioEnabled)
        XCTAssertNil(disabled.audioInputDeviceName)
        XCTAssertFalse(disabled.fileTransferEnabled)
        XCTAssertNil(disabled.fileTransferReceiveRoot)

        let readOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", clipboardReadEnabled: true
        )
        XCTAssertTrue(readOnly.clipboardReadEnabled)
        XCTAssertFalse(readOnly.clipboardWriteEnabled)
        XCTAssertFalse(readOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(readOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(readOnly.clipboardImageReadEnabled)
        XCTAssertFalse(readOnly.clipboardImageWriteEnabled)

        let writeOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key",
            clipboardWriteEnabled: true)
        XCTAssertFalse(writeOnly.clipboardReadEnabled)
        XCTAssertTrue(writeOnly.clipboardWriteEnabled)
        XCTAssertFalse(writeOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(writeOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(writeOnly.clipboardImageReadEnabled)
        XCTAssertFalse(writeOnly.clipboardImageWriteEnabled)

        let richReadOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key",
            clipboardRichTextReadEnabled: true)
        XCTAssertFalse(richReadOnly.clipboardReadEnabled)
        XCTAssertFalse(richReadOnly.clipboardWriteEnabled)
        XCTAssertTrue(richReadOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(richReadOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(richReadOnly.clipboardImageReadEnabled)
        XCTAssertFalse(richReadOnly.clipboardImageWriteEnabled)

        let richWriteOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key",
            clipboardRichTextWriteEnabled: true)
        XCTAssertFalse(richWriteOnly.clipboardReadEnabled)
        XCTAssertFalse(richWriteOnly.clipboardWriteEnabled)
        XCTAssertFalse(richWriteOnly.clipboardRichTextReadEnabled)
        XCTAssertTrue(richWriteOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(richWriteOnly.clipboardImageReadEnabled)
        XCTAssertFalse(richWriteOnly.clipboardImageWriteEnabled)

        let imageReadOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key",
            clipboardImageReadEnabled: true)
        XCTAssertFalse(imageReadOnly.clipboardReadEnabled)
        XCTAssertFalse(imageReadOnly.clipboardWriteEnabled)
        XCTAssertFalse(imageReadOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(imageReadOnly.clipboardRichTextWriteEnabled)
        XCTAssertTrue(imageReadOnly.clipboardImageReadEnabled)
        XCTAssertFalse(imageReadOnly.clipboardImageWriteEnabled)

        let imageWriteOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key",
            clipboardImageWriteEnabled: true)
        XCTAssertFalse(imageWriteOnly.clipboardReadEnabled)
        XCTAssertFalse(imageWriteOnly.clipboardWriteEnabled)
        XCTAssertFalse(imageWriteOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(imageWriteOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(imageWriteOnly.clipboardImageReadEnabled)
        XCTAssertTrue(imageWriteOnly.clipboardImageWriteEnabled)

        let fileTransferOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", fileTransferEnabled: true,
            fileTransferReceiveRoot: "/private/var/folders/farpane-receive")
        XCTAssertFalse(fileTransferOnly.clipboardReadEnabled)
        XCTAssertFalse(fileTransferOnly.clipboardWriteEnabled)
        XCTAssertFalse(fileTransferOnly.clipboardRichTextReadEnabled)
        XCTAssertFalse(fileTransferOnly.clipboardRichTextWriteEnabled)
        XCTAssertFalse(fileTransferOnly.clipboardImageReadEnabled)
        XCTAssertFalse(fileTransferOnly.clipboardImageWriteEnabled)
        XCTAssertTrue(fileTransferOnly.fileTransferEnabled)
        XCTAssertFalse(fileTransferOnly.audioEnabled)
        XCTAssertEqual(
            fileTransferOnly.fileTransferReceiveRoot, "/private/var/folders/farpane-receive")

        let audioOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", audioEnabled: true,
            audioInputDeviceName: "BlackHole 2ch")
        XCTAssertTrue(audioOnly.audioEnabled)
        XCTAssertEqual(audioOnly.audioInputDeviceName, "BlackHole 2ch")
        XCTAssertFalse(audioOnly.clipboardReadEnabled)
        XCTAssertFalse(audioOnly.clipboardWriteEnabled)
        XCTAssertFalse(audioOnly.fileTransferEnabled)
        XCTAssertNil(audioOnly.fileTransferReceiveRoot)
    }

    func testViewerClipboardDirectionsAreExplicitAndIndependent() {
        let receiveOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            receiveClipboardText: true)
        XCTAssertTrue(receiveOnly.receiveClipboardText)
        XCTAssertFalse(receiveOnly.sendClipboardText)
        XCTAssertFalse(receiveOnly.receiveClipboardRichText)
        XCTAssertFalse(receiveOnly.sendClipboardRichText)

        let sendOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            sendClipboardText: true)
        XCTAssertFalse(sendOnly.receiveClipboardText)
        XCTAssertTrue(sendOnly.sendClipboardText)
        XCTAssertFalse(sendOnly.receiveClipboardRichText)
        XCTAssertFalse(sendOnly.sendClipboardRichText)

        let receiveRichOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            receiveClipboardRichText: true)
        XCTAssertFalse(receiveRichOnly.receiveClipboardText)
        XCTAssertFalse(receiveRichOnly.sendClipboardText)
        XCTAssertTrue(receiveRichOnly.receiveClipboardRichText)
        XCTAssertFalse(receiveRichOnly.sendClipboardRichText)

        let sendRichOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            sendClipboardRichText: true)
        XCTAssertFalse(sendRichOnly.receiveClipboardText)
        XCTAssertFalse(sendRichOnly.sendClipboardText)
        XCTAssertFalse(sendRichOnly.receiveClipboardRichText)
        XCTAssertTrue(sendRichOnly.sendClipboardRichText)

        let receiveImageOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            receiveClipboardImage: true)
        XCTAssertFalse(receiveImageOnly.receiveClipboardText)
        XCTAssertFalse(receiveImageOnly.receiveClipboardRichText)
        XCTAssertTrue(receiveImageOnly.receiveClipboardImage)
        XCTAssertFalse(receiveImageOnly.sendClipboardImage)

        let sendImageOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            sendClipboardImage: true)
        XCTAssertFalse(sendImageOnly.sendClipboardText)
        XCTAssertFalse(sendImageOnly.sendClipboardRichText)
        XCTAssertFalse(sendImageOnly.receiveClipboardImage)
        XCTAssertTrue(sendImageOnly.sendClipboardImage)

        XCTAssertEqual(
            CoreClipboardImagePayload.rgba(width: 1, height: 1, pixels: Data([1, 2, 3, 255])),
            CoreClipboardImagePayload.rgba(width: 1, height: 1, pixels: Data([1, 2, 3, 255])))
        XCTAssertEqual(
            CoreClipboardImagePayload.png(Data([0x89, 0x50, 0x4e, 0x47])),
            CoreClipboardImagePayload.png(Data([0x89, 0x50, 0x4e, 0x47])))
        XCTAssertEqual(
            CoreClipboardImagePayload.svg("<svg></svg>"),
            CoreClipboardImagePayload.svg("<svg></svg>"))
    }

    func testViewerAudioPolicyDefaultsOffAndRemainsIndependent() {
        let disabled = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789")
        XCTAssertFalse(disabled.receiveAudio)

        let audioOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            receiveAudio: true)
        XCTAssertTrue(audioOnly.receiveAudio)
        XCTAssertFalse(audioOnly.receiveClipboardText)
        XCTAssertFalse(audioOnly.sendClipboardText)
        XCTAssertFalse(audioOnly.fileTransferEnabled)
        XCTAssertEqual(audioOnly.fileTransferSessionEpoch, 0)
    }

    func testViewerFileTransferSeamIsDefaultOffAndEpochScoped() {
        let disabled = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789")
        XCTAssertFalse(disabled.fileTransferEnabled)
        XCTAssertEqual(disabled.fileTransferSessionEpoch, 0)

        let reserved = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1", serverPublicKey: "public-key", peerID: "123456789",
            fileTransferEnabled: true, fileTransferSessionEpoch: 7)
        XCTAssertTrue(reserved.fileTransferEnabled)
        XCTAssertEqual(reserved.fileTransferSessionEpoch, 7)
        XCTAssertFalse(reserved.receiveAudio)
        XCTAssertFalse(reserved.receiveClipboardText)
        XCTAssertFalse(reserved.sendClipboardText)
        XCTAssertFalse(reserved.receiveClipboardImage)
        XCTAssertFalse(reserved.sendClipboardImage)
    }

    func testPhase3InputTypesStaySemantic() {
        let pointer = CorePointerEvent(
            kind: .down, x: 1919, y: 1079, buttons: .left, modifiers: [.shift, .command])
        XCTAssertEqual(pointer.kind, .down)
        XCTAssertEqual(pointer.buttons, .left)
        XCTAssertEqual(pointer.modifiers, [.shift, .command])
        XCTAssertEqual(CorePointerKind.preciseScroll.rawValue, 4)
        XCTAssertEqual(CoreKey.character("a"), .character("a"))
        XCTAssertEqual(CoreKey.special(.return), .special(.return))
        XCTAssertEqual(CoreKey.physical(0), .physical(0))
    }

    func testOnlyEncodedQueueBackpressureRequiresKeyframeRecovery() {
        let backpressure = HostControlError.media(-8)  // RDN_HOST_ERR_BACKPRESSURE
        XCTAssertTrue(backpressure.isExpectedMediaDrop)
        XCTAssertTrue(backpressure.requiresMediaKeyframeRecovery)
        XCTAssertEqual(backpressure.mediaSubmissionDropReason, .networkBackpressure)

        for (error, reason) in [
            (HostControlError.media(-7), HostMediaSubmissionDropReason.reconfigure),
            (HostControlError.media(-3), HostMediaSubmissionDropReason.shutdown),
        ] {
            XCTAssertTrue(error.isExpectedMediaDrop)
            XCTAssertFalse(error.requiresMediaKeyframeRecovery)
            XCTAssertEqual(error.mediaSubmissionDropReason, reason)
        }
        for code in [-1, -2, -4, -5, -9, -10, -11, -12] {
            let validationError = HostControlError.media(Int32(code))
            XCTAssertFalse(validationError.isExpectedMediaDrop)
            XCTAssertEqual(validationError.mediaSubmissionDropReason, .invalidFrame)
        }
        XCTAssertNil(HostControlError.media(-6).mediaSubmissionDropReason)
        XCTAssertFalse(HostControlError.start(-1).requiresMediaKeyframeRecovery)
        XCTAssertNil(HostControlError.start(-1).mediaSubmissionDropReason)
    }

    func testHostJSONCommandEnvelopeRejectsSensitiveAndReservedPayloads() throws {
        let safe = try HostCommandEnvelopePolicy.envelope(
            commandName: "setApprovalMode", commandID: "command-1",
            payload: [
                "approvalMode": "manualOnly",
                "capabilities": [["name": "viewDisplay", "enabled": true]],
            ])
        XCTAssertEqual(safe["commandId"] as? String, "command-1")
        XCTAssertEqual(safe["name"] as? String, "setApprovalMode")
        XCTAssertEqual(safe["approvalMode"] as? String, "manualOnly")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: safe))

        XCTAssertNoThrow(
            try HostCommandEnvelopePolicy.envelope(
                commandName: "clearPermanentPassword", commandID: "command-2", payload: [:]))

        for payload in [
            ["password": "must-never-enter-json"],
            ["nested": ["Permanent_Password": "must-never-enter-json"]],
            ["credentials": ["value": "must-never-enter-json"]], ["opaque": Data([1, 2, 3])],
            ["name": "disableHost"], ["command_id": "replacement"],
        ] {
            XCTAssertThrowsError(
                try HostCommandEnvelopePolicy.envelope(
                    commandName: "futureCommand", commandID: "command-3", payload: payload))
        }

        XCTAssertThrowsError(
            try HostCommandEnvelopePolicy.envelope(
                commandName: "setPermanentPassword", commandID: "command-4", payload: [:])
        ) { error in
            XCTAssertFalse(String(describing: error).contains("must-never-enter-json"))
            guard case HostControlError.sensitiveCommandRequiresDedicatedABI = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testHostSecretBufferPolicyWipesSuccessAndThrownPaths() throws {
        var success = Data("canary-success".utf8)
        let count = HostSecretBufferPolicy.withMutableBytes(&success) { bytes, count in
            XCTAssertNotNil(bytes)
            return count
        }
        XCTAssertEqual(count, "canary-success".utf8.count)
        XCTAssertEqual(success, Data(repeating: 0, count: count))

        enum SyntheticFailure: Error { case rejected }
        var rejected = Data("canary-rejected".utf8)
        XCTAssertThrowsError(
            try HostSecretBufferPolicy.withMutableBytes(&rejected) { _, _ in
                throw SyntheticFailure.rejected
            })
        XCTAssertEqual(rejected, Data(repeating: 0, count: "canary-rejected".utf8.count))
    }

    func testPermanentPasswordABIErrorsAreClassifiedSemantically() {
        XCTAssertEqual(
            HostControlError.permanentPassword(-13).permanentPasswordFailure, .invalidUTF8)
        XCTAssertEqual(HostControlError.permanentPassword(-14).permanentPasswordFailure, .empty)
        XCTAssertEqual(HostControlError.permanentPassword(-15).permanentPasswordFailure, .tooShort)
        XCTAssertEqual(HostControlError.permanentPassword(-16).permanentPasswordFailure, .tooLong)
        XCTAssertEqual(
            HostControlError.permanentPassword(-17).permanentPasswordFailure, .forbiddenCharacter)
        XCTAssertEqual(
            HostControlError.permanentPassword(-18).permanentPasswordFailure, .outerWhitespace)
        XCTAssertEqual(
            HostControlError.permanentPassword(-19).permanentPasswordFailure, .changeDisabled)
        XCTAssertEqual(HostControlError.permanentPassword(-20).permanentPasswordFailure, .storage)
        XCTAssertEqual(HostControlError.permanentPassword(-999).permanentPasswordFailure, .unknown)
        XCTAssertNil(HostControlError.command(-20).permanentPasswordFailure)
    }

    func testSleepRecoveryABIErrorsAreClassifiedSemantically() {
        let cases: [(Int32, HostSleepRecoveryFailure)] = [
            (-1, .invalidEpoch), (-7, .staleEpoch), (-3, .invalidState), (-4, .unsupported),
            (-6, .internalFailure), (-999, .unknown),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                HostControlError.sleepRecovery(.beginSleep, code).sleepRecoveryFailure, expected)
        }
        XCTAssertNil(HostControlError.stop(-7).sleepRecoveryFailure)
    }

    func testNetworkPathRecoveryABIErrorsAreClassifiedSemantically() {
        let cases: [(Int32, HostNetworkPathRecoveryFailure)] = [
            (-27, .staleGeneration), (-3, .invalidState), (-4, .unsupported),
            (-6, .internalFailure), (-1, .unknown), (-999, .unknown),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                HostControlError.networkPathRecovery(code).networkPathRecoveryFailure, expected)
        }
        XCTAssertNil(HostControlError.sleepRecovery(.beginSleep, -27).networkPathRecoveryFailure)
    }

    func testApprovalDecisionErrorsAreClassifiedSemantically() {
        XCTAssertEqual(HostControlError.command(-21).approvalDecisionFailure, .notFound)
        XCTAssertEqual(HostControlError.command(-22).approvalDecisionFailure, .alreadyFinalized)
        XCTAssertEqual(HostControlError.command(-23).approvalDecisionFailure, .expired)
        XCTAssertNil(HostControlError.command(-5).approvalDecisionFailure)
        XCTAssertNil(HostControlError.snapshot(-21).approvalDecisionFailure)
    }

    func testActiveSessionCommandsAreTypedAndErrorsAreClassified() {
        XCTAssertEqual(
            HostSessionRevocableCapability.keyboardAndMouse.commandName,
            "disableInputForActiveSession")
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardRead.commandName,
            "disableClipboardReadForActiveSession")
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardWrite.commandName,
            "disableClipboardWriteForActiveSession")
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboard.commandName, "disableClipboardForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.systemAudio.commandName, "disableAudioForActiveSession")
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardRead.snapshotCapabilityNames, ["readClipboard"])
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardWrite.snapshotCapabilityNames,
            ["writeClipboard"])
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboard.snapshotCapabilityNames,
            ["readClipboard", "writeClipboard"])
        XCTAssertEqual(HostControlError.command(-24).sessionCommandFailure, .notFound)
        XCTAssertEqual(HostControlError.command(-25).sessionCommandFailure, .staleConnection)
        XCTAssertEqual(HostControlError.command(-26).sessionCommandFailure, .unavailable)
        XCTAssertNil(HostControlError.command(-5).sessionCommandFailure)
        XCTAssertNil(HostControlError.snapshot(-24).sessionCommandFailure)
    }

    func testHostSessionCommandGateWaitsForAuthoritativeSnapshotConvergence() {
        var gate = HostSessionCommandGate()
        let allCapabilities = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            "hearSystemAudio",
        ]

        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.begin(connectionID: "host:1", intent: .disable(.keyboardAndMouse)))

        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertFalse(gate.begin(connectionID: "host:stale", intent: .disable(.keyboardAndMouse)))
        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disable(.keyboardAndMouse)))
        XCTAssertFalse(gate.begin(connectionID: "host:1", intent: .disconnect))
        XCTAssertEqual(gate.resolvingIntent(connectionID: "host:1"), .disable(.keyboardAndMouse))

        // Command acceptance is not completion. The gate remains closed until
        // the capability actually disappears from the Rust snapshot.
        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: allCapabilities.filter { $0 != "controlKeyboardMouse" })
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disable(.clipboardRead)))
        let withoutKeyboard = allCapabilities.filter { $0 != "controlKeyboardMouse" }
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "readClipboard" })
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disable(.clipboardWrite)))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "writeClipboard" })
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        // Exercise the legacy two-direction alias from a fresh bidirectional
        // snapshot; the preceding directional cases are independent fixtures.
        gate.observe(connectionID: "host:1", activeCapabilities: withoutKeyboard)
        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disable(.clipboard)))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "readClipboard" })
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        let viewAndAudio = withoutKeyboard.filter {
            $0 != "readClipboard" && $0 != "writeClipboard"
        }
        gate.observe(connectionID: "host:1", activeCapabilities: viewAndAudio)
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disable(.systemAudio)))
        gate.complete(connectionID: "host:stale", intent: .disable(.systemAudio))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.complete(connectionID: "host:1", intent: .disable(.systemAudio))
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disconnect))
        gate.observe(connectionID: "host:1", activeCapabilities: viewAndAudio)
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        gate.observe(connectionID: "host:2", activeCapabilities: ["viewDisplay"])
        XCTAssertFalse(gate.begin(connectionID: "host:2", intent: .disable(.systemAudio)))
        XCTAssertTrue(gate.begin(connectionID: "host:2", intent: .disconnect))
        gate.reset()
        XCTAssertNil(gate.currentConnectionID)
        XCTAssertNil(gate.resolvingIntent(connectionID: "host:2"))
    }

    func testHostSnapshotRecoversPendingApprovalAndActiveSessionAndFailsClosed() throws {
        let pending: [String: Any] = [
            "connectionId": "host-instance:7", "remoteId": "123456789", "remoteName": "Remote Mac",
            "remotePlatform": "macOS", "remoteMetadataTrust": "untrusted",
            "requestedAt": 1_700_000_000_000 as UInt64, "expiresAt": 1_700_000_030_000 as UInt64,
            "requestedCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "transport": "unknown", "authenticationMethod": "localApproval", "riskAlerts": [],
        ]
        let activeSession: [String: Any] = [
            "connectionId": "host-instance:9", "remoteId": "987654321",
            "remoteName": "Controlled Mac", "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted", "startedAt": 1_700_000_000_500 as UInt64,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            ], "activeCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "inputAvailability": "available", "inputUnavailableReason": NSNull(),
        ]
        func document(
            pendingApproval: Any, activeSession: Any = NSNull(),
            sessionAvailability: String = "available", sessionUnavailableReason: Any = NSNull(),
            hostState: String = "ready", registrationStatus: String = "ready",
            recoveryEpoch: Any = 0, recoveryStatus: String = "running",
            authenticatedConnectionCount: Any = 1
        ) -> [String: Any] {
            [
                "schemaVersion": 8, "hostInstanceId": "host-instance", "hostState": hostState,
                "localId": "987654321",
                "authenticatedConnectionCount": authenticatedConnectionCount,
                "sessionAvailability": sessionAvailability,
                "sessionUnavailableReason": sessionUnavailableReason,
                "registrationStatus": registrationStatus, "recoveryEpoch": recoveryEpoch,
                "recoveryStatus": recoveryStatus, "pendingApproval": pendingApproval,
                "activeSession": activeSession,
                "temporaryPasswordPresentation": ["policy": "redacted"],
                "passwordPolicy": [
                    "localPasswordSet": false, "effectivePasswordSet": false,
                    "usingPresetPassword": false, "changeAllowed": true,
                    "strengthPolicy": [
                        "version": 1, "minimumCharacters": 6, "maximumCharacters": 128,
                        "maximumUtf8Bytes": 512, "rejectsControlCharacters": true,
                        "rejectsOuterWhitespace": true,
                    ],
                ], "lastError": NSNull(), "observedAt": 1_700_000_001_000 as UInt64,
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: document(pendingApproval: pending, activeSession: activeSession))
        let snapshot = try HostCoreSnapshot(rawJSON: data)
        XCTAssertEqual(snapshot.schemaVersion, 8)
        XCTAssertEqual(snapshot.authenticatedConnectionCount, 1)
        XCTAssertEqual(snapshot.sessionAvailability, .available)
        XCTAssertNil(snapshot.sessionUnavailableReason)
        XCTAssertEqual(snapshot.recoveryEpoch, 0)
        XCTAssertEqual(snapshot.recoveryStatus, .running)
        XCTAssertEqual(snapshot.pendingApproval?.connectionId, "host-instance:7")
        XCTAssertEqual(snapshot.pendingApproval?.remoteName, "Remote Mac")
        XCTAssertEqual(
            snapshot.pendingApproval?.requestedCapabilities,
            ["viewDisplay", "controlKeyboardMouse"])
        XCTAssertEqual(snapshot.activeSession?.connectionId, "host-instance:9")
        XCTAssertEqual(snapshot.activeSession?.remoteName, "Controlled Mac")
        XCTAssertEqual(
            snapshot.activeSession?.initialCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard"])
        XCTAssertEqual(
            snapshot.activeSession?.activeCapabilities, ["viewDisplay", "controlKeyboardMouse"])
        XCTAssertEqual(snapshot.activeSession?.inputAvailability, .available)
        XCTAssertNil(snapshot.activeSession?.inputUnavailableReason)

        let noPending = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document(pendingApproval: NSNull())))
        XCTAssertNil(noPending.pendingApproval)
        XCTAssertNil(noPending.activeSession)

        var missingCount = document(pendingApproval: NSNull())
        missingCount.removeValue(forKey: "authenticatedConnectionCount")
        XCTAssertThrowsError(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(withJSONObject: missingCount)))
        for invalidCount in [true as Any, 1.5 as Any] {
            XCTAssertThrowsError(
                try HostCoreSnapshot(
                    rawJSON: JSONSerialization.data(
                        withJSONObject: document(
                            pendingApproval: NSNull(), authenticatedConnectionCount: invalidCount)))
            )
        }
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: activeSession,
                        authenticatedConnectionCount: 0))))

        var invalidPending = pending
        invalidPending["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(pendingApproval: invalidPending))))
        invalidPending = pending
        invalidPending["requestedCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(pendingApproval: invalidPending))))
        invalidPending = pending
        invalidPending["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(pendingApproval: invalidPending))))
        invalidPending = pending
        invalidPending["riskAlerts"] = ["futureRiskCode"]
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(pendingApproval: invalidPending))))

        var invalidSession = activeSession
        invalidSession["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "hearSystemAudio"]
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["connectionId"] = "other-host:9"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
        ]
        let readOnlyClipboard = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(
                withJSONObject: document(pendingApproval: NSNull(), activeSession: invalidSession)))
        XCTAssertEqual(
            readOnlyClipboard.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "readClipboard"])
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = [
            "viewDisplay", "controlKeyboardMouse", "writeClipboard",
        ]
        let writeOnlyClipboard = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(
                withJSONObject: document(pendingApproval: NSNull(), activeSession: invalidSession)))
        XCTAssertEqual(
            writeOnlyClipboard.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "writeClipboard"])
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "available"
        invalidSession["inputUnavailableReason"] = NSNull()
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "sessionUnavailable"
        let limitedSnapshot = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(
                withJSONObject: document(pendingApproval: NSNull(), activeSession: invalidSession)))
        XCTAssertEqual(limitedSnapshot.activeSession?.inputAvailability, .limited)
        XCTAssertEqual(limitedSnapshot.activeSession?.inputUnavailableReason, .sessionUnavailable)
        let limitedHostSnapshot = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(
                withJSONObject: document(
                    pendingApproval: NSNull(), sessionAvailability: "limited",
                    sessionUnavailableReason: "sessionUnavailable")))
        XCTAssertEqual(limitedHostSnapshot.sessionAvailability, .limited)
        XCTAssertEqual(limitedHostSnapshot.sessionUnavailableReason, .sessionUnavailable)
        for invalidTuple in [
            ("available", "sessionUnavailable" as Any), ("limited", NSNull() as Any),
            ("future", NSNull() as Any),
        ] {
            XCTAssertThrowsError(
                try HostCoreSnapshot(
                    rawJSON: JSONSerialization.data(
                        withJSONObject: document(
                            pendingApproval: NSNull(), sessionAvailability: invalidTuple.0,
                            sessionUnavailableReason: invalidTuple.1))))
        }
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "disabled"
        invalidSession["inputUnavailableReason"] = "accessibilityDenied"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "futureReason"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        invalidSession = activeSession
        invalidSession["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), activeSession: invalidSession))))
        var oldSchema = document(pendingApproval: NSNull())
        oldSchema["schemaVersion"] = 6
        XCTAssertThrowsError(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(withJSONObject: oldSchema)))
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), recoveryStatus: "futureStatus"))))
        XCTAssertThrowsError(
            try HostCoreSnapshot(
                rawJSON: JSONSerialization.data(
                    withJSONObject: document(
                        pendingApproval: NSNull(), hostState: "starting",
                        registrationStatus: "suspending", recoveryEpoch: 0,
                        recoveryStatus: "suspending"))))
        for invalidEpoch: Any in [-1, 1.5] {
            XCTAssertThrowsError(
                try HostCoreSnapshot(
                    rawJSON: JSONSerialization.data(
                        withJSONObject: document(
                            pendingApproval: NSNull(), recoveryEpoch: invalidEpoch))))
        }
        let suspended = try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(
                withJSONObject: document(
                    pendingApproval: NSNull(), hostState: "starting",
                    registrationStatus: "suspended", recoveryEpoch: 7, recoveryStatus: "suspended"))
        )
        XCTAssertEqual(suspended.recoveryEpoch, 7)
        XCTAssertEqual(suspended.recoveryStatus, .suspended)
    }

    func testHostApprovalDecisionGateRejectsStaleAndDuplicateActions() {
        var gate = HostApprovalDecisionGate()
        XCTAssertFalse(gate.observe(connectionID: nil))

        XCTAssertTrue(gate.observe(connectionID: "host:1"))
        XCTAssertFalse(gate.observe(connectionID: "host:1"))
        XCTAssertFalse(gate.beginDecision(connectionID: "host:stale"))
        XCTAssertTrue(gate.beginDecision(connectionID: "host:1"))
        XCTAssertFalse(gate.beginDecision(connectionID: "host:1"))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))

        XCTAssertFalse(gate.observe(connectionID: "host:1"))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        XCTAssertFalse(gate.observe(connectionID: nil))
        XCTAssertNil(gate.decisionInFlightConnectionID)
        XCTAssertFalse(gate.beginDecision(connectionID: "host:1"))

        XCTAssertTrue(gate.observe(connectionID: "host:2"))
        XCTAssertTrue(gate.beginDecision(connectionID: "host:2"))
        gate.completeDecision(connectionID: "host:stale")
        XCTAssertTrue(gate.isResolving(connectionID: "host:2"))
        gate.completeDecision(connectionID: "host:2")
        XCTAssertNil(gate.decisionInFlightConnectionID)

        gate.reset()
        XCTAssertNil(gate.currentConnectionID)
        XCTAssertTrue(gate.observe(connectionID: "host:2"))
    }

    func testHostMediaControlEnvelopeFailsClosedAndTracksRouteEpochs() throws {
        let reconfigure = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 30,
                "bitrate": 8_000_000,
            ])?.mediaControl)
        XCTAssertEqual(reconfigure.command, .reconfigure)
        XCTAssertEqual(reconfigure.codec, .h264)
        XCTAssertEqual(reconfigure.width, 1920)

        let h265Reconfigure = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 10, "displayId": 0,
                "displayRevision": 3, "codec": "h265", "width": 1920, "height": 1080, "fps": 30,
                "bitrate": 8_000_000,
            ])?.mediaControl)
        XCTAssertEqual(h265Reconfigure.codec, .h265)
        XCTAssertEqual(h265Reconfigure.codecEpoch, 10)

        let matchingStop = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "stopCapture", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
            ])?.mediaControl)
        XCTAssertTrue(reconfigure.matchesRoute(matchingStop))

        let staleRefresh = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "requestIdr", "connectionEpoch": 6, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3,
            ])?.mediaControl)
        XCTAssertFalse(reconfigure.matchesRoute(staleRefresh))

        XCTAssertNil(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 0,
            ])?.mediaControl)
        XCTAssertNil(
            try hostEvent(payload: [
                "command": "requestIdr", "connectionEpoch": 0, "codecEpoch": 9, "displayId": 0,
            ])?.mediaControl)
        XCTAssertNil(try hostEvent(payload: [:], schemaVersion: 2))
    }

    func testDisplayReconfigureMarkerAndControlProvenanceFailClosed() throws {
        let markerPayload: [String: Any] = [
            "displayReconfigureGeneration": 4, "displayId": 0, "previousDisplayRevision": 2,
            "previousConnectionEpoch": 7, "previousCodecEpoch": 9,
        ]
        let started = try XCTUnwrap(
            try hostEvent(payload: markerPayload, eventType: "mediaDisplayReconfigureStarted")?
                .displayReconfigureStarted)
        XCTAssertEqual(started.generation, 4)
        XCTAssertEqual(started.displayID, 0)
        XCTAssertEqual(started.previousDisplayRevision, 2)
        XCTAssertEqual(started.previousConnectionEpoch, 7)
        XCTAssertEqual(started.previousCodecEpoch, 9)

        let provenance: [String: Any] = [
            "displayReconfigureGeneration": 4, "previousDisplayRevision": 2,
            "previousConnectionEpoch": 7, "previousCodecEpoch": 9,
        ]
        let replacement = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 8, "codecEpoch": 10, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1_920, "height": 1_080, "fps": 30,
                "displayReconfigure": provenance,
            ])?.mediaControl)
        XCTAssertEqual(
            replacement.displayReconfigure,
            .init(
                generation: 4, previousDisplayRevision: 2, previousConnectionEpoch: 7,
                previousCodecEpoch: 9))

        for invalid in [
            [
                "displayReconfigureGeneration": 0, "previousDisplayRevision": 2,
                "previousConnectionEpoch": 7, "previousCodecEpoch": 9,
            ],
            [
                "displayReconfigureGeneration": 4, "previousDisplayRevision": 3,
                "previousConnectionEpoch": 7, "previousCodecEpoch": 9,
            ],
            [
                "displayReconfigureGeneration": 4, "previousDisplayRevision": 2,
                "previousConnectionEpoch": 8, "previousCodecEpoch": 9,
            ],
        ] {
            XCTAssertNil(
                try hostEvent(payload: [
                    "command": "reconfigure", "connectionEpoch": 8, "codecEpoch": 10,
                    "displayId": 0, "displayRevision": 3, "codec": "h264", "width": 1_920,
                    "height": 1_080, "fps": 30, "displayReconfigure": invalid,
                ])?.mediaControl)
        }
        var malformedMarker = markerPayload
        malformedMarker["previousCodecEpoch"] = true
        XCTAssertNil(
            try hostEvent(payload: malformedMarker, eventType: "mediaDisplayReconfigureStarted")?
                .displayReconfigureStarted)
        XCTAssertNil(
            try hostEvent(payload: [
                "command": "stopCapture", "connectionEpoch": 8, "codecEpoch": 10, "displayId": 0,
                "displayReconfigure": provenance,
            ])?.mediaControl)
    }

    func testHostMediaDiagnosticIsSanitizedAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "firstPacketAcknowledged", "connectionEpoch": 7, "codecEpoch": 9,
            "displayId": 0, "displayRevision": 3, "codec": "h264", "framing": "avcc",
            "ptsUs": 42_999, "keyframe": true, "hasParameterSets": true, "subscriberCount": 1,
        ]
        let diagnostic = try XCTUnwrap(
            try hostEvent(payload: payload, eventType: "mediaDiagnostic")?.mediaDiagnostic)
        XCTAssertEqual(diagnostic.kind, .firstPacketAcknowledged)
        XCTAssertEqual(diagnostic.codec, .h264)
        XCTAssertEqual(diagnostic.framing, .avcc)
        XCTAssertEqual(diagnostic.presentationTimeUS, 42_999)
        XCTAssertTrue(diagnostic.isKeyframe)
        XCTAssertTrue(diagnostic.hasParameterSets)
        XCTAssertEqual(diagnostic.subscriberCount, 1)

        let route = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))
        let staleRoute = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 8, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertFalse(diagnostic.matchesRoute(staleRoute))

        var invalid = payload
        invalid["subscriberCount"] = 0
        XCTAssertNil(try hostEvent(payload: invalid, eventType: "mediaDiagnostic")?.mediaDiagnostic)
        invalid = payload
        invalid["connectionEpoch"] = true
        XCTAssertNil(try hostEvent(payload: invalid, eventType: "mediaDiagnostic")?.mediaDiagnostic)
        invalid = payload
        invalid["framing"] = "unknown"
        XCTAssertNil(try hostEvent(payload: invalid, eventType: "mediaDiagnostic")?.mediaDiagnostic)

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("peerId"))
        XCTAssertFalse(text.contains("data"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("server"))
    }

    func testHostMediaQueueDiagnosticIsBoundedSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
            "displayRevision": 3, "currentDepth": 1, "maximumDepth": 3, "capacity": 3,
        ]
        let diagnostic = try XCTUnwrap(
            try hostEvent(payload: payload, eventType: "mediaQueueDiagnostic")?.mediaQueueDiagnostic
        )
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.currentDepth, 1)
        XCTAssertEqual(diagnostic.maximumDepth, 3)
        XCTAssertEqual(diagnostic.capacity, 3)

        let route = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true }, { $0["currentDepth"] = 4 },
            { $0["maximumDepth"] = 4 }, { $0["capacity"] = 0 }, { $0["maximumDepth"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(
                try hostEvent(payload: invalid, eventType: "mediaQueueDiagnostic")?
                    .mediaQueueDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaWriterDiagnosticIsConsistentSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
            "displayRevision": 3, "cycles": 3, "subscriberDispatches": 5,
            "dispatchWallTotalUs": 120, "maximumDispatchWallUs": 70, "confirmationWaitTotalUs": 900,
            "maximumConfirmationWaitUs": 400, "completedConfirmations": 2,
            "timedOutConfirmations": 1,
        ]
        let diagnostic = try XCTUnwrap(
            try hostEvent(payload: payload, eventType: "mediaWriterDiagnostic")?
                .mediaWriterDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.cycles, 3)
        XCTAssertEqual(diagnostic.subscriberDispatches, 5)
        XCTAssertEqual(diagnostic.maximumDispatchWallUS, 70)
        XCTAssertEqual(diagnostic.maximumConfirmationWaitUS, 400)

        let route = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h265", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true }, { $0["subscriberDispatches"] = 2 },
            { $0["maximumDispatchWallUs"] = 121 }, { $0["maximumConfirmationWaitUs"] = 901 },
            { $0["completedConfirmations"] = 3 }, { $0["cycles"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(
                try hostEvent(payload: invalid, eventType: "mediaWriterDiagnostic")?
                    .mediaWriterDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaNetworkDiagnosticPreservesUnavailableSamplesAndRouteScope() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
            "displayRevision": 3, "subscriberCount": 2, "qosSubscriberCount": 2,
            "delaySampledSubscribers": 2, "rttSampledSubscribers": 1,
            "responseDelayedSubscribers": 1, "worstNetworkDelayMs": 180, "worstRttMs": 42,
        ]
        let diagnostic = try XCTUnwrap(
            try hostEvent(payload: payload, eventType: "mediaNetworkDiagnostic")?
                .mediaNetworkDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 2)
        XCTAssertEqual(diagnostic.qosSubscriberCount, 2)
        XCTAssertEqual(diagnostic.delaySampledSubscribers, 2)
        XCTAssertEqual(diagnostic.rttSampledSubscribers, 1)
        XCTAssertEqual(diagnostic.responseDelayedSubscribers, 1)
        XCTAssertEqual(diagnostic.worstNetworkDelayMS, 180)
        XCTAssertEqual(diagnostic.worstRTTMS, 42)

        let route = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h265", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        var unsampled = payload
        unsampled["delaySampledSubscribers"] = 0
        unsampled["rttSampledSubscribers"] = 0
        unsampled["responseDelayedSubscribers"] = 0
        unsampled["worstNetworkDelayMs"] = NSNull()
        unsampled["worstRttMs"] = NSNull()
        let unavailable = try XCTUnwrap(
            try hostEvent(payload: unsampled, eventType: "mediaNetworkDiagnostic")?
                .mediaNetworkDiagnostic)
        XCTAssertNil(unavailable.worstNetworkDelayMS)
        XCTAssertNil(unavailable.worstRTTMS)

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true }, { $0["qosSubscriberCount"] = 3 },
            { $0["delaySampledSubscribers"] = 3 }, { $0["rttSampledSubscribers"] = 3 },
            { $0["responseDelayedSubscribers"] = 3 }, { $0["worstNetworkDelayMs"] = NSNull() },
            { $0.removeValue(forKey: "worstRttMs") }, { $0["worstRttMs"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(
                try hostEvent(payload: invalid, eventType: "mediaNetworkDiagnostic")?
                    .mediaNetworkDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaTransportDiagnosticPreservesUnknownAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
            "displayRevision": 3, "subscriberCount": 4, "directSubscribers": 2,
            "relaySubscribers": 1, "unknownSubscribers": 1,
        ]
        let diagnostic = try XCTUnwrap(
            try hostEvent(payload: payload, eventType: "mediaTransportDiagnostic")?
                .mediaTransportDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 4)
        XCTAssertEqual(diagnostic.directSubscribers, 2)
        XCTAssertEqual(diagnostic.relaySubscribers, 1)
        XCTAssertEqual(diagnostic.unknownSubscribers, 1)

        let route = try XCTUnwrap(
            try hostEvent(payload: [
                "command": "reconfigure", "connectionEpoch": 7, "codecEpoch": 9, "displayId": 0,
                "displayRevision": 3, "codec": "h264", "width": 1920, "height": 1080, "fps": 30,
            ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true }, { $0["unknownSubscribers"] = 0 },
            { $0["directSubscribers"] = -1 }, { $0["relaySubscribers"] = 1.5 },
            { $0.removeValue(forKey: "subscriberCount") }, { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(
                try hostEvent(payload: invalid, eventType: "mediaTransportDiagnostic")?
                    .mediaTransportDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testLoadsBuiltCoreAndVerifiesABIWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RDN_CORE_LIBRARY"] else {
            throw XCTSkip("set RDN_CORE_LIBRARY for the built-core smoke test")
        }
        let client = try RustDeskCoreClient(
            libraryURL: URL(fileURLWithPath: path), onState: { _ in }, onVideo: { _ in },
            onMetrics: { _ in })
        XCTAssertEqual(client.upstreamCommit, RustDeskCoreClient.expectedUpstreamCommit)
        client.disconnect()
    }
}
