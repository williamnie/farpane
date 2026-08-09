import CoreBridge
import Foundation
import XCTest

final class HostAgentOwnedCoreRuntimeTests: XCTestCase {
    func testExplicitStopStopsCoreBeforeReleasingBootstrapOwner() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        var bootstrapOwner: HostAgentTestBootstrapOwner? = .init(recorder: recorder)
        weak let weakBootstrapOwner = bootstrapOwner

        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: try XCTUnwrap(bootstrapOwner)
        ) { retainedOwner in
            XCTAssertTrue(retainedOwner === weakBootstrapOwner)
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }
        bootstrapOwner = nil

        XCTAssertNotNil(weakBootstrapOwner)
        try runtime.stop(reason: .userRequest)

        XCTAssertNil(weakBootstrapOwner)
        XCTAssertEqual(recorder.events, [
            .bootstrapCreated,
            .runtimeFactory,
            .configRoot,
            .coreStart,
            .coreStop(.userRequest),
            .bootstrapReleased,
        ])
        XCTAssertNoThrow(try runtime.stop(reason: .appExit))
    }

    func testDeinitStopsCoreBeforeReleasingBootstrapOwner() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        var bootstrapOwner: HostAgentTestBootstrapOwner? = .init(recorder: recorder)
        weak let weakBootstrapOwner = bootstrapOwner

        do {
            let runtime = try HostAgentOwnedCoreRuntime.start(
                bootstrapOwner: try XCTUnwrap(bootstrapOwner)
            ) { _ in
                recorder.append(.runtimeFactory)
                return try self.startCore(client: client)
            }
            bootstrapOwner = nil
            XCTAssertNotNil(weakBootstrapOwner)
            withExtendedLifetime(runtime) {}
        }

        XCTAssertNil(weakBootstrapOwner)
        XCTAssertEqual(Array(recorder.events.suffix(2)), [
            .coreStop(.appExit),
            .bootstrapReleased,
        ])
    }

    func testRuntimeFactoryFailureReleasesBootstrapOwnerWithoutCoreStop() throws {
        let recorder = HostAgentLifecycleRecorder()
        var bootstrapOwner: HostAgentTestBootstrapOwner? = .init(recorder: recorder)
        weak let weakBootstrapOwner = bootstrapOwner

        XCTAssertThrowsError(
            try HostAgentOwnedCoreRuntime.start(
                bootstrapOwner: try XCTUnwrap(bootstrapOwner)
            ) { _ in
                recorder.append(.runtimeFactory)
                throw OwnedRuntimeTestFailure.runtimeFactory
            }
        ) { error in
            XCTAssertEqual(error as? OwnedRuntimeTestFailure, .runtimeFactory)
        }
        bootstrapOwner = nil

        XCTAssertNil(weakBootstrapOwner)
        XCTAssertEqual(recorder.events, [
            .bootstrapCreated,
            .runtimeFactory,
            .bootstrapReleased,
        ])
    }

    func testStopFailureStillReleasesBootstrapOwnerAndDoesNotRetry() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder, failStop: true)
        var bootstrapOwner: HostAgentTestBootstrapOwner? = .init(recorder: recorder)
        weak let weakBootstrapOwner = bootstrapOwner
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: try XCTUnwrap(bootstrapOwner)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }
        bootstrapOwner = nil

        XCTAssertThrowsError(try runtime.stop(reason: .error)) { error in
            XCTAssertEqual(error as? OwnedRuntimeTestFailure, .stop)
        }
        XCTAssertNil(weakBootstrapOwner)
        XCTAssertNoThrow(try runtime.stop(reason: .appExit))
        XCTAssertEqual(recorder.events.filter {
            if case .coreStop = $0 { return true }
            return false
        }, [.coreStop(.error)])
        XCTAssertEqual(recorder.events.last, .bootstrapReleased)
    }

    func testCopiesSnapshotThroughOwnedRuntimeOnlyBeforeStop() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        var bootstrapOwner: HostAgentTestBootstrapOwner? = .init(recorder: recorder)
        weak let weakBootstrapOwner = bootstrapOwner
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: try XCTUnwrap(bootstrapOwner)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }
        bootstrapOwner = nil

        let snapshot = try runtime.copySnapshot()
        XCTAssertEqual(snapshot.hostInstanceId, "owned-runtime-host")
        XCTAssertNotNil(weakBootstrapOwner)
        XCTAssertEqual(recorder.events.last, .coreCopySnapshot)

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.copySnapshot()) { error in
            XCTAssertEqual(
                error as? HostAgentCoreRuntimeAccessError,
                .notRunning
            )
        }
        XCTAssertNil(weakBootstrapOwner)
        XCTAssertEqual(
            recorder.events.filter { $0 == .coreCopySnapshot }.count,
            1
        )
    }

    func testSleepRecoveryOperationsStayWithinOwnedRuntimeLifetime() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: HostAgentTestBootstrapOwner(recorder: recorder)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }

        try runtime.beginSleep(epoch: 9)
        try runtime.finishSleep(epoch: 9)
        try runtime.resumeAfterWake(epoch: 9)
        XCTAssertEqual(Array(recorder.events.suffix(3)), [
            .coreBeginSleep(9),
            .coreFinishSleep(9),
            .coreResumeAfterWake(9),
        ])

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.beginSleep(epoch: 10)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertThrowsError(try runtime.finishSleep(epoch: 9)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertThrowsError(try runtime.resumeAfterWake(epoch: 9)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(recorder.events.filter {
            switch $0 {
            case .coreBeginSleep, .coreFinishSleep, .coreResumeAfterWake:
                return true
            default:
                return false
            }
        }.count, 3)
    }

    func testNetworkRecoveryStaysWithinOwnedRuntimeLifetime() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: HostAgentTestBootstrapOwner(recorder: recorder)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }

        try runtime.recoverNetworkPath(generation: 11)
        XCTAssertEqual(recorder.events.last, .coreRecoverNetworkPath(11))

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(
            try runtime.recoverNetworkPath(generation: 12)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentCoreRuntimeAccessError,
                .notRunning
            )
        }
        XCTAssertEqual(recorder.events.filter {
            if case .coreRecoverNetworkPath = $0 { return true }
            return false
        }.count, 1)
    }

    func testMediaOperationsStayWithinOwnedRuntimeLifetime() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: HostAgentTestBootstrapOwner(recorder: recorder)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }
        let capabilities = HostEncoderCapabilities(
            h264Hardware: true,
            h265Hardware: true,
            maxWidth: 1_920,
            maxHeight: 1_080,
            maxFPS: 30
        )
        let accessUnit = HostEncodedAccessUnit(
            hostInstanceID: "owned-runtime-host",
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
            hostInstanceID: "owned-runtime-host",
            capabilities: capabilities
        )
        try runtime.submit(accessUnit: accessUnit)
        try runtime.reportEncoderState(
            hostInstanceID: "owned-runtime-host",
            connectionEpoch: 11,
            codecEpoch: 21,
            codec: .h264,
            hardwareAccelerated: true,
            softwareFallback: false,
            encoderID: "test-encoder"
        )
        XCTAssertEqual(Array(recorder.events.suffix(3)), [
            .coreSetMediaCapabilities,
            .coreSubmitMedia,
            .coreReportEncoderState,
        ])

        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.submit(accessUnit: accessUnit)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(
            recorder.events.filter { $0 == .coreSubmitMedia }.count,
            1
        )
    }

    func testTypedCommandStaysWithinOwnedRuntimeLifetime() throws {
        let recorder = HostAgentLifecycleRecorder()
        let client = OwnedRuntimeRecordingClient(recorder: recorder)
        let runtime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: HostAgentTestBootstrapOwner(recorder: recorder)
        ) { _ in
            recorder.append(.runtimeFactory)
            return try self.startCore(client: client)
        }
        let request = try HostAgentXPCWireCommandRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            commandID: "command-1",
            wireVersion: 1,
            hostInstanceID: "owned-runtime-host",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            name: .disconnectSession,
            connectionID: "owned-runtime-host:connection-1",
            sentAtUnixMilliseconds: 10
        )
        let command = HostAgentCoreCommandSubmission(
            validatedRequest: request
        )

        try runtime.submit(command: command)
        XCTAssertEqual(recorder.events.last, .coreCommand)
        try runtime.stop(reason: .appExit)
        XCTAssertThrowsError(try runtime.submit(command: command)) { error in
            XCTAssertEqual(error as? HostAgentCoreRuntimeAccessError, .notRunning)
        }
        XCTAssertEqual(
            recorder.events.filter { $0 == .coreCommand }.count,
            1
        )
    }

    private func startCore(
        client: OwnedRuntimeRecordingClient
    ) throws -> HostAgentCoreRuntime {
        try HostAgentCoreRuntime.start(
            client: client,
            configAppName: "FarPaneHost",
            configOrganization: "io.rustdesknative",
            serverConfiguration: HostServerConfiguration(
                rendezvousServer: "one.example.invalid:21116",
                serverPublicKey: "public-key"
            )
        )
    }
}

private enum HostAgentLifecycleEvent: Equatable {
    case bootstrapCreated
    case runtimeFactory
    case configRoot
    case coreStart
    case coreCopySnapshot
    case coreBeginSleep(UInt64)
    case coreFinishSleep(UInt64)
    case coreResumeAfterWake(UInt64)
    case coreRecoverNetworkPath(UInt64)
    case coreSetMediaCapabilities
    case coreSubmitMedia
    case coreReportEncoderState
    case coreCommand
    case coreStop(HostStopReason)
    case bootstrapReleased
}

private final class HostAgentLifecycleRecorder {
    private(set) var events: [HostAgentLifecycleEvent] = []

    func append(_ event: HostAgentLifecycleEvent) {
        events.append(event)
    }
}

private final class HostAgentTestBootstrapOwner {
    private let recorder: HostAgentLifecycleRecorder

    init(recorder: HostAgentLifecycleRecorder) {
        self.recorder = recorder
        recorder.append(.bootstrapCreated)
    }

    deinit {
        recorder.append(.bootstrapReleased)
    }
}

private enum OwnedRuntimeTestFailure: Error, Equatable {
    case runtimeFactory
    case stop
}

private final class OwnedRuntimeRecordingClient: HostAgentCoreControlSurface {
    private let recorder: HostAgentLifecycleRecorder
    private let failStop: Bool

    init(recorder: HostAgentLifecycleRecorder, failStop: Bool = false) {
        self.recorder = recorder
        self.failStop = failStop
    }

    func setConfigRoot(appName: String, org: String) throws {
        recorder.append(.configRoot)
    }

    func start(configuration: HostServerConfiguration) throws {
        recorder.append(.coreStart)
    }

    func stop(reason: HostStopReason) throws {
        recorder.append(.coreStop(reason))
        if failStop { throw OwnedRuntimeTestFailure.stop }
    }

    func beginSleep(epoch: UInt64) throws {
        recorder.append(.coreBeginSleep(epoch))
    }

    func finishSleep(epoch: UInt64) throws {
        recorder.append(.coreFinishSleep(epoch))
    }

    func resumeAfterWake(epoch: UInt64) throws {
        recorder.append(.coreResumeAfterWake(epoch))
    }

    func recoverNetworkPath(generation: UInt64) throws {
        recorder.append(.coreRecoverNetworkPath(generation))
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        recorder.append(.coreCopySnapshot)
        let document: [String: Any] = [
            "schemaVersion": 6,
            "hostInstanceId": "owned-runtime-host",
            "hostState": "ready",
            "localId": "123456789",
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
        recorder.append(.coreSetMediaCapabilities)
    }

    func submit(accessUnit: HostEncodedAccessUnit) throws {
        recorder.append(.coreSubmitMedia)
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
        recorder.append(.coreReportEncoderState)
    }

    func resolvePendingApproval(
        connectionID: String,
        decision: HostApprovalDecision,
        commandId: String
    ) throws {
        recorder.append(.coreCommand)
    }

    func disableActiveSessionCapability(
        _ capability: HostSessionRevocableCapability,
        connectionID: String,
        commandId: String
    ) throws {
        recorder.append(.coreCommand)
    }

    func disconnectSession(
        connectionID: String,
        commandId: String
    ) throws {
        recorder.append(.coreCommand)
    }
}
