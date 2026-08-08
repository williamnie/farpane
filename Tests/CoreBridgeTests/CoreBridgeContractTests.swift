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
        XCTAssertTrue(bridge.contains("const SNAPSHOT_SCHEMA_VERSION: u32 = 2;"))
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
