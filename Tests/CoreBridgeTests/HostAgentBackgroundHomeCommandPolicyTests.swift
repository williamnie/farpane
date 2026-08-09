@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHomeCommandPolicyTests: XCTestCase {
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testIdleCoherentRouteExposesSixExactActionsAndFreshIDs()
        throws
    {
        let fixture = try commandFixture(
            activeCapabilities: [
                "viewDisplay", "controlKeyboardMouse",
                "readClipboard", "writeClipboard", "hearSystemAudio",
            ]
        )
        let presentation = present(
            fixture,
            state: .idle
        )

        XCTAssertEqual(presentation.route, fixture.route)
        XCTAssertEqual(
            presentation.availableActions,
            [
                .approveIncoming,
                .rejectIncoming,
                .disableKeyboardAndMouse,
                .disableClipboard,
                .disableSystemAudio,
                .disconnect,
            ]
        )
        XCTAssertFalse(presentation.isBusy)
        XCTAssertFalse(presentation.canRetry)

        let first = try XCTUnwrap(
            HostAgentBackgroundHomeCommandPolicy.productSubmission(
                action: .approveIncoming,
                presentation: presentation
            )
        )
        let second = try XCTUnwrap(
            HostAgentBackgroundHomeCommandPolicy.productSubmission(
                action: .approveIncoming,
                presentation: presentation
            )
        )
        XCTAssertNotEqual(first.intent.commandID, second.intent.commandID)
        XCTAssertTrue(HostAgentXPCWireHandshakeContract.validCanonicalUUID(
            first.intent.commandID
        ))
        XCTAssertTrue(HostAgentXPCWireHandshakeContract.validCanonicalUUID(
            second.intent.commandID
        ))
        XCTAssertEqual(first.route, fixture.route)
        XCTAssertEqual(first.intent.name, .approveIncoming)
        XCTAssertEqual(first.intent.connectionID, "host-a:pending-1")

        let clipboard = try XCTUnwrap(
            HostAgentBackgroundHomeCommandPolicy.submission(
                action: .disableClipboard,
                presentation: presentation,
                makeCommandID: { "command-clipboard" }
            )
        )
        XCTAssertEqual(
            clipboard.intent,
            HostAgentXPCCommandIntent(
                commandID: "command-clipboard",
                name: .disableClipboardForActiveSession,
                connectionID: "host-a:session-1"
            )
        )
    }

    func testCapabilitiesAndEveryRouteEpochFailClosed() throws {
        let fixture = try commandFixture(
            activeCapabilities: ["viewDisplay"]
        )
        let idle = present(fixture, state: .idle)
        XCTAssertEqual(
            idle.availableActions,
            [.approveIncoming, .rejectIncoming, .disconnect]
        )
        var generatorCalls = 0
        XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.submission(
            action: .disableClipboard,
            presentation: idle,
            makeCommandID: {
                generatorCalls += 1
                return "must-not-be-created"
            }
        ))
        XCTAssertEqual(generatorCalls, 0)
        XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.submission(
            action: .disconnect,
            presentation: idle,
            makeCommandID: { "contains spaces" }
        ))

        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.presentation(
                phase: .idle,
                projection: fixture.projection,
                availability: .available(
                    route: fixture.route,
                    state: .idle
                )
            ),
            .unavailable
        )
        let waitingAuthority = HostAgentBackgroundProjectionAuthority()
        _ = waitingAuthority.beginSession()
        let waitingProjection = waitingAuthority.snapshot()
        let incoherentHealth = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        incoherentHealth.acceptProjection(waitingProjection)
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.presentation(
                phase: .monitoring(
                    epoch: fixture.route.activationEpoch,
                    readiness: incoherentHealth.snapshot()
                ),
                projection: fixture.projection,
                availability: .available(
                    route: fixture.route,
                    state: .idle
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            present(
                fixture,
                route: HostAgentBackgroundCommandRoute(
                    activationEpoch: fixture.route.activationEpoch + 1,
                    projectionGeneration:
                        fixture.route.projectionGeneration,
                    reconnectRoute: fixture.route.reconnectRoute
                ),
                state: .idle
            ),
            .unavailable
        )
        XCTAssertEqual(
            present(
                fixture,
                route: HostAgentBackgroundCommandRoute(
                    activationEpoch: fixture.route.activationEpoch,
                    projectionGeneration:
                        fixture.route.projectionGeneration + 1,
                    reconnectRoute: fixture.route.reconnectRoute
                ),
                state: .idle
            ),
            .unavailable
        )
        let foreignPeer = try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: "host-b",
            agentBootID: "287fd5f2-98b7-4183-ac81-6973cef9a610"
        )
        XCTAssertEqual(
            present(
                fixture,
                route: HostAgentBackgroundCommandRoute(
                    activationEpoch: fixture.route.activationEpoch,
                    projectionGeneration:
                        fixture.route.projectionGeneration,
                    reconnectRoute: HostAgentXPCReconnectCommandRoute(
                        sessionGeneration: 7,
                        peerIdentity: foreignPeer
                    )
                ),
                state: .idle
            ),
            .unavailable
        )
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.presentation(
                phase: fixture.phase,
                projection: fixture.projection,
                availability: .unavailable
            ),
            .unavailable
        )
        XCTAssertEqual(
            present(fixture, state: .invalidated),
            .unavailable
        )
        XCTAssertEqual(
            present(fixture, state: .cancelled),
            .unavailable
        )

        let wrongTarget = HostAgentXPCCommandIntent(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:session-2"
        )
        XCTAssertEqual(
            present(fixture, state: .awaitingResult(wrongTarget)),
            .unavailable
        )
        let invalidID = HostAgentXPCCommandIntent(
            commandID: "bad command id",
            name: .disconnectSession,
            connectionID: "host-a:session-1"
        )
        XCTAssertEqual(
            present(fixture, state: .retryable(invalidID)),
            .unavailable
        )
    }

    func testLimitedSessionWithdrawsNewControlAndKeepsExactDisconnect()
        throws
    {
        let fixture = try commandFixture(
            activeCapabilities: [
                "viewDisplay", "controlKeyboardMouse",
                "readClipboard", "writeClipboard", "hearSystemAudio",
            ],
            limitedSession: true
        )
        let idle = present(fixture, state: .idle)

        XCTAssertEqual(idle.availableActions, [.disconnect])
        XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.submission(
            action: .approveIncoming,
            presentation: idle,
            makeCommandID: { "must-not-be-created" }
        ))
        XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.submission(
            action: .disableKeyboardAndMouse,
            presentation: idle,
            makeCommandID: { "must-not-be-created" }
        ))
        let disconnect = try XCTUnwrap(
            HostAgentBackgroundHomeCommandPolicy.submission(
                action: .disconnect,
                presentation: idle,
                makeCommandID: { "command-disconnect" }
            )
        )
        XCTAssertEqual(disconnect.intent.name, .disconnectSession)
        XCTAssertEqual(disconnect.intent.connectionID, "host-a:session-1")
        let retainedDisconnect = present(
            fixture,
            state: .retryable(disconnect.intent)
        )
        XCTAssertTrue(retainedDisconnect.canRetry)
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.retryRoute(
                presentation: retainedDisconnect
            ),
            fixture.route
        )

        let retainedApproval = HostAgentXPCCommandIntent(
            commandID: "command-approval",
            name: .approveIncoming,
            connectionID: "host-a:pending-1"
        )
        XCTAssertEqual(
            present(fixture, state: .retryable(retainedApproval)),
            .unavailable
        )
    }

    func testInflightQueuedAndRetryablePresentWithoutNewActions()
        throws
    {
        let fixture = try commandFixture(
            activeCapabilities: ["viewDisplay", "controlKeyboardMouse"]
        )
        let intent = HostAgentXPCCommandIntent(
            commandID: "command-1",
            name: .disableInputForActiveSession,
            connectionID: "host-a:session-1"
        )

        for state in [
            HostAgentXPCCommandIntentOwnerState.pausing(intent),
            .awaitingAcceptance(intent),
        ] {
            let view = present(fixture, state: state)
            XCTAssertEqual(view.activeAction, .disableKeyboardAndMouse)
            XCTAssertTrue(view.isBusy)
            XCTAssertFalse(view.canRetry)
            XCTAssertEqual(view.availableActions, [])
            XCTAssertEqual(view.statusText, "正在提交停止键鼠控制…")
            XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.retryRoute(
                presentation: view
            ))
        }

        let queued = present(
            fixture,
            state: .awaitingResult(intent)
        )
        XCTAssertTrue(queued.isBusy)
        XCTAssertEqual(
            queued.statusText,
            "停止键鼠控制已排队，等待后台确认…"
        )

        let retryable = present(
            fixture,
            state: .retryable(intent)
        )
        XCTAssertFalse(retryable.isBusy)
        XCTAssertTrue(retryable.canRetry)
        XCTAssertEqual(retryable.activeAction, .disableKeyboardAndMouse)
        XCTAssertEqual(retryable.availableActions, [])
        XCTAssertEqual(
            retryable.errorText,
            "无法确认停止键鼠控制结果；可重试同一操作。"
        )
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.retryRoute(
                presentation: retryable
            ),
            fixture.route
        )
        var generatorCalls = 0
        XCTAssertNil(HostAgentBackgroundHomeCommandPolicy.submission(
            action: .disconnect,
            presentation: retryable,
            makeCommandID: {
                generatorCalls += 1
                return "replacement-command"
            }
        ))
        XCTAssertEqual(generatorCalls, 0)
    }

    func testResultPresentationIsCorrelatedBoundedAndRetryAware()
        throws
    {
        let fixture = try commandFixture(
            activeCapabilities: ["viewDisplay", "controlKeyboardMouse"]
        )
        let submission = try XCTUnwrap(
            HostAgentBackgroundHomeCommandPolicy.submission(
                action: .approveIncoming,
                presentation: present(fixture, state: .idle),
                makeCommandID: { "command-1" }
            )
        )
        let intent = submission.intent
        let accepted = try acceptedResponse(for: intent)
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                .accepted(accepted),
                submission: submission
            ),
            HostAgentBackgroundHomeCommandResultPresentation(
                action: .approveIncoming,
                statusText: "允许连接已排队，等待后台确认…",
                errorText: "",
                tone: .neutral,
                isTerminal: false,
                canRetry: false
            )
        )

        let details = "sensitive-marker-must-not-be-presented"
        for (status, expectedTone) in [
            (HostAgentXPCWireCommandResultStatus.ok,
             HostAgentBackgroundHomeCommandTone.success),
            (.rejected, .warning),
            (.error, .error),
            (.unknownCommand, .error),
        ] {
            let result = try HostAgentXPCWireCommandResult(
                commandID: intent.commandID,
                status: status,
                detail: details
            )
            let view = try XCTUnwrap(
                HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                    .completed(result),
                    submission: submission
                )
            )
            XCTAssertTrue(view.isTerminal)
            XCTAssertFalse(view.canRetry)
            XCTAssertEqual(view.tone, expectedTone)
            XCTAssertFalse(view.statusText.contains(details))
            XCTAssertFalse(view.errorText.contains(details))
        }

        for outcome in [
            HostAgentXPCSnapshotClientCommandResult.resultUnknown,
            .resultTimedOut,
        ] {
            let view = try XCTUnwrap(
                HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                    outcome,
                    submission: submission
                )
            )
            XCTAssertTrue(view.isTerminal)
            XCTAssertTrue(view.canRetry)
            XCTAssertEqual(view.tone, .warning)
        }
        for outcome in [
            HostAgentXPCSnapshotClientCommandResult.invalidRequest,
            .invalidResponse,
            .disconnected,
            .acceptanceTimedOut,
            .cancelled,
            .invalidState,
        ] {
            let view = try XCTUnwrap(
                HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                    outcome,
                    submission: submission
                )
            )
            XCTAssertTrue(view.isTerminal)
            XCTAssertFalse(view.canRetry)
            XCTAssertFalse(view.errorText.isEmpty)
        }

        let mismatched = try HostAgentXPCWireCommandResult(
            commandID: "command-2",
            status: .ok,
            detail: "ok"
        )
        XCTAssertNil(
            HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                .completed(mismatched),
                submission: submission
            )
        )
        let foreignIntent = HostAgentXPCCommandIntent(
            commandID: intent.commandID,
            name: .approveIncoming,
            connectionID: "host-b:pending-1"
        )
        let foreignAccepted = try acceptedResponse(
            for: foreignIntent,
            hostInstanceID: "host-b",
            agentBootID: "287fd5f2-98b7-4183-ac81-6973cef9a610"
        )
        XCTAssertNil(
            HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                .accepted(foreignAccepted),
                submission: submission
            )
        )
    }

    func testPolicyRemainsPureAndProductHomeStillHasNoRouteConsumer()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let policySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundHomeCommandPolicy.swift"
            ),
            encoding: .utf8
        )
        for forbidden in [
            "import AppKit", "import SwiftUI", "HostControlClient",
            "UserDefaults", "SMAppService", ".submitCommand(",
            ".retryCommand(",
        ] {
            XCTAssertFalse(policySource.contains(forbidden), forbidden)
        }
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HomeView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(appSource.contains(
            "HostAgentBackgroundHomeCommandPolicy"
        ))
        XCTAssertFalse(appSource.contains("HostAgentBackgroundCommandRoute"))
        XCTAssertFalse(homeSource.contains(
            "HostAgentBackgroundHomeCommandAction"
        ))
    }

    private func present(
        _ fixture: CommandFixture,
        route: HostAgentBackgroundCommandRoute? = nil,
        state: HostAgentXPCCommandIntentOwnerState
    ) -> HostAgentBackgroundHomeCommandPresentation {
        HostAgentBackgroundHomeCommandPolicy.presentation(
            phase: fixture.phase,
            projection: fixture.projection,
            availability: .available(
                route: route ?? fixture.route,
                state: state
            )
        )
    }

    private func commandFixture(
        activeCapabilities: [String],
        limitedSession: Bool = false
    ) throws -> CommandFixture {
        let projectionAuthority = HostAgentBackgroundProjectionAuthority()
        let binding = projectionAuthority.beginSession()
        let peer = try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
        binding.sink.publishInitialSnapshot(
            try commandSnapshot(
                activeCapabilities: activeCapabilities,
                limitedSession: limitedSession
            ),
            peerIdentity: peer,
            transition: .firstObservation
        )
        let projection = projectionAuthority.snapshot()
        let healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        healthAuthority.acceptProjection(projection)
        let epoch: UInt64 = 9
        return CommandFixture(
            phase: .monitoring(
                epoch: epoch,
                readiness: healthAuthority.snapshot()
            ),
            projection: projection,
            route: HostAgentBackgroundCommandRoute(
                activationEpoch: epoch,
                projectionGeneration: projection.generation,
                reconnectRoute: HostAgentXPCReconnectCommandRoute(
                    sessionGeneration: 7,
                    peerIdentity: peer
                )
            )
        )
    }

    private func commandSnapshot(
        activeCapabilities: [String],
        limitedSession: Bool
    ) throws -> HostAgentXPCWireSnapshotResponse {
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let pending: [String: Any] = [
            "connectionId": "host-a:pending-1",
            "remoteId": "remote-1",
            "remoteName": "Mini",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "requestedAt": 40,
            "expiresAt": 80,
            "requestedCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "transport": "relay",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        ]
        let controlsKeyboardAndMouse = activeCapabilities.contains(
            "controlKeyboardMouse"
        )
        let inputUnavailableReason: Any = controlsKeyboardAndMouse
            ? NSNull()
            : "remoteDisabled"
        let active: [String: Any] = [
            "connectionId": "host-a:session-1",
            "remoteId": "remote-2",
            "remoteName": "MBP",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 30,
            "initialCapabilities": activeCapabilities,
            "activeCapabilities": activeCapabilities,
            "inputAvailability": controlsKeyboardAndMouse
                ? "available"
                : "disabled",
            "inputUnavailableReason": inputUnavailableReason,
        ]
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 7,
                    "hostInstanceId": "host-a",
                    "hostState": "ready",
                    "localId": "123456789",
                    "sessionAvailability": limitedSession
                        ? "limited"
                        : "available",
                    "sessionUnavailableReason": limitedSession
                        ? "sessionUnavailable"
                        : NSNull(),
                    "registrationStatus": "ready",
                    "recoveryEpoch": 0,
                    "recoveryStatus": "running",
                    "pendingApproval": pending,
                    "activeSession": active,
                    "temporaryPasswordPresentation": [
                        "policy": "redacted",
                    ],
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
                    "observedAt": 10,
                ]
            )),
            eventSequence: 1,
            expectedHostInstanceID: "host-a"
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: HostAgentXPCWireAgentIdentity(
                agentBuildID: "agent-build",
                hostInstanceID: "host-a",
                agentBootID: bootID
            ),
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        )
    }

    private func acceptedResponse(
        for intent: HostAgentXPCCommandIntent,
        hostInstanceID: String = "host-a",
        agentBootID: String? = nil
    ) throws -> HostAgentXPCWireCommandAcceptedResponse {
        let agentBootID = agentBootID ?? bootID
        let request = try HostAgentXPCWireCommandRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            commandID: intent.commandID,
            wireVersion: 1,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            name: intent.name,
            connectionID: intent.connectionID,
            sentAtUnixMilliseconds: 30
        )
        return try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity(
                agentBuildID: "agent-build",
                hostInstanceID: hostInstanceID,
                agentBootID: agentBootID
            ),
            sentAtUnixMilliseconds: 31
        )
    }
}

private struct CommandFixture {
    let phase: HostAgentBackgroundActivationPhase
    let projection: HostAgentBackgroundProjectionView
    let route: HostAgentBackgroundCommandRoute
}
