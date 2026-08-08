import CoreBridge
import XCTest

final class CoreBridgeContractTests: XCTestCase {
    private func hostEvent(
        payload: [String: Any],
        eventType: String = "mediaControl",
        schemaVersion: Int = 1
    ) throws -> HostCoreEvent? {
        let envelope: [String: Any] = [
            "schemaVersion": schemaVersion,
            "eventId": 0,
            "eventType": eventType,
            "hostInstanceId": "test-host-instance",
            "sentAt": 1,
            "payload": payload,
        ]
        return HostCoreEvent(rawJSON: try JSONSerialization.data(withJSONObject: envelope))
    }

    func testPinsRustDesk149Commit() {
        XCTAssertEqual(RustDeskCoreClient.abiVersion, 5)
        XCTAssertEqual(
            RustDeskCoreClient.expectedUpstreamCommit,
            "6c578292e8ebbbec708b76986ba8c4bc7c509747"
        )
    }

    func testHostEventAndSnapshotSchemaVersionsAreIndependent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/rdn_host_bridge.rs")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        XCTAssertTrue(bridge.contains("const EVENT_SCHEMA_VERSION: u32 = 1;"))
        XCTAssertTrue(bridge.contains("const SNAPSHOT_SCHEMA_VERSION: u32 = 5;"))
        XCTAssertTrue(bridge.contains("\"schemaVersion\": EVENT_SCHEMA_VERSION"))
        XCTAssertTrue(bridge.contains(
            "map.insert(\"schemaVersion\".into(), json!(SNAPSHOT_SCHEMA_VERSION));"
        ))
    }

    func testNativeHostUsesCanonicalCGSessionOnConsoleKey() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/upstream-1.4.9.patch")
        let patch = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(patch.contains("\"kCGSSessionOnConsoleKey\""))
        XCTAssertFalse(patch.contains("\"kCGSessionOnConsoleKey\""))
    }

    func testHostAgentModeDispatchPrecedesNSApplicationBootstrap() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let dispatch = try XCTUnwrap(source.range(
            of: "RustDeskNativeProcessModePolicy.resolve(arguments: CommandLine.arguments)"
        ))
        let appKitBootstrap = try XCTUnwrap(source.range(of: "NSApplication.shared"))

        XCTAssertLessThan(dispatch.lowerBound, appKitBootstrap.lowerBound)
        XCTAssertTrue(source.contains("HostAgentBootstrap.failClosed()"))
    }

    func testHostAgentProcessRuntimeUsesOneBootstrapAuthorityButRemainsDisabled() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/HostAgentProcessRuntime.swift")
        let runtimeSource = try String(contentsOf: runtimeURL, encoding: .utf8)
        let contextPreparation = try XCTUnwrap(runtimeSource.range(
            of: "HostAgentBootstrapContext.prepare()"
        ))
        let clientCreation = try XCTUnwrap(runtimeSource.range(of: "HostControlClient("))

        XCTAssertLessThan(contextPreparation.lowerBound, clientCreation.lowerBound)
        XCTAssertTrue(runtimeSource.contains("bootstrapOwner: bootstrapContext"))
        XCTAssertTrue(runtimeSource.contains("let configuration = context.configuration"))
        XCTAssertTrue(runtimeSource.contains("configAppName: configuration.hostConfigAppName"))
        XCTAssertTrue(runtimeSource.contains("configOrganization: configuration.hostConfigOrganization"))
        XCTAssertTrue(runtimeSource.contains("rendezvousServer: configuration.rendezvousServer"))
        XCTAssertTrue(runtimeSource.contains("serverPublicKey: configuration.serverPublicKey"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentProcessRuntime.start("))
        XCTAssertTrue(appSource.contains("HostAgentBootstrap.failClosed()"))
    }

    func testProductAppPublishesOnlyAfterCanonicalCatalogReadOrSave() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "catalog = try catalogStore.load()\n            reconcileHostAgentBootstrap()"
        ))
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let catalogSaveLines = sourceLines.indices.filter {
            sourceLines[$0].contains("catalogStore.save(")
        }
        XCTAssertFalse(catalogSaveLines.isEmpty)
        for saveLine in catalogSaveLines {
            let endLine = min(sourceLines.endIndex, saveLine + 5)
            XCTAssertTrue(
                sourceLines[saveLine..<endLine].contains {
                    $0.contains("reconcileHostAgentBootstrap()")
                },
                "canonical catalog save at line \(saveLine + 1) must reconcile afterward"
            )
        }
        XCTAssertTrue(source.contains(
            ".reconcileSavedCatalog(from: catalogStore)"
        ))
        XCTAssertTrue(source.contains(
            "hostAgentBootstrapState == .degraded"
        ))
        XCTAssertTrue(source.contains(
            "errorText: combinedHostErrorText"
        ))
    }

    func testConnectionConfigDoesNotPersistPassword() {
        let config = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            password: "one-time-password"
        )
        XCTAssertEqual(config.password, "one-time-password")
        XCTAssertFalse(config.forceRelay)
    }

    func testPhase3InputTypesStaySemantic() {
        let pointer = CorePointerEvent(
            kind: .down,
            x: 1919,
            y: 1079,
            buttons: .left,
            modifiers: [.shift, .command]
        )
        XCTAssertEqual(pointer.kind, .down)
        XCTAssertEqual(pointer.buttons, .left)
        XCTAssertEqual(pointer.modifiers, [.shift, .command])
        XCTAssertEqual(CorePointerKind.preciseScroll.rawValue, 4)
        XCTAssertEqual(CoreKey.character("a"), .character("a"))
        XCTAssertEqual(CoreKey.special(.return), .special(.return))
        XCTAssertEqual(CoreKey.physical(0), .physical(0))
    }

    func testOnlyEncodedQueueBackpressureRequiresKeyframeRecovery() {
        let backpressure = HostControlError.media(-8) // RDN_HOST_ERR_BACKPRESSURE
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
            commandName: "setApprovalMode",
            commandID: "command-1",
            payload: [
                "approvalMode": "manualOnly",
                "capabilities": [["name": "viewDisplay", "enabled": true]],
            ]
        )
        XCTAssertEqual(safe["commandId"] as? String, "command-1")
        XCTAssertEqual(safe["name"] as? String, "setApprovalMode")
        XCTAssertEqual(safe["approvalMode"] as? String, "manualOnly")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: safe))

        XCTAssertNoThrow(try HostCommandEnvelopePolicy.envelope(
            commandName: "clearPermanentPassword",
            commandID: "command-2",
            payload: [:]
        ))

        for payload in [
            ["password": "must-never-enter-json"],
            ["nested": ["Permanent_Password": "must-never-enter-json"]],
            ["credentials": ["value": "must-never-enter-json"]],
            ["opaque": Data([1, 2, 3])],
            ["name": "disableHost"],
            ["command_id": "replacement"],
        ] {
            XCTAssertThrowsError(try HostCommandEnvelopePolicy.envelope(
                commandName: "futureCommand",
                commandID: "command-3",
                payload: payload
            ))
        }

        XCTAssertThrowsError(try HostCommandEnvelopePolicy.envelope(
            commandName: "setPermanentPassword",
            commandID: "command-4",
            payload: [:]
        )) { error in
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
        XCTAssertThrowsError(try HostSecretBufferPolicy.withMutableBytes(&rejected) { _, _ in
            throw SyntheticFailure.rejected
        })
        XCTAssertEqual(rejected, Data(repeating: 0, count: "canary-rejected".utf8.count))
    }

    func testPermanentPasswordABIErrorsAreClassifiedSemantically() {
        XCTAssertEqual(HostControlError.permanentPassword(-13).permanentPasswordFailure, .invalidUTF8)
        XCTAssertEqual(HostControlError.permanentPassword(-14).permanentPasswordFailure, .empty)
        XCTAssertEqual(HostControlError.permanentPassword(-15).permanentPasswordFailure, .tooShort)
        XCTAssertEqual(HostControlError.permanentPassword(-16).permanentPasswordFailure, .tooLong)
        XCTAssertEqual(
            HostControlError.permanentPassword(-17).permanentPasswordFailure,
            .forbiddenCharacter)
        XCTAssertEqual(
            HostControlError.permanentPassword(-18).permanentPasswordFailure,
            .outerWhitespace)
        XCTAssertEqual(
            HostControlError.permanentPassword(-19).permanentPasswordFailure,
            .changeDisabled)
        XCTAssertEqual(HostControlError.permanentPassword(-20).permanentPasswordFailure, .storage)
        XCTAssertEqual(HostControlError.permanentPassword(-999).permanentPasswordFailure, .unknown)
        XCTAssertNil(HostControlError.command(-20).permanentPasswordFailure)
    }

    func testApprovalDecisionErrorsAreClassifiedSemantically() {
        XCTAssertEqual(HostControlError.command(-21).approvalDecisionFailure, .notFound)
        XCTAssertEqual(
            HostControlError.command(-22).approvalDecisionFailure,
            .alreadyFinalized
        )
        XCTAssertEqual(HostControlError.command(-23).approvalDecisionFailure, .expired)
        XCTAssertNil(HostControlError.command(-5).approvalDecisionFailure)
        XCTAssertNil(HostControlError.snapshot(-21).approvalDecisionFailure)
    }

    func testActiveSessionCommandsAreTypedAndErrorsAreClassified() {
        XCTAssertEqual(
            HostSessionRevocableCapability.keyboardAndMouse.commandName,
            "disableInputForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboard.commandName,
            "disableClipboardForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.systemAudio.commandName,
            "disableAudioForActiveSession"
        )
        XCTAssertEqual(HostControlError.command(-24).sessionCommandFailure, .notFound)
        XCTAssertEqual(HostControlError.command(-25).sessionCommandFailure, .staleConnection)
        XCTAssertEqual(HostControlError.command(-26).sessionCommandFailure, .unavailable)
        XCTAssertNil(HostControlError.command(-5).sessionCommandFailure)
        XCTAssertNil(HostControlError.snapshot(-24).sessionCommandFailure)
    }

    func testHostSessionCommandGateWaitsForAuthoritativeSnapshotConvergence() {
        var gate = HostSessionCommandGate()
        let allCapabilities = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
            "writeClipboard", "hearSystemAudio",
        ]

        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.begin(
            connectionID: "host:1",
            intent: .disable(.keyboardAndMouse)
        ))

        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertFalse(gate.begin(
            connectionID: "host:stale",
            intent: .disable(.keyboardAndMouse)
        ))
        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.keyboardAndMouse)
        ))
        XCTAssertFalse(gate.begin(connectionID: "host:1", intent: .disconnect))
        XCTAssertEqual(
            gate.resolvingIntent(connectionID: "host:1"),
            .disable(.keyboardAndMouse)
        )

        // Command acceptance is not completion. The gate remains closed until
        // the capability actually disappears from the Rust snapshot.
        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: allCapabilities.filter { $0 != "controlKeyboardMouse" }
        )
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.clipboard)
        ))
        let withoutKeyboard = allCapabilities.filter { $0 != "controlKeyboardMouse" }
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "readClipboard" }
        )
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        let viewAndAudio = withoutKeyboard.filter {
            $0 != "readClipboard" && $0 != "writeClipboard"
        }
        gate.observe(connectionID: "host:1", activeCapabilities: viewAndAudio)
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.systemAudio)
        ))
        gate.complete(connectionID: "host:stale", intent: .disable(.systemAudio))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.complete(connectionID: "host:1", intent: .disable(.systemAudio))
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disconnect))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: viewAndAudio
        )
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        gate.observe(connectionID: "host:2", activeCapabilities: ["viewDisplay"])
        XCTAssertFalse(gate.begin(
            connectionID: "host:2",
            intent: .disable(.systemAudio)
        ))
        XCTAssertTrue(gate.begin(connectionID: "host:2", intent: .disconnect))
        gate.reset()
        XCTAssertNil(gate.currentConnectionID)
        XCTAssertNil(gate.resolvingIntent(connectionID: "host:2"))
    }

    func testHostSnapshotRecoversPendingApprovalAndActiveSessionAndFailsClosed() throws {
        let pending: [String: Any] = [
            "connectionId": "host-instance:7",
            "remoteId": "123456789",
            "remoteName": "Remote Mac",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "requestedAt": 1_700_000_000_000 as UInt64,
            "expiresAt": 1_700_000_030_000 as UInt64,
            "requestedCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "transport": "unknown",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        ]
        let activeSession: [String: Any] = [
            "connectionId": "host-instance:9",
            "remoteId": "987654321",
            "remoteName": "Controlled Mac",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 1_700_000_000_500 as UInt64,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            ],
            "activeCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ]
        func document(
            pendingApproval: Any,
            activeSession: Any = NSNull()
        ) -> [String: Any] {
            [
                "schemaVersion": 5,
                "hostInstanceId": "host-instance",
                "hostState": "ready",
                "localId": "987654321",
                "registrationStatus": "ready",
                "pendingApproval": pendingApproval,
                "activeSession": activeSession,
                "temporaryPasswordPresentation": ["policy": "redacted"],
                "passwordPolicy": [
                    "localPasswordSet": false,
                    "effectivePasswordSet": false,
                    "usingPresetPassword": false,
                    "changeAllowed": true,
                    "strengthPolicy": [
                        "version": 1,
                        "minimumCharacters": 6,
                        "maximumCharacters": 128,
                        "maximumUtf8Bytes": 512,
                        "rejectsControlCharacters": true,
                        "rejectsOuterWhitespace": true,
                    ],
                ],
                "lastError": NSNull(),
                "observedAt": 1_700_000_001_000 as UInt64,
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: pending,
                activeSession: activeSession
            )
        )
        let snapshot = try HostCoreSnapshot(rawJSON: data)
        XCTAssertEqual(snapshot.schemaVersion, 5)
        XCTAssertEqual(snapshot.pendingApproval?.connectionId, "host-instance:7")
        XCTAssertEqual(snapshot.pendingApproval?.remoteName, "Remote Mac")
        XCTAssertEqual(
            snapshot.pendingApproval?.requestedCapabilities,
            ["viewDisplay", "controlKeyboardMouse"]
        )
        XCTAssertEqual(snapshot.activeSession?.connectionId, "host-instance:9")
        XCTAssertEqual(snapshot.activeSession?.remoteName, "Controlled Mac")
        XCTAssertEqual(
            snapshot.activeSession?.initialCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard"]
        )
        XCTAssertEqual(
            snapshot.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse"]
        )
        XCTAssertEqual(snapshot.activeSession?.inputAvailability, .available)
        XCTAssertNil(snapshot.activeSession?.inputUnavailableReason)

        let noPending = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: NSNull())
        ))
        XCTAssertNil(noPending.pendingApproval)
        XCTAssertNil(noPending.activeSession)

        var invalidPending = pending
        invalidPending["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["requestedCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["riskAlerts"] = ["futureRiskCode"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))

        var invalidSession = activeSession
        invalidSession["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "hearSystemAudio"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["connectionId"] = "other-host:9"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "readClipboard"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "available"
        invalidSession["inputUnavailableReason"] = NSNull()
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "sessionUnavailable"
        let limitedSnapshot = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        ))
        XCTAssertEqual(limitedSnapshot.activeSession?.inputAvailability, .limited)
        XCTAssertEqual(
            limitedSnapshot.activeSession?.inputUnavailableReason,
            .sessionUnavailable
        )
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "disabled"
        invalidSession["inputUnavailableReason"] = "accessibilityDenied"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "futureReason"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        var oldSchema = document(pendingApproval: NSNull())
        oldSchema["schemaVersion"] = 4
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: oldSchema
        )))
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
        let reconfigure = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "bitrate": 8_000_000,
        ])?.mediaControl)
        XCTAssertEqual(reconfigure.command, .reconfigure)
        XCTAssertEqual(reconfigure.codec, .h264)
        XCTAssertEqual(reconfigure.width, 1920)

        let h265Reconfigure = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 10,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "bitrate": 8_000_000,
        ])?.mediaControl)
        XCTAssertEqual(h265Reconfigure.codec, .h265)
        XCTAssertEqual(h265Reconfigure.codecEpoch, 10)

        let matchingStop = try XCTUnwrap(try hostEvent(payload: [
            "command": "stopCapture",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
        ])?.mediaControl)
        XCTAssertTrue(reconfigure.matchesRoute(matchingStop))

        let staleRefresh = try XCTUnwrap(try hostEvent(payload: [
            "command": "requestIdr",
            "connectionEpoch": 6,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
        ])?.mediaControl)
        XCTAssertFalse(reconfigure.matchesRoute(staleRefresh))

        XCTAssertNil(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 0,
        ])?.mediaControl)
        XCTAssertNil(try hostEvent(payload: [
            "command": "requestIdr",
            "connectionEpoch": 0,
            "codecEpoch": 9,
            "displayId": 0,
        ])?.mediaControl)
        XCTAssertNil(try hostEvent(payload: [:], schemaVersion: 2))
    }

    func testHostMediaDiagnosticIsSanitizedAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "firstPacketAcknowledged",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "framing": "avcc",
            "ptsUs": 42_999,
            "keyframe": true,
            "hasParameterSets": true,
            "subscriberCount": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)
        XCTAssertEqual(diagnostic.kind, .firstPacketAcknowledged)
        XCTAssertEqual(diagnostic.codec, .h264)
        XCTAssertEqual(diagnostic.framing, .avcc)
        XCTAssertEqual(diagnostic.presentationTimeUS, 42_999)
        XCTAssertTrue(diagnostic.isKeyframe)
        XCTAssertTrue(diagnostic.hasParameterSets)
        XCTAssertEqual(diagnostic.subscriberCount, 1)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))
        let staleRoute = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 8,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertFalse(diagnostic.matchesRoute(staleRoute))

        var invalid = payload
        invalid["subscriberCount"] = 0
        XCTAssertNil(try hostEvent(
            payload: invalid,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)
        invalid = payload
        invalid["framing"] = "unknown"
        XCTAssertNil(try hostEvent(
            payload: invalid,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("peerId"))
        XCTAssertFalse(text.contains("data"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("server"))
    }

    func testHostMediaQueueDiagnosticIsBoundedSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "currentDepth": 1,
            "maximumDepth": 3,
            "capacity": 3,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaQueueDiagnostic"
        )?.mediaQueueDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.currentDepth, 1)
        XCTAssertEqual(diagnostic.maximumDepth, 3)
        XCTAssertEqual(diagnostic.capacity, 3)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["currentDepth"] = 4 },
            { $0["maximumDepth"] = 4 },
            { $0["capacity"] = 0 },
            { $0["maximumDepth"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaQueueDiagnostic"
            )?.mediaQueueDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaWriterDiagnosticIsConsistentSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "cycles": 3,
            "subscriberDispatches": 5,
            "dispatchWallTotalUs": 120,
            "maximumDispatchWallUs": 70,
            "confirmationWaitTotalUs": 900,
            "maximumConfirmationWaitUs": 400,
            "completedConfirmations": 2,
            "timedOutConfirmations": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaWriterDiagnostic"
        )?.mediaWriterDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.cycles, 3)
        XCTAssertEqual(diagnostic.subscriberDispatches, 5)
        XCTAssertEqual(diagnostic.maximumDispatchWallUS, 70)
        XCTAssertEqual(diagnostic.maximumConfirmationWaitUS, 400)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["subscriberDispatches"] = 2 },
            { $0["maximumDispatchWallUs"] = 121 },
            { $0["maximumConfirmationWaitUs"] = 901 },
            { $0["completedConfirmations"] = 3 },
            { $0["cycles"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaWriterDiagnostic"
            )?.mediaWriterDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaNetworkDiagnosticPreservesUnavailableSamplesAndRouteScope() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "subscriberCount": 2,
            "qosSubscriberCount": 2,
            "delaySampledSubscribers": 2,
            "rttSampledSubscribers": 1,
            "responseDelayedSubscribers": 1,
            "worstNetworkDelayMs": 180,
            "worstRttMs": 42,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaNetworkDiagnostic"
        )?.mediaNetworkDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 2)
        XCTAssertEqual(diagnostic.qosSubscriberCount, 2)
        XCTAssertEqual(diagnostic.delaySampledSubscribers, 2)
        XCTAssertEqual(diagnostic.rttSampledSubscribers, 1)
        XCTAssertEqual(diagnostic.responseDelayedSubscribers, 1)
        XCTAssertEqual(diagnostic.worstNetworkDelayMS, 180)
        XCTAssertEqual(diagnostic.worstRTTMS, 42)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        var unsampled = payload
        unsampled["delaySampledSubscribers"] = 0
        unsampled["rttSampledSubscribers"] = 0
        unsampled["responseDelayedSubscribers"] = 0
        unsampled["worstNetworkDelayMs"] = NSNull()
        unsampled["worstRttMs"] = NSNull()
        let unavailable = try XCTUnwrap(try hostEvent(
            payload: unsampled,
            eventType: "mediaNetworkDiagnostic"
        )?.mediaNetworkDiagnostic)
        XCTAssertNil(unavailable.worstNetworkDelayMS)
        XCTAssertNil(unavailable.worstRTTMS)

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["qosSubscriberCount"] = 3 },
            { $0["delaySampledSubscribers"] = 3 },
            { $0["rttSampledSubscribers"] = 3 },
            { $0["responseDelayedSubscribers"] = 3 },
            { $0["worstNetworkDelayMs"] = NSNull() },
            { $0.removeValue(forKey: "worstRttMs") },
            { $0["worstRttMs"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaNetworkDiagnostic"
            )?.mediaNetworkDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaTransportDiagnosticPreservesUnknownAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "subscriberCount": 4,
            "directSubscribers": 2,
            "relaySubscribers": 1,
            "unknownSubscribers": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaTransportDiagnostic"
        )?.mediaTransportDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 4)
        XCTAssertEqual(diagnostic.directSubscribers, 2)
        XCTAssertEqual(diagnostic.relaySubscribers, 1)
        XCTAssertEqual(diagnostic.unknownSubscribers, 1)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["unknownSubscribers"] = 0 },
            { $0["directSubscribers"] = -1 },
            { $0["relaySubscribers"] = 1.5 },
            { $0.removeValue(forKey: "subscriberCount") },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaTransportDiagnostic"
            )?.mediaTransportDiagnostic)
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
            libraryURL: URL(fileURLWithPath: path),
            onState: { _ in },
            onVideo: { _ in },
            onMetrics: { _ in }
        )
        XCTAssertEqual(client.upstreamCommit, RustDeskCoreClient.expectedUpstreamCommit)
        client.disconnect()
    }
}
