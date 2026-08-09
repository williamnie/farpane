@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCSnapshotClientTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testStrictlyHandshakesThenFetchesAndPublishesFirstSnapshot() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let resets = SnapshotClientTestRecorder<String>()
        let results = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let client = try makeClient(
            transport: transport,
            source: source,
            previousPeerIdentity: nil,
            onReset: { resets.append("reset") }
        )

        client.start { results.append($0) }

        XCTAssertEqual(client.stateSnapshot(), .handshaking)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.handshakeRequestCount, 1)
        XCTAssertEqual(transport.snapshotRequestCount, 0)
        let handshakeRequest = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(transport.lastHandshakeRequest)
        )
        XCTAssertNil(handshakeRequest.knownHostInstanceID)
        XCTAssertNil(handshakeRequest.knownAgentBootID)
        XCTAssertNil(handshakeRequest.knownAgentProcessID)
        XCTAssertNil(
            handshakeRequest.knownAgentProcessStartIdentitySHA256
        )
        transport.replyToHandshake(try handshakeResponse(
            for: handshakeRequest,
            hostID: hostID,
            bootID: bootID
        ))

        XCTAssertEqual(
            client.stateSnapshot(),
            .fetchingSnapshot(try peerIdentity())
        )
        XCTAssertEqual(transport.snapshotRequestCount, 1)
        let snapshotRequest = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        XCTAssertEqual(snapshotRequest.hostInstanceID, hostID)
        XCTAssertEqual(snapshotRequest.agentBootID, bootID)
        transport.replyToSnapshot(try snapshotResponse(
            for: snapshotRequest,
            hostID: hostID,
            bootID: bootID,
            eventSequence: 7
        ))

        XCTAssertEqual(resets.values, [])
        let completedResults = results.values
        XCTAssertEqual(completedResults.count, 1)
        guard case .ready(let snapshot, let peer, let transition) =
            completedResults[0]
        else { return XCTFail("expected ready") }
        XCTAssertEqual(peer, try peerIdentity())
        XCTAssertEqual(transition, .firstObservation)
        XCTAssertEqual(snapshot.lastEventID, 7)
        XCTAssertEqual(snapshot.snapshot.hostState, "ready")
        XCTAssertEqual(client.stateSnapshot(), .ready(peer, lastEventID: 7))
        XCTAssertEqual(transport.invalidateCount, 0)

        client.cancel()
        XCTAssertEqual(client.stateSnapshot(), .cancelled)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testEventFetchUsesSnapshotCursorAndAdvancesCorrelatedBatch() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let eventResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let duplicateResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)

        client.fetchEvents { eventResults.append($0) }
        client.fetchEvents { duplicateResults.append($0) }

        XCTAssertEqual(
            client.stateSnapshot(),
            .fetchingEvents(try peerIdentity(), afterEventID: 0)
        )
        XCTAssertEqual(transport.eventRequestCount, 1)
        XCTAssertEqual(duplicateResults.values, [.invalidState])
        let request = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        XCTAssertEqual(request.afterEventID, 0)
        XCTAssertEqual(
            request.maximumEventCount,
            HostAgentXPCWireEventContract.maximumEventCount
        )
        let response = try eventResponse(
            for: request,
            events: [try event(
                id: 41,
                type: "commandResult",
                payload: [
                    "commandId": "command-1",
                    "status": "ok",
                    "detail": "completed",
                ]
            )]
        )
        transport.replyToEvents(try response.encoded())

        XCTAssertEqual(eventResults.values, [.events(response)])
        XCTAssertEqual(
            client.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 1)
        )
        XCTAssertEqual(transport.snapshotRequestCount, 1)
        XCTAssertEqual(transport.invalidateCount, 0)
    }

    func testCommandQueuesThenCompletesFromCorrelatedEventWithoutBlockingPoll()
        throws
    {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let commandResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let duplicateResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let deliveryOrder = SnapshotClientTestRecorder<String>()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)

        client.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { result in
            commandResults.append(result)
            if case .completed = result { deliveryOrder.append("command") }
        }
        client.submitCommand(
            commandID: "command-2",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { duplicateResults.append($0) }

        XCTAssertEqual(
            client.stateSnapshot(),
            .submittingCommand(
                try peerIdentity(),
                lastEventID: 0,
                commandID: "command-1"
            )
        )
        XCTAssertEqual(transport.commandRequestCount, 1)
        XCTAssertEqual(duplicateResults.values, [.invalidState])
        let request = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(transport.lastCommandRequest)
        )
        XCTAssertEqual(request.commandID, "command-1")
        XCTAssertEqual(request.name, .disconnectSession)
        let accepted = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            sentAtUnixMilliseconds: 30
        )
        transport.replyToCommand(try accepted.encoded())

        XCTAssertEqual(commandResults.values, [.accepted(accepted)])
        XCTAssertEqual(
            client.commandStateSnapshot(),
            .awaitingResult(commandID: "command-1")
        )
        XCTAssertEqual(
            client.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 0)
        )

        client.fetchEvents { result in
            if case .events = result { deliveryOrder.append("events") }
        }
        let eventRequest = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        let response = try eventResponse(
            for: eventRequest,
            events: [try event(
                id: 1,
                type: "commandResult",
                payload: [
                    "commandId": "command-1",
                    "status": "ok",
                    "detail": "completed",
                ]
            )]
        )
        transport.replyToEvents(try response.encoded())

        XCTAssertEqual(deliveryOrder.values, ["events", "command"])
        XCTAssertEqual(commandResults.values, [
            .accepted(accepted),
            .completed(try HostAgentXPCWireCommandResult(
                commandID: "command-1",
                status: .ok,
                detail: "completed"
            )),
        ])
        XCTAssertEqual(client.commandStateSnapshot(), .idle)
        XCTAssertEqual(
            client.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 1)
        )
    }

    func testMalformedCommandAckFailsSessionAndLateAckCannotRevive() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport)
        client.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { results.append($0) }
        let request = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(transport.lastCommandRequest)
        )
        let late = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            sentAtUnixMilliseconds: 30
        )

        transport.replyToCommand(Data())
        transport.replyToCommand(try late.encoded())

        XCTAssertEqual(results.values, [.invalidResponse])
        XCTAssertEqual(client.stateSnapshot(), .failed)
        XCTAssertEqual(client.commandStateSnapshot(), .idle)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testCommandResultWaitsForAuthoritativeResnapshotDelivery() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let commandResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let eventResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let deliveryOrder = SnapshotClientTestRecorder<String>()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)
        client.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { result in
            commandResults.append(result)
            if case .completed = result { deliveryOrder.append("command") }
        }
        let commandRequest = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(transport.lastCommandRequest)
        )
        let accepted = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: commandRequest,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            sentAtUnixMilliseconds: 30
        )
        transport.replyToCommand(try accepted.encoded())

        client.fetchEvents { result in
            eventResults.append(result)
            if case .resynchronized = result {
                deliveryOrder.append("snapshot")
            }
        }
        let eventRequest = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        let triggering = try eventResponse(
            for: eventRequest,
            events: [
                try event(
                    id: 1,
                    type: "sessionCapabilitiesChanged",
                    payload: [:]
                ),
                try event(
                    id: 2,
                    type: "commandResult",
                    payload: [
                        "commandId": "command-1",
                        "status": "ok",
                        "detail": "completed",
                    ]
                ),
            ]
        )
        transport.replyToEvents(try triggering.encoded())
        XCTAssertEqual(commandResults.values, [.accepted(accepted)])
        XCTAssertEqual(
            client.stateSnapshot(),
            .refreshingSnapshot(try peerIdentity(), lastEventID: 0)
        )

        let refreshRequest = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        let refreshed = try HostAgentXPCWireSnapshotResponse.decode(
            snapshotResponse(
                for: refreshRequest,
                hostID: hostID,
                bootID: bootID,
                eventSequence: 2
            )
        )
        transport.replyToSnapshot(try refreshed.encoded())

        XCTAssertEqual(eventResults.values, [.resynchronized(
            snapshot: refreshed,
            triggeringResponse: triggering
        )])
        XCTAssertEqual(deliveryOrder.values, ["snapshot", "command"])
        XCTAssertEqual(commandResults.values.count, 2)
        XCTAssertEqual(client.commandStateSnapshot(), .idle)
    }

    func testCommandAcceptanceTimeoutIsTerminalButResultTimeoutIsRetryable()
        throws
    {
        let acceptanceTransport = SnapshotClientTestTransport()
        let acceptanceSource = SnapshotClientTestSource()
        let acceptanceResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let acceptanceClient = try makeClient(
            transport: acceptanceTransport,
            source: acceptanceSource
        )
        acceptanceClient.start { _ in }
        try completeReady(transport: acceptanceTransport)
        acceptanceClient.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { acceptanceResults.append($0) }
        acceptanceSource.fireLastTimeout()

        XCTAssertEqual(acceptanceResults.values, [.acceptanceTimedOut])
        XCTAssertEqual(acceptanceClient.stateSnapshot(), .failed)
        XCTAssertEqual(acceptanceTransport.invalidateCount, 1)

        let resultTransport = SnapshotClientTestTransport()
        let resultSource = SnapshotClientTestSource()
        let resultResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let resultClient = try makeClient(
            transport: resultTransport,
            source: resultSource
        )
        resultClient.start { _ in }
        try completeReady(transport: resultTransport)
        resultClient.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { resultResults.append($0) }
        let request = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(resultTransport.lastCommandRequest)
        )
        let accepted = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            sentAtUnixMilliseconds: 30
        )
        resultTransport.replyToCommand(try accepted.encoded())
        resultSource.fireLastTimeout()

        XCTAssertEqual(resultResults.values, [
            .accepted(accepted),
            .resultTimedOut,
        ])
        XCTAssertEqual(resultClient.commandStateSnapshot(), .idle)
        XCTAssertEqual(
            resultClient.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 1)
        )
        XCTAssertEqual(resultTransport.invalidateCount, 0)

        let retryResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        resultClient.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { retryResults.append($0) }
        let retry = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(resultTransport.lastCommandRequest)
        )
        XCTAssertEqual(retry.commandID, request.commandID)
        XCTAssertNotEqual(retry.requestID, request.requestID)
        XCTAssertEqual(resultTransport.commandRequestCount, 2)
        resultClient.cancel()
        XCTAssertEqual(retryResults.values, [.cancelled])
    }

    func testCommandCancellationAndDisconnectReportUnknownExactlyOnce()
        throws
    {
        let cancelTransport = SnapshotClientTestTransport()
        let cancelSource = SnapshotClientTestSource()
        let cancelResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let cancelClient = try makeClient(
            transport: cancelTransport,
            source: cancelSource
        )
        cancelClient.start { _ in }
        try completeReady(transport: cancelTransport)
        cancelClient.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { cancelResults.append($0) }
        cancelClient.cancel()
        cancelTransport.replyToCommand(Data())
        XCTAssertEqual(cancelResults.values, [.cancelled])

        let disconnectTransport = SnapshotClientTestTransport()
        let disconnectSource = SnapshotClientTestSource()
        let disconnectResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let disconnectClient = try makeClient(
            transport: disconnectTransport,
            source: disconnectSource
        )
        disconnectClient.start { _ in }
        try completeReady(transport: disconnectTransport)
        disconnectClient.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { disconnectResults.append($0) }
        let request = try HostAgentXPCWireCommandRequest.decode(
            XCTUnwrap(disconnectTransport.lastCommandRequest)
        )
        let accepted = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            sentAtUnixMilliseconds: 30
        )
        disconnectTransport.replyToCommand(try accepted.encoded())
        disconnectTransport.triggerInterruption()
        disconnectTransport.triggerInvalidation()

        XCTAssertEqual(disconnectResults.values, [
            .accepted(accepted),
            .resultUnknown,
        ])
        XCTAssertEqual(disconnectClient.stateSnapshot(), .disconnected)
    }

    func testGapAutomaticallyResnapshotsBeforeReturningToReady() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)
        client.fetchEvents { results.append($0) }
        let eventRequest = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        let gap = try eventResponse(
            for: eventRequest,
            events: [
                try event(id: 1, type: "sessionStarted", payload: [:]),
                try event(id: 2, type: "sessionEnded", payload: [:]),
                try event(id: 3, type: "permissionChanged", payload: [:]),
            ],
            capacity: 2
        )
        XCTAssertEqual(gap.outcome, .gap)

        transport.replyToEvents(try gap.encoded())

        XCTAssertEqual(results.values, [])
        XCTAssertEqual(
            client.stateSnapshot(),
            .refreshingSnapshot(try peerIdentity(), lastEventID: 0)
        )
        XCTAssertEqual(transport.snapshotRequestCount, 2)
        let refreshRequest = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        let refreshed = try HostAgentXPCWireSnapshotResponse.decode(
            snapshotResponse(
                for: refreshRequest,
                hostID: hostID,
                bootID: bootID,
                eventSequence: 3
            )
        )
        transport.replyToSnapshot(try refreshed.encoded())

        XCTAssertEqual(results.values, [.resynchronized(
            snapshot: refreshed,
            triggeringResponse: gap
        )])
        XCTAssertEqual(
            client.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 3)
        )
        XCTAssertEqual(transport.invalidateCount, 0)
    }

    func testSnapshotChangedBatchResnapshotsInsteadOfPublishingStaleState()
        throws
    {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)
        client.fetchEvents { results.append($0) }
        let eventRequest = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        let changed = try eventResponse(
            for: eventRequest,
            events: [try event(
                id: 1,
                type: "sessionCapabilitiesChanged",
                payload: [:]
            )]
        )

        transport.replyToEvents(try changed.encoded())

        XCTAssertEqual(results.values, [])
        XCTAssertEqual(transport.snapshotRequestCount, 2)
        let refreshRequest = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        let refreshed = try HostAgentXPCWireSnapshotResponse.decode(
            snapshotResponse(
                for: refreshRequest,
                hostID: hostID,
                bootID: bootID,
                eventSequence: 1
            )
        )
        transport.replyToSnapshot(try refreshed.encoded())

        XCTAssertEqual(results.values, [.resynchronized(
            snapshot: refreshed,
            triggeringResponse: changed
        )])
        XCTAssertEqual(
            client.stateSnapshot(),
            .ready(try peerIdentity(), lastEventID: 1)
        )
    }

    func testInvalidEventResponseFailsClosedAndLateReplyCannotRevive() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let client = try makeClient(transport: transport, source: source)
        client.start { _ in }
        try completeReady(transport: transport, eventSequence: 0)
        client.fetchEvents { results.append($0) }
        let request = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(transport.lastEventRequest)
        )
        let late = try eventResponse(for: request, events: [])

        transport.replyToEvents(Data())
        transport.replyToEvents(try late.encoded())

        XCTAssertEqual(results.values, [.invalidResponse])
        XCTAssertEqual(client.stateSnapshot(), .failed)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testEventTimeoutAndCancellationAreTerminalAndOneShot() throws {
        let timeoutTransport = SnapshotClientTestTransport()
        let timeoutSource = SnapshotClientTestSource()
        let timeoutResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let timeoutClient = try makeClient(
            transport: timeoutTransport,
            source: timeoutSource
        )
        timeoutClient.start { _ in }
        try completeReady(transport: timeoutTransport, eventSequence: 0)
        timeoutClient.fetchEvents { timeoutResults.append($0) }
        timeoutSource.fireLastTimeout()

        XCTAssertEqual(timeoutResults.values, [.timedOut])
        XCTAssertEqual(timeoutClient.stateSnapshot(), .failed)
        XCTAssertEqual(timeoutTransport.invalidateCount, 1)

        let cancelTransport = SnapshotClientTestTransport()
        let cancelSource = SnapshotClientTestSource()
        let cancelResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let cancelClient = try makeClient(
            transport: cancelTransport,
            source: cancelSource
        )
        cancelClient.start { _ in }
        try completeReady(transport: cancelTransport, eventSequence: 0)
        cancelClient.fetchEvents { cancelResults.append($0) }
        let request = try HostAgentXPCWireEventCursorRequest.decode(
            XCTUnwrap(cancelTransport.lastEventRequest)
        )
        let late = try eventResponse(for: request, events: [])

        cancelClient.cancel()
        cancelTransport.replyToEvents(try late.encoded())

        XCTAssertEqual(cancelResults.values, [.cancelled])
        XCTAssertEqual(cancelClient.stateSnapshot(), .cancelled)
        XCTAssertEqual(cancelTransport.invalidateCount, 1)
    }

    func testPreviousIdentityIsOfferedAndReplacementResetsBeforeDelivery() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let previous = try HostAgentXPCSnapshotClientPeerIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID,
            agentProcessID: 3_210,
            agentProcessStartIdentitySHA256:
                String(repeating: "b", count: 64)
        )
        let order = SnapshotClientTestRecorder<String>()
        let results = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let client = try makeClient(
            transport: transport,
            source: source,
            previousPeerIdentity: previous,
            onReset: { order.append("reset") }
        )
        client.start {
            order.append("ready")
            results.append($0)
        }
        let handshakeRequest = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(transport.lastHandshakeRequest)
        )
        XCTAssertEqual(handshakeRequest.knownHostInstanceID, hostID)
        XCTAssertEqual(
            handshakeRequest.knownAgentBootID,
            previous.agentBootID
        )
        XCTAssertEqual(
            handshakeRequest.knownAgentProcessID,
            previous.agentProcessID
        )
        XCTAssertEqual(
            handshakeRequest.knownAgentProcessStartIdentitySHA256,
            previous.agentProcessStartIdentitySHA256
        )
        transport.replyToHandshake(try handshakeResponse(
            for: handshakeRequest,
            hostID: hostID,
            bootID: bootID
        ))
        let snapshotRequest = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        transport.replyToSnapshot(try snapshotResponse(
            for: snapshotRequest,
            hostID: hostID,
            bootID: bootID,
            eventSequence: 1
        ))

        XCTAssertEqual(order.values, ["reset", "ready"])
        guard case .ready(_, _, .replacedPrevious)? = results.values.first
        else {
            return XCTFail("expected replaced identity")
        }
    }

    func testIncompatibleHandshakeStopsBeforeSnapshot() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let client = try makeClient(transport: transport, source: source)
        client.start { results.append($0) }
        let request = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(transport.lastHandshakeRequest)
        )
        transport.replyToHandshake(try handshakeResponse(
            for: request,
            hostID: hostID,
            bootID: bootID,
            agentVersions: [1]
        ))

        XCTAssertEqual(results.values, [.incompatible])
        XCTAssertEqual(client.stateSnapshot(), .incompatible)
        XCTAssertEqual(transport.snapshotRequestCount, 0)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testInvalidOrUncorrelatedRepliesFailClosed() throws {
        let malformedTransport = SnapshotClientTestTransport()
        let malformedSource = SnapshotClientTestSource()
        let malformedResults =
            SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let malformedClient = try makeClient(
            transport: malformedTransport,
            source: malformedSource
        )
        malformedClient.start { malformedResults.append($0) }
        malformedTransport.replyToHandshake(Data())
        XCTAssertEqual(malformedResults.values, [.invalidResponse])
        XCTAssertEqual(malformedClient.stateSnapshot(), .failed)
        XCTAssertEqual(malformedTransport.invalidateCount, 1)

        let mismatchTransport = SnapshotClientTestTransport()
        let mismatchSource = SnapshotClientTestSource()
        let mismatchResults =
            SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let mismatchClient = try makeClient(
            transport: mismatchTransport,
            source: mismatchSource
        )
        mismatchClient.start { mismatchResults.append($0) }
        let handshake = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(mismatchTransport.lastHandshakeRequest)
        )
        mismatchTransport.replyToHandshake(try handshakeResponse(
            for: handshake,
            hostID: hostID,
            bootID: bootID
        ))
        let snapshot = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(mismatchTransport.lastSnapshotRequest)
        )
        let differentRequest = try HostAgentXPCWireSnapshotRequest(
            requestID: "841733af-919b-4dc2-84bb-7134d0951dc9",
            wireVersion: snapshot.wireVersion,
            hostInstanceID: snapshot.hostInstanceID,
            agentBootID: snapshot.agentBootID,
            sentAtUnixMilliseconds: snapshot.sentAtUnixMilliseconds
        )
        mismatchTransport.replyToSnapshot(try snapshotResponse(
            for: differentRequest,
            hostID: hostID,
            bootID: bootID,
            eventSequence: 1
        ))
        XCTAssertEqual(mismatchResults.values, [.invalidResponse])
        XCTAssertEqual(mismatchClient.stateSnapshot(), .failed)
        XCTAssertEqual(mismatchTransport.invalidateCount, 1)
    }

    func testInterruptionCompletesOnceAndLateRepliesCannotReviveSession() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let results = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let client = try makeClient(transport: transport, source: source)
        client.start { results.append($0) }
        let request = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(transport.lastHandshakeRequest)
        )

        transport.triggerInterruption()
        transport.replyToHandshake(try handshakeResponse(
            for: request,
            hostID: hostID,
            bootID: bootID
        ))
        transport.triggerInvalidation()

        XCTAssertEqual(results.values, [.disconnected])
        XCTAssertEqual(client.stateSnapshot(), .disconnected)
        XCTAssertEqual(transport.snapshotRequestCount, 0)
    }

    func testCancelAndRepeatedStartAreTerminalAndReplyExactlyOnce() throws {
        let transport = SnapshotClientTestTransport()
        let source = SnapshotClientTestSource()
        let first = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let second = SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let client = try makeClient(transport: transport, source: source)

        client.start { first.append($0) }
        client.start { second.append($0) }
        client.cancel()
        client.cancel()

        XCTAssertEqual(second.values, [.invalidState])
        XCTAssertEqual(first.values, [.cancelled])
        XCTAssertEqual(client.stateSnapshot(), .cancelled)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testTimeoutAndReadyConnectionEndAreBoundedAndOneShot() throws {
        let timeoutTransport = SnapshotClientTestTransport()
        let timeoutSource = SnapshotClientTestSource()
        let timeoutResults =
            SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let timeoutClient = try makeClient(
            transport: timeoutTransport,
            source: timeoutSource
        )
        timeoutClient.start { timeoutResults.append($0) }
        let lateRequest = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(timeoutTransport.lastHandshakeRequest)
        )
        timeoutSource.fireNextTimeout()
        timeoutTransport.replyToHandshake(try handshakeResponse(
            for: lateRequest,
            hostID: hostID,
            bootID: bootID
        ))
        XCTAssertEqual(timeoutResults.values, [.timedOut])
        XCTAssertEqual(timeoutClient.stateSnapshot(), .failed)
        XCTAssertEqual(timeoutTransport.invalidateCount, 1)
        XCTAssertEqual(timeoutTransport.snapshotRequestCount, 0)

        let readyTransport = SnapshotClientTestTransport()
        let readySource = SnapshotClientTestSource()
        let readyResults =
            SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let ended = SnapshotClientTestRecorder<String>()
        let readyClient = try makeClient(
            transport: readyTransport,
            source: readySource,
            onConnectionEnded: { ended.append("ended") }
        )
        readyClient.start { readyResults.append($0) }
        try completeReady(transport: readyTransport)
        readyTransport.triggerInterruption()
        readyTransport.triggerInvalidation()
        XCTAssertEqual(readyResults.values.count, 1)
        XCTAssertEqual(ended.values, ["ended"])
        XCTAssertEqual(readyClient.stateSnapshot(), .disconnected)
    }

    func testConnectionTransportCompletesAnonymousXPCRoundTrip() throws {
        let snapshotState = HostAgentSnapshotState()
        _ = snapshotState.publish(
            try coreSnapshot(hostID: hostID),
            eventSequence: 0,
            expectedHostInstanceID: hostID
        )
        let eventState = try HostAgentEventState()
        let expectedHostID = hostID
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let commandService = HostAgentXPCCommandService(
            identity: identity,
            authority: try HostAgentXPCCommandAdmissionAuthority(
                identity: identity
            ),
            prepareExecution: { _ in
                HostAgentXPCCommandQueueTicket {}
            },
            publishResult: { result in
                switch eventState.ingestCommandResult(
                    result,
                    hostInstanceID: expectedHostID,
                    sentAtUnixMilliseconds: 1_700_000_000_000
                ) {
                case .accepted, .unchanged:
                    return true
                case .rejected:
                    return false
                }
            },
            nowUnixMilliseconds: { 20 }
        )
        let handler = HostAgentXPCSnapshotSessionHandler(
            identity: identity,
            snapshotState: snapshotState,
            eventState: eventState,
            commandService: commandService,
            nowUnixMilliseconds: { 20 },
            monotonicMilliseconds: { 1 }
        )
        let listener = NSXPCListener.anonymous()
        let delegate = SnapshotClientTestListenerDelegate(handler: handler)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let transport = HostAgentXPCSnapshotClientConnectionTransport(
            connection: connection
        )
        let source = SnapshotClientTestSource()
        let results =
            SnapshotClientTestRecorder<HostAgentXPCSnapshotClientResult>()
        let completed = expectation(description: "snapshot client ready")
        let client = try makeClient(transport: transport, source: source)
        defer { client.cancel() }

        client.start {
            results.append($0)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        guard case .ready(let snapshot, let peer, .firstObservation)? =
            results.values.first
        else { return XCTFail("expected ready XPC snapshot") }
        XCTAssertEqual(snapshot.lastEventID, 0)
        XCTAssertEqual(snapshot.snapshot.hostState, "ready")
        XCTAssertEqual(peer, try peerIdentity())
        XCTAssertEqual(client.stateSnapshot(), .ready(peer, lastEventID: 0))

        let commandAccepted = expectation(description: "command accepted")
        let commandCompleted = expectation(description: "command completed")
        let commandResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        client.submitCommand(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        ) { result in
            commandResults.append(result)
            switch result {
            case .accepted:
                commandAccepted.fulfill()
            case .completed:
                commandCompleted.fulfill()
            default:
                break
            }
        }
        wait(for: [commandAccepted], timeout: 2)
        XCTAssertEqual(
            commandService.acceptResult(try HostAgentXPCWireCommandResult(
                commandID: "command-1",
                status: .ok,
                detail: "completed"
            )),
            .published
        )

        let eventCompleted = expectation(description: "event client ready")
        let eventResults = SnapshotClientTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        client.fetchEvents {
            eventResults.append($0)
            eventCompleted.fulfill()
        }
        wait(for: [eventCompleted, commandCompleted], timeout: 2)
        guard case .events(let eventResponse)? = eventResults.values.first
        else { return XCTFail("expected event batch") }
        XCTAssertEqual(eventResponse.outcome, .batch)
        XCTAssertEqual(eventResponse.resumeAfterEventID, 1)
        XCTAssertEqual(commandResults.values.count, 2)
        XCTAssertEqual(client.stateSnapshot(), .ready(peer, lastEventID: 1))
    }

    func testProductFactorySourceFixesMachServiceAndUsesTypedCommand() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCSnapshotClient.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentRegistrationBundlePreflight.inspectMainBundle()"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentXPCListenerFactory.machServiceName"
        ))
        XCTAssertTrue(source.contains("let connection = NSXPCConnection("))
        XCTAssertTrue(source.contains(
            "HostAgentXPCSnapshotInterfaceFactory.makeInterface()"
        ))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("getenv"))
        XCTAssertTrue(source.contains("HostAgentXPCWireEvent"))
        XCTAssertTrue(source.contains("HostAgentXPCWireCommand"))
        XCTAssertFalse(source.contains("NSURL"))
    }

    private func makeClient(
        transport: HostAgentXPCSnapshotClientTransport,
        source: SnapshotClientTestSource,
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity? = nil,
        onReset: @escaping @Sendable () -> Void = {},
        onConnectionEnded: @escaping @Sendable () -> Void = {}
    ) throws -> HostAgentXPCSnapshotClient {
        try HostAgentXPCSnapshotClient(
            appBuildID: "app-build",
            previousPeerIdentity: previousPeerIdentity,
            transport: transport,
            makeRequestID: { source.nextRequestID() },
            nowUnixMilliseconds: { source.now() },
            scheduleTimeout: { milliseconds, action in
                source.scheduleTimeout(
                    milliseconds: milliseconds,
                    action: action
                )
            },
            onIdentityReplacementRequired: onReset,
            onConnectionEnded: onConnectionEnded
        )
    }

    private func completeReady(
        transport: SnapshotClientTestTransport,
        eventSequence: UInt64 = 1
    ) throws {
        let handshake = try HostAgentXPCWireHandshakeRequest.decode(
            XCTUnwrap(transport.lastHandshakeRequest)
        )
        transport.replyToHandshake(try handshakeResponse(
            for: handshake,
            hostID: hostID,
            bootID: bootID
        ))
        let snapshot = try HostAgentXPCWireSnapshotRequest.decode(
            XCTUnwrap(transport.lastSnapshotRequest)
        )
        transport.replyToSnapshot(try snapshotResponse(
            for: snapshot,
            hostID: hostID,
            bootID: bootID,
            eventSequence: eventSequence
        ))
    }

    private func peerIdentity() throws
        -> HostAgentXPCSnapshotClientPeerIdentity
    {
        try HostAgentXPCSnapshotClientPeerIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func handshakeResponse(
        for request: HostAgentXPCWireHandshakeRequest,
        hostID: String,
        bootID: String,
        agentVersions: [UInt64] = [2]
    ) throws -> Data {
        let response = try HostAgentXPCWireHandshakeResponse.decode(
            JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "messageType": "handshakeResponse",
                "requestId": request.requestID,
                "supportedWireVersions": agentVersions,
                "selectedWireVersion": agentVersions.contains(2)
                    && request.supportedWireVersions.contains(2) ? 2 : NSNull(),
                "compatibility": agentVersions.contains(2)
                    && request.supportedWireVersions.contains(2)
                    ? "compatible" : "incompatible",
                "agentBuildId": "agent-build",
                "hostInstanceId": hostID,
                "agentBootId": bootID,
                "agentProcessId": 4_321,
                "agentProcessStartIdentitySHA256":
                    String(repeating: "a", count: 64),
                "sentAtUnixMilliseconds": 20,
            ])
        )
        return try response.encoded()
    }

    private func snapshotResponse(
        for request: HostAgentXPCWireSnapshotRequest,
        hostID: String,
        bootID: String,
        eventSequence: UInt64
    ) throws -> Data {
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(hostID: hostID),
            eventSequence: eventSequence,
            expectedHostInstanceID: hostID
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: identity,
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        ).encoded()
    }

    private func eventResponse(
        for request: HostAgentXPCWireEventCursorRequest,
        events: [HostCoreEvent],
        capacity: Int = HostAgentEventState.productCapacity
    ) throws -> HostAgentXPCWireEventCursorResponse {
        let state = try HostAgentEventState(capacity: capacity)
        for event in events {
            switch HostAgentCoreCommandResultDecoder.decode(
                event,
                expectedHostInstanceID: hostID
            ) {
            case .decoded(let result):
                _ = state.ingestCommandResult(
                    result,
                    hostInstanceID: hostID,
                    sentAtUnixMilliseconds: event.sentAt
                )
            case .notCommandResult:
                _ = state.ingest(event)
            case .malformed, .foreignIdentity:
                XCTFail("invalid fixture event")
            }
        }
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            replay: state.replay(
                afterSequence: request.afterEventID,
                limit: request.maximumEventCount
            ),
            sentAtUnixMilliseconds: 22
        )
    }

    private func event(
        id: UInt64,
        type: String,
        payload: [String: Any]
    ) throws -> HostCoreEvent {
        try XCTUnwrap(HostCoreEvent(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "eventId": id,
                "eventType": type,
                "hostInstanceId": hostID,
                "sentAt": 1_700_000_000_000 as UInt64,
                "payload": payload,
            ]
        )))
    }

    private func coreSnapshot(hostID: String) throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "hostInstanceId": hostID,
                "hostState": "ready",
                "localId": "123456789",
                "authenticatedConnectionCount": 1,
                "sessionAvailability": "available",
                "sessionUnavailableReason": NSNull(),
                "registrationStatus": "ready",
                "recoveryEpoch": 0,
                "recoveryStatus": "running",
                "pendingApproval": NSNull(),
                "activeSession": NSNull(),
                "temporaryPasswordPresentation": ["policy": "redacted"],
                "passwordPolicy": [
                    "localPasswordSet": true,
                    "effectivePasswordSet": true,
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
                "observedAt": 15,
            ]
        ))
    }
}

private final class SnapshotClientTestListenerDelegate:
    NSObject,
    NSXPCListenerDelegate
{
    private let handler: HostAgentXPCSnapshotSessionHandler

    init(handler: HostAgentXPCSnapshotSessionHandler) {
        self.handler = handler
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface =
            HostAgentXPCSnapshotInterfaceFactory.makeInterface()
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}

private final class SnapshotClientTestSource: @unchecked Sendable {
    private let lock = NSLock()
    private var requestIDs = [
        "287fd5f2-98b7-4183-ac81-6973cef9a610",
        "151db9a9-7dd3-4fea-93af-1b6c10840676",
        "841733af-919b-4dc2-84bb-7134d0951dc9",
        "f3b55fb3-bc9f-443a-9a73-7769eb35875d",
        "f71830c9-4d88-4743-9780-fec7858191f1",
        "e16c8797-ac9a-40ac-87a9-6a4509bde67e",
    ]
    private var times: [UInt64] = [10, 11, 12, 13, 14, 15]
    private var scheduledTimeouts: [@Sendable () -> Void] = []

    func nextRequestID() -> String {
        lock.lock()
        defer { lock.unlock() }
        return requestIDs.removeFirst()
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return times.removeFirst()
    }

    func scheduleTimeout(
        milliseconds: UInt64,
        action: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        scheduledTimeouts.append(action)
        lock.unlock()
    }

    func fireNextTimeout() {
        lock.lock()
        let timeout = scheduledTimeouts.removeFirst()
        lock.unlock()
        timeout()
    }

    func fireLastTimeout() {
        lock.lock()
        let timeout = scheduledTimeouts.removeLast()
        lock.unlock()
        timeout()
    }
}

private final class SnapshotClientTestTransport:
    HostAgentXPCSnapshotClientTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var interruption: (@Sendable () -> Void)?
    private var invalidation: (@Sendable () -> Void)?
    private var handshakeReply: (@Sendable (Data?) -> Void)?
    private var snapshotReply: (@Sendable (Data?) -> Void)?
    private var eventReply: (@Sendable (Data?) -> Void)?
    private var commandReply: (@Sendable (Data?) -> Void)?
    private var starts = 0
    private var invalidations = 0
    private var handshakeRequests: [Data] = []
    private var snapshotRequests: [Data] = []
    private var eventRequests: [Data] = []
    private var commandRequests: [Data] = []

    var startCount: Int { locked { starts } }
    var invalidateCount: Int { locked { invalidations } }
    var handshakeRequestCount: Int { locked { handshakeRequests.count } }
    var snapshotRequestCount: Int { locked { snapshotRequests.count } }
    var eventRequestCount: Int { locked { eventRequests.count } }
    var commandRequestCount: Int { locked { commandRequests.count } }
    var lastHandshakeRequest: Data? { locked { handshakeRequests.last } }
    var lastSnapshotRequest: Data? { locked { snapshotRequests.last } }
    var lastEventRequest: Data? { locked { eventRequests.last } }
    var lastCommandRequest: Data? { locked { commandRequests.last } }

    func start(
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        starts += 1
        interruption = onInterruption
        invalidation = onInvalidation
        lock.unlock()
    }

    func performHandshake(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        lock.lock()
        handshakeRequests.append(requestData)
        handshakeReply = reply
        lock.unlock()
    }

    func fetchSnapshot(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        lock.lock()
        snapshotRequests.append(requestData)
        snapshotReply = reply
        lock.unlock()
    }

    func fetchEvents(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        lock.lock()
        eventRequests.append(requestData)
        eventReply = reply
        lock.unlock()
    }

    func submitCommand(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        lock.lock()
        commandRequests.append(requestData)
        commandReply = reply
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }

    func replyToHandshake(_ data: Data?) {
        locked { handshakeReply }?(data)
    }

    func replyToSnapshot(_ data: Data?) {
        locked { snapshotReply }?(data)
    }

    func replyToEvents(_ data: Data?) {
        locked { eventReply }?(data)
    }

    func replyToCommand(_ data: Data?) {
        locked { commandReply }?(data)
    }

    func triggerInterruption() {
        locked { interruption }?()
    }

    func triggerInvalidation() {
        locked { invalidation }?()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SnapshotClientTestRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
