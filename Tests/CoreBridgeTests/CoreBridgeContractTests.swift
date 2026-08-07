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
