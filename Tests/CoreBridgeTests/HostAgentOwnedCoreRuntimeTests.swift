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
}
