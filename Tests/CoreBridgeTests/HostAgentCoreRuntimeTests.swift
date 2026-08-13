import CoreBridge
import Foundation
import XCTest

final class HostAgentCoreRuntimeTests: XCTestCase {
    func testConfigRootPrecedesStartAndExplicitStopIsIdempotent() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )

        XCTAssertEqual(client.operations, [
            .setConfigRoot("FarPaneHost", "io.rustdesknative"),
            .start("one.example.invalid:21116", "", "public-key"),
        ])
        try runtime.stop(reason: .userRequest)
        try runtime.stop(reason: .error)
        XCTAssertEqual(client.operations, [
            .setConfigRoot("FarPaneHost", "io.rustdesknative"),
            .start("one.example.invalid:21116", "", "public-key"),
            .stop(.userRequest),
        ])
    }

    func testConfigRootFailureNeverCallsStartOrStop() {
        let client = RecordingHostAgentCoreClient(failure: .configRoot)

        XCTAssertThrowsError(
            try HostAgentCoreRuntime.start(
                client: client,
                configAppName: "FarPaneHost",
                configOrganization: "io.rustdesknative",
                serverConfiguration: serverConfiguration()
            )
        ) { error in
            XCTAssertEqual(error as? TestFailure, .configRoot)
        }
        XCTAssertEqual(client.operations, [
            .setConfigRoot("FarPaneHost", "io.rustdesknative"),
        ])
    }

    func testStartFailureDoesNotConstructRuntimeOrIssueSpeculativeStop() {
        let client = RecordingHostAgentCoreClient(failure: .start)

        XCTAssertThrowsError(
            try HostAgentCoreRuntime.start(
                client: client,
                configAppName: "FarPaneHost",
                configOrganization: "io.rustdesknative",
                serverConfiguration: serverConfiguration()
            )
        ) { error in
            XCTAssertEqual(error as? TestFailure, .start)
        }
        XCTAssertEqual(client.operations, [
            .setConfigRoot("FarPaneHost", "io.rustdesknative"),
            .start("one.example.invalid:21116", "", "public-key"),
        ])
    }

    func testDeinitStopsStartedRuntimeWithAppExit() throws {
        let client = RecordingHostAgentCoreClient()
        do {
            let runtime = try HostAgentCoreRuntime.start(
                client: client,
                configAppName: "FarPaneHost",
                configOrganization: "io.rustdesknative",
                serverConfiguration: serverConfiguration()
            )
            withExtendedLifetime(runtime) {}
        }

        XCTAssertEqual(client.operations, [
            .setConfigRoot("FarPaneHost", "io.rustdesknative"),
            .start("one.example.invalid:21116", "", "public-key"),
            .stop(.appExit),
        ])
    }

    func testStopFailureStillPreventsDuplicateTeardown() throws {
        let client = RecordingHostAgentCoreClient(failure: .stop)
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )

        XCTAssertThrowsError(try runtime.stop(reason: .error)) { error in
            XCTAssertEqual(error as? TestFailure, .stop)
        }
        XCTAssertNoThrow(try runtime.stop(reason: .appExit))
        XCTAssertEqual(client.operations.filter {
            if case .stop = $0 { return true }
            return false
        }, [.stop(.error)])
    }

    func testCopiesSnapshotOnlyWhileRuntimeIsRunning() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )

        let snapshot = try runtime.copySnapshot()
        XCTAssertEqual(snapshot.hostInstanceId, "host-agent-test")
        XCTAssertEqual(client.operations.last, .copySnapshot)

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.copySnapshot()) { error in
            XCTAssertEqual(
                error as? HostAgentCoreRuntimeAccessError,
                .notRunning
            )
        }
        XCTAssertEqual(
            client.operations.filter { $0 == .copySnapshot }.count,
            1
        )
    }

    func testSleepRecoveryOperationsUseExactEpochAndFailAfterStop() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )

        try runtime.beginSleep(epoch: 7)
        try runtime.finishSleep(epoch: 7)
        try runtime.resumeAfterWake(epoch: 7)
        XCTAssertEqual(Array(client.operations.suffix(3)), [
            .beginSleep(7),
            .finishSleep(7),
            .resumeAfterWake(7),
        ])

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.beginSleep(epoch: 8)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertThrowsError(try runtime.finishSleep(epoch: 7)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertThrowsError(try runtime.resumeAfterWake(epoch: 7)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(client.operations.filter {
            switch $0 {
            case .beginSleep, .finishSleep, .resumeAfterWake:
                return true
            default:
                return false
            }
        }.count, 3)
    }

    func testNetworkRecoveryUsesExactGenerationAndFailsAfterStop() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )

        try runtime.recoverNetworkPath(generation: 7)
        XCTAssertEqual(client.operations.last, .recoverNetworkPath(7))

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(
            try runtime.recoverNetworkPath(generation: 8)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentCoreRuntimeAccessError,
                .notRunning
            )
        }
        XCTAssertEqual(client.operations.filter {
            if case .recoverNetworkPath = $0 { return true }
            return false
        }.count, 1)
    }

    func testMediaOperationsUseSameOwnerAndFailAfterStop() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )
        let capabilities = HostEncoderCapabilities(
            h264Hardware: true,
            h265Hardware: true,
            maxWidth: 1_920,
            maxHeight: 1_080,
            maxFPS: 30
        )
        let accessUnit = HostEncodedAccessUnit(
            hostInstanceID: "host-agent-test",
            connectionEpoch: 11,
            codecEpoch: 21,
            displayID: 0,
            displayRevision: 3,
            codec: .h264,
            framing: .avcc,
            presentationTimeUS: 10,
            isKeyframe: true,
            hasParameterSets: true,
            data: Data([0, 0, 0, 1])
        )

        try runtime.setMediaCapabilities(
            hostInstanceID: "host-agent-test",
            capabilities: capabilities
        )
        try runtime.submit(accessUnit: accessUnit)
        try runtime.reportEncoderState(
            hostInstanceID: "host-agent-test",
            connectionEpoch: 11,
            codecEpoch: 21,
            codec: .h264,
            hardwareAccelerated: true,
            softwareFallback: false,
            encoderID: "test-encoder"
        )
        XCTAssertEqual(Array(client.operations.suffix(3)), [
            .setMediaCapabilities("host-agent-test", true, true, 1_920, 1_080, 30),
            .submitMedia("host-agent-test", 11, 21, 0, 3, 10, 4),
            .reportEncoderState("host-agent-test", 11, 21, "test-encoder"),
        ])

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.submit(accessUnit: accessUnit)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(
            client.operations.filter {
                if case .submitMedia = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testTypedCommandsUseSameOwnerAndFailAfterStop() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )
        let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
        let cases: [(HostAgentXPCWireCommandName, RecordedOperation)] = [
            (
                .approveIncoming,
                .resolveApproval(
                    "host-agent-test:connection-1",
                    .approve,
                    "command-0"
                )
            ),
            (
                .rejectIncoming,
                .resolveApproval(
                    "host-agent-test:connection-1",
                    .reject,
                    "command-1"
                )
            ),
            (
                .disableInputForActiveSession,
                .disableCapability(
                    "host-agent-test:connection-1",
                    .keyboardAndMouse,
                    "command-2"
                )
            ),
            (
                .disableClipboardReadForActiveSession,
                .disableCapability(
                    "host-agent-test:connection-1",
                    .clipboardRead,
                    "command-3"
                )
            ),
            (
                .disableClipboardWriteForActiveSession,
                .disableCapability(
                    "host-agent-test:connection-1",
                    .clipboardWrite,
                    "command-4"
                )
            ),
            (
                .disableClipboardForActiveSession,
                .disableCapability(
                    "host-agent-test:connection-1",
                    .clipboard,
                    "command-5"
                )
            ),
            (
                .disableAudioForActiveSession,
                .disableCapability(
                    "host-agent-test:connection-1",
                    .systemAudio,
                    "command-6"
                )
            ),
            (
                .disconnectSession,
                .disconnectSession(
                    "host-agent-test:connection-1",
                    "command-7"
                )
            ),
        ]

        for (index, item) in cases.enumerated() {
            let request = try HostAgentXPCWireCommandRequest(
                requestID: [
                    "287fd5f2-98b7-4183-ac81-6973cef9a610",
                    "151db9a9-7dd3-4fea-93af-1b6c10840676",
                    "841733af-919b-4dc2-84bb-7134d0951dc9",
                    "62113cb8-4d8c-43ec-8e84-a92b77ed2ce7",
                    "9f28662b-bd6c-47df-890f-48b4f8774557",
                    "7f8207d1-1ea3-4d90-9efe-bcac72ba1d54",
                    "f29de2a1-931b-4c33-a957-f80ab1c3a8bf",
                    "ca4cd39c-ad0b-4ab8-9d9a-b48cf93a1bf1",
                ][index],
                commandID: "command-\(index)",
                wireVersion: 2,
                hostInstanceID: "host-agent-test",
                agentBootID: bootID,
                name: item.0,
                connectionID: "host-agent-test:connection-1",
                sentAtUnixMilliseconds: 10
            )
            try runtime.submit(command: HostAgentCoreCommandSubmission(
                validatedRequest: request
            ))
        }
        XCTAssertEqual(
            Array(client.operations.suffix(cases.count)),
            cases.map(\.1)
        )

        try runtime.stop(reason: .appExit)
        let request = try HostAgentXPCWireCommandRequest(
            requestID: "eaa7431f-5139-42d2-88a2-d6ce72dc9f47",
            commandID: "command-after-stop",
            wireVersion: 2,
            hostInstanceID: "host-agent-test",
            agentBootID: bootID,
            name: .disconnectSession,
            connectionID: "host-agent-test:connection-1",
            sentAtUnixMilliseconds: 11
        )
        XCTAssertThrowsError(try runtime.submit(
            command: HostAgentCoreCommandSubmission(validatedRequest: request)
        )) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(
            client.operations.filter {
                if case .disconnectSession = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testPasswordOperationsUseSameOwnerAndFailAfterStop() throws {
        let client = RecordingHostAgentCoreClient()
        let runtime = try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: serverConfiguration()
        )
        var empty = Data()
        let revealed = try runtime.performPasswordOperation(
            .revealTemporaryPassword,
            secret: &empty,
            requestID: "password-1"
        )
        XCTAssertEqual(revealed, Data("135792468".utf8))

        var permanent = Data("strong-password-123".utf8)
        XCTAssertNil(try runtime.performPasswordOperation(
            .setPermanentPassword,
            secret: &permanent,
            requestID: "password-2"
        ))
        XCTAssertNil(try runtime.performPasswordOperation(
            .regenerateTemporaryPassword,
            secret: &empty,
            requestID: "password-3"
        ))
        XCTAssertNil(try runtime.performPasswordOperation(
            .clearPermanentPassword,
            secret: &empty,
            requestID: "password-4"
        ))
        XCTAssertEqual(
            Array(client.operations.suffix(4)),
            [
                .revealTemporaryPassword("password-1"),
                .setPermanentPassword("strong-password-123", "password-2"),
                .regenerateTemporaryPassword("password-3"),
                .clearPermanentPassword("password-4"),
            ]
        )

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.performPasswordOperation(
            .revealTemporaryPassword,
            secret: &empty,
            requestID: "password-5"
        )) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
    }

    private func serverConfiguration() -> HostServerConfiguration {
        HostServerConfiguration(
            rendezvousServer: "one.example.invalid:21116",
            serverPublicKey: "public-key"
        )
    }
}

private enum TestFailure: Error, Equatable {
    case configRoot
    case start
    case stop
}

private enum RecordedOperation: Equatable {
    case setConfigRoot(String, String)
    case start(String, String, String)
    case copySnapshot
    case beginSleep(UInt64)
    case finishSleep(UInt64)
    case resumeAfterWake(UInt64)
    case recoverNetworkPath(UInt64)
    case setMediaCapabilities(String, Bool, Bool, UInt32, UInt32, UInt32)
    case submitMedia(String, UInt64, UInt64, UInt64, UInt64, UInt64, Int)
    case reportEncoderState(String, UInt64, UInt64, String)
    case resolveApproval(String, HostApprovalDecision, String)
    case disableCapability(
        String,
        HostSessionRevocableCapability,
        String
    )
    case disconnectSession(String, String)
    case revealTemporaryPassword(String)
    case regenerateTemporaryPassword(String)
    case setPermanentPassword(String, String)
    case clearPermanentPassword(String)
    case stop(HostStopReason)
}

private final class RecordingHostAgentCoreClient: HostAgentCoreControlSurface {
    private let failure: TestFailure?
    var operations: [RecordedOperation] = []

    init(failure: TestFailure? = nil) {
        self.failure = failure
    }

    func setConfigRoot(appName: String, org: String) throws {
        operations.append(.setConfigRoot(appName, org))
        if failure == .configRoot { throw TestFailure.configRoot }
    }

    func start(configuration: HostServerConfiguration) throws {
        operations.append(.start(
            configuration.rendezvousServer,
            configuration.relayServer,
            configuration.serverPublicKey
        ))
        if failure == .start { throw TestFailure.start }
    }

    func stop(reason: HostStopReason) throws {
        operations.append(.stop(reason))
        if failure == .stop { throw TestFailure.stop }
    }

    func beginSleep(epoch: UInt64) throws {
        operations.append(.beginSleep(epoch))
    }

    func finishSleep(epoch: UInt64) throws {
        operations.append(.finishSleep(epoch))
    }

    func resumeAfterWake(epoch: UInt64) throws {
        operations.append(.resumeAfterWake(epoch))
    }

    func recoverNetworkPath(generation: UInt64) throws {
        operations.append(.recoverNetworkPath(generation))
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        operations.append(.copySnapshot)
        let document: [String: Any] = [
            "schemaVersion": 8,
            "hostInstanceId": "host-agent-test",
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
            "observedAt": 1_700_000_000_000 as UInt64,
        ]
        return try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document)
        )
    }

    func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        operations.append(.setMediaCapabilities(
            hostInstanceID,
            capabilities.h264Hardware,
            capabilities.h265Hardware,
            capabilities.maxWidth,
            capabilities.maxHeight,
            capabilities.maxFPS
        ))
    }

    func submit(accessUnit: HostEncodedAccessUnit) throws {
        operations.append(.submitMedia(
            accessUnit.hostInstanceID,
            accessUnit.connectionEpoch,
            accessUnit.codecEpoch,
            accessUnit.displayID,
            accessUnit.displayRevision,
            accessUnit.presentationTimeUS,
            accessUnit.data.count
        ))
    }

    func reportEncoderState(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws {
        operations.append(.reportEncoderState(
            hostInstanceID,
            connectionEpoch,
            codecEpoch,
            encoderID
        ))
    }

    func resolvePendingApproval(
        connectionID: String,
        decision: HostApprovalDecision,
        commandId: String
    ) throws {
        operations.append(.resolveApproval(
            connectionID,
            decision,
            commandId
        ))
    }

    func disableActiveSessionCapability(
        _ capability: HostSessionRevocableCapability,
        connectionID: String,
        commandId: String
    ) throws {
        operations.append(.disableCapability(
            connectionID,
            capability,
            commandId
        ))
    }

    func disconnectSession(
        connectionID: String,
        commandId: String
    ) throws {
        operations.append(.disconnectSession(connectionID, commandId))
    }

    func revealTemporaryPassword(commandId: String) throws -> String {
        operations.append(.revealTemporaryPassword(commandId))
        return "135792468"
    }

    func regenerateTemporaryPassword(commandId: String) throws {
        operations.append(.regenerateTemporaryPassword(commandId))
    }

    func setPermanentPassword(
        _ passwordUTF8: inout Data,
        commandId: String
    ) throws {
        operations.append(.setPermanentPassword(
            String(data: passwordUTF8, encoding: .utf8) ?? "",
            commandId
        ))
    }

    func clearPermanentPassword(commandId: String) throws {
        operations.append(.clearPermanentPassword(commandId))
    }
}
