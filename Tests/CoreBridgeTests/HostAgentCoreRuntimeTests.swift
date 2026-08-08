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

    func copySnapshot() throws -> HostCoreSnapshot {
        operations.append(.copySnapshot)
        let document: [String: Any] = [
            "schemaVersion": 5,
            "hostInstanceId": "host-agent-test",
            "hostState": "ready",
            "localId": "123456789",
            "registrationStatus": "ready",
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
}
