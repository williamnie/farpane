@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundActivationOwnerTests: XCTestCase {
    func testEnableCreatesAndStartsExactlyOneFreshRuntime() {
        let factory = ActivationRuntimeFactory()
        let observations = ActivationViewRecorder()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { observations.append($0) }
        )

        XCTAssertEqual(owner.snapshot().phase, .idle)
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.cancelCount, 0)
        XCTAssertEqual(
            owner.snapshot().phase,
            .monitoring(epoch: 1, readiness: runtime.readinessSnapshot())
        )
        XCTAssertEqual(
            observations.values.map(\.phase),
            [
                .starting(epoch: 1),
                .monitoring(
                    epoch: 1,
                    readiness: runtime.readinessSnapshot()
                ),
            ]
        )

        XCTAssertTrue(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(observations.values.count, 2)
    }

    func testTypedHealthUpdatesOnlyCurrentActivationEpoch() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        runtime.emitHealthy(projectionGeneration: 1)

        guard case .monitoring(let epoch, let readiness) =
            owner.snapshot().phase
        else { return XCTFail("expected monitoring") }
        XCTAssertEqual(epoch, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testMonitoringViewCarriesOnlyCoherentRuntimeProjection() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        let projectionAuthority = HostAgentBackgroundProjectionAuthority()
        _ = projectionAuthority.beginSession()
        let projection = projectionAuthority.snapshot()

        runtime.emitProjection(projection)

        XCTAssertEqual(owner.snapshot().projection, projection)
        guard case .monitoring(_, let readiness) = owner.snapshot().phase
        else { return XCTFail("expected monitoring") }
        XCTAssertEqual(
            readiness.runtime,
            HostAgentBackgroundRuntimeEvidence(projection: projection)
        )

        runtime.setProjection(projection)
        runtime.emitHealthy(
            projectionGeneration: projection.generation + 1
        )
        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(.invalidHealthSequence)
        )
        XCTAssertNil(owner.snapshot().projection)
        XCTAssertEqual(runtime.cancelCount, 1)
    }

    func testDisableCancelsBeforePublishingAndIgnoresLateHealth() {
        let factory = ActivationRuntimeFactory()
        let cancellationObserved = LockedValue(false)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { view in
                if view.phase == .disabled {
                    cancellationObserved.set(
                        factory.runtimes[0].cancelCount == 1
                    )
                }
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertTrue(owner.apply(.hostDisabled))
        let disabled = owner.snapshot()
        XCTAssertEqual(disabled.phase, .disabled)
        XCTAssertEqual(runtime.cancelCount, 1)
        XCTAssertTrue(cancellationObserved.value)

        runtime.emitHealthy(projectionGeneration: 1)
        XCTAssertEqual(owner.snapshot(), disabled)
    }

    func testReenableUsesFreshRuntimeAndRejectsOldEpochCallbacks() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let oldRuntime = factory.runtimes[0]
        XCTAssertTrue(owner.apply(.hostDisabled))

        XCTAssertTrue(owner.apply(.hostEnabled))
        let newRuntime = factory.runtimes[1]
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(newRuntime.startCount, 1)
        guard case .monitoring(let epoch, _) = owner.snapshot().phase else {
            return XCTFail("expected replacement monitoring")
        }
        XCTAssertEqual(epoch, 3)

        oldRuntime.emitHealthy(projectionGeneration: 1)
        guard case .monitoring(_, let afterOld) = owner.snapshot().phase else {
            return XCTFail("expected monitoring after old callback")
        }
        XCTAssertFalse(afterOld.isReady)

        newRuntime.emitHealthy(projectionGeneration: 1)
        guard case .monitoring(_, let afterNew) = owner.snapshot().phase else {
            return XCTFail("expected monitoring after new callback")
        }
        XCTAssertTrue(afterNew.isReady)
    }

    func testApplicationTerminationIsTerminalAndCancelsCurrentRuntime() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertTrue(owner.apply(.applicationWillTerminate))
        XCTAssertEqual(runtime.cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .terminated)
        XCTAssertFalse(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testFactoryFailureIsSanitizedAndExplicitEnableCanRetry() {
        let factory = ActivationRuntimeFactory()
        factory.failNextCreation = true
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        XCTAssertFalse(owner.apply(.hostEnabled))
        XCTAssertEqual(owner.snapshot().phase, .failed(.runtimeCreation))
        XCTAssertEqual(factory.makeCount, 1)

        XCTAssertTrue(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(factory.runtimes[0].startCount, 1)
    }

    func testRejectedRuntimeStartCancelsAndFailsClosed() {
        let factory = ActivationRuntimeFactory()
        factory.nextStartResult = false
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        XCTAssertFalse(owner.apply(.hostEnabled))

        XCTAssertEqual(owner.snapshot().phase, .failed(.runtimeStartRejected))
        XCTAssertEqual(factory.runtimes[0].startCount, 1)
        XCTAssertEqual(factory.runtimes[0].cancelCount, 1)
    }

    func testRejectedHealthCancelsRuntimeAndCannotBeRevived() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        runtime.emitInvalid(projectionGeneration: 1)
        let failed = owner.snapshot()

        XCTAssertEqual(failed.phase, .failed(.runtimeHealthRejected))
        XCTAssertEqual(runtime.cancelCount, 1)
        runtime.emitHealthy(projectionGeneration: 2)
        XCTAssertEqual(owner.snapshot(), failed)
    }

    func testDisableDuringBlockingFactoryCancelsStaleRuntimeWithoutStart() {
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let runtimeHolder = LockedValue<ActivationFakeRuntime?>(nil)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                let runtime = ActivationFakeRuntime(observer: observer)
                runtimeHolder.set(runtime)
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                return runtime
            }
        )
        let enableResult = LockedValue<Bool?>(nil)
        let enableFinished = expectation(description: "enable finished")
        DispatchQueue.global().async {
            enableResult.set(owner.apply(.hostEnabled))
            enableFinished.fulfill()
        }
        XCTAssertEqual(factoryEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(owner.apply(.hostDisabled))
        releaseFactory.signal()
        wait(for: [enableFinished], timeout: 2)

        let runtime = try? XCTUnwrap(runtimeHolder.value)
        XCTAssertEqual(enableResult.value, false)
        XCTAssertEqual(runtime?.startCount, 0)
        XCTAssertEqual(runtime?.cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testDisableDuringBlockingStartCannotBeOverwritten() {
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let runtime = ActivationFakeRuntime(
            observer: { _ in },
            startAction: {
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
                return true
            }
        )
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                runtime.replaceObserver(observer)
                return runtime
            }
        )
        let enableResult = LockedValue<Bool?>(nil)
        let enableFinished = expectation(description: "enable finished")
        DispatchQueue.global().async {
            enableResult.set(owner.apply(.hostEnabled))
            enableFinished.fulfill()
        }
        XCTAssertEqual(startEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(owner.apply(.hostDisabled))
        XCTAssertEqual(runtime.cancelCount, 1)
        releaseStart.signal()
        wait(for: [enableFinished], timeout: 2)

        XCTAssertEqual(enableResult.value, false)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testReentrantDisableFromMonitoringObserverPreventsRuntimeStart() {
        let factory = ActivationRuntimeFactory()
        let ownerHolder = LockedValue<HostAgentBackgroundActivationOwner?>(nil)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { view in
                if case .monitoring = view.phase {
                    _ = ownerHolder.value?.apply(.hostDisabled)
                }
            }
        )
        ownerHolder.set(owner)

        XCTAssertFalse(owner.apply(.hostEnabled))

        XCTAssertEqual(factory.runtimes[0].startCount, 0)
        XCTAssertEqual(factory.runtimes[0].cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testRegistrationRefreshOnlyTargetsCurrentMonitoringRuntime() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        owner.refreshRegistration()
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        owner.refreshRegistration()
        XCTAssertEqual(runtime.refreshCount, 1)

        XCTAssertTrue(owner.apply(.hostDisabled))
        owner.refreshRegistration()
        XCTAssertEqual(runtime.refreshCount, 1)
    }

    func testCommandRouteRequiresCoherentProjectionAndExactCurrentTarget()
        throws
    {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        XCTAssertEqual(owner.commandAvailabilitySnapshot(), .unavailable)
        let projection = try commandProjection(
            pendingConnectionID: "host-a:pending-1",
            activeConnectionID: "host-a:session-1"
        )
        guard case .available(let projected) = projection.phase else {
            return XCTFail("expected available projection")
        }
        let reconnectRoute = HostAgentXPCReconnectCommandRoute(
            sessionGeneration: 7,
            peerIdentity: projected.peerIdentity
        )
        runtime.setCommandAvailability(.available(
            route: reconnectRoute,
            state: .idle
        ))
        runtime.emitProjection(projection)

        guard case .available(let route, let state) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected background command route") }
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(route.activationEpoch, 1)
        XCTAssertEqual(route.projectionGeneration, projection.generation)
        XCTAssertEqual(route.reconnectRoute, reconnectRoute)
        let wrongTarget = HostAgentXPCCommandIntent(
            commandID: "command-wrong",
            name: .disconnectSession,
            connectionID: "host-a:session-2"
        )
        XCTAssertFalse(owner.submitCommand(
            route: route,
            intent: wrongTarget,
            observer: { _ in }
        ))
        let intent = HostAgentXPCCommandIntent(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:session-1"
        )
        let results = ActivationCommandResultRecorder()
        XCTAssertTrue(owner.submitCommand(
            route: route,
            intent: intent,
            observer: { results.append($0) }
        ))
        XCTAssertEqual(runtime.submittedIntents, [intent])
        runtime.publishCommand(.invalidRequest)
        XCTAssertEqual(results.values, [.invalidRequest])

        let approval = HostAgentXPCCommandIntent(
            commandID: "command-2",
            name: .approveIncoming,
            connectionID: "host-a:pending-1"
        )
        runtime.setCommandAvailability(.available(
            route: reconnectRoute,
            state: .idle
        ))
        XCTAssertTrue(owner.submitCommand(
            route: route,
            intent: approval,
            observer: { _ in }
        ))
        XCTAssertEqual(runtime.submittedIntents, [intent, approval])
        runtime.publishCommand(.invalidRequest)
        runtime.setCommandAvailability(.available(
            route: reconnectRoute,
            state: .retryable(intent)
        ))
        guard case .available(let retryRoute, .retryable(let retained)) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected retryable command route") }
        XCTAssertEqual(retained, intent)
        XCTAssertTrue(owner.retryCommand(
            route: retryRoute,
            observer: { _ in }
        ))
        XCTAssertEqual(runtime.retryCount, 1)
    }

    func testDisableInvalidatesRouteAndCompletesPendingObserverOnce()
        throws
    {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        let projection = try commandProjection(
            pendingConnectionID: nil,
            activeConnectionID: "host-a:session-1"
        )
        guard case .available(let projected) = projection.phase else {
            return XCTFail("expected available projection")
        }
        runtime.setCommandAvailability(.available(
            route: HostAgentXPCReconnectCommandRoute(
                sessionGeneration: 1,
                peerIdentity: projected.peerIdentity
            ),
            state: .idle
        ))
        runtime.emitProjection(projection)
        guard case .available(let route, _) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected route") }
        let results = ActivationCommandResultRecorder()
        XCTAssertTrue(owner.submitCommand(
            route: route,
            intent: HostAgentXPCCommandIntent(
                commandID: "command-1",
                name: .disconnectSession,
                connectionID: "host-a:session-1"
            ),
            observer: { results.append($0) }
        ))

        XCTAssertTrue(owner.apply(.hostDisabled))
        runtime.publishLateCommand(.invalidRequest)

        XCTAssertEqual(results.values, [.cancelled])
        XCTAssertEqual(owner.commandAvailabilitySnapshot(), .unavailable)
        XCTAssertFalse(owner.retryCommand(
            route: route,
            observer: { _ in }
        ))
    }

    func testLimitedSessionRejectsNewControlAtFinalSubmissionBoundary()
        throws
    {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        let projection = try commandProjection(
            pendingConnectionID: "host-a:pending-1",
            activeConnectionID: "host-a:session-1",
            limitedSession: true
        )
        guard case .available(let projected) = projection.phase else {
            return XCTFail("expected available projection")
        }
        runtime.setCommandAvailability(.available(
            route: HostAgentXPCReconnectCommandRoute(
                sessionGeneration: 7,
                peerIdentity: projected.peerIdentity
            ),
            state: .idle
        ))
        runtime.emitProjection(projection)
        guard case .available(let route, .idle) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected command route") }

        for intent in [
            HostAgentXPCCommandIntent(
                commandID: "command-approve",
                name: .approveIncoming,
                connectionID: "host-a:pending-1"
            ),
            HostAgentXPCCommandIntent(
                commandID: "command-input",
                name: .disableInputForActiveSession,
                connectionID: "host-a:session-1"
            ),
        ] {
            XCTAssertFalse(owner.submitCommand(
                route: route,
                intent: intent,
                observer: { _ in }
            ))
        }
        let disconnect = HostAgentXPCCommandIntent(
            commandID: "command-disconnect",
            name: .disconnectSession,
            connectionID: "host-a:session-1"
        )
        XCTAssertTrue(owner.submitCommand(
            route: route,
            intent: disconnect,
            observer: { _ in }
        ))
        XCTAssertEqual(runtime.submittedIntents, [disconnect])
        runtime.publishCommand(.invalidRequest)

        let retainedApproval = HostAgentXPCCommandIntent(
            commandID: "command-retained-approval",
            name: .approveIncoming,
            connectionID: "host-a:pending-1"
        )
        runtime.setCommandAvailability(.available(
            route: route.reconnectRoute,
            state: .retryable(retainedApproval)
        ))
        XCTAssertEqual(owner.commandAvailabilitySnapshot(), .unavailable)

        runtime.setCommandAvailability(.available(
            route: route.reconnectRoute,
            state: .retryable(disconnect)
        ))
        guard case .available(let retryRoute, .retryable(let retained)) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected exact disconnect retry") }
        XCTAssertEqual(retained, disconnect)
        XCTAssertTrue(owner.retryCommand(
            route: retryRoute,
            observer: { _ in }
        ))
        XCTAssertEqual(runtime.retryCount, 1)
    }

    func testProductFactoryAndSourceRemainInertAndIndependentFromLegacyHost()
        throws
    {
        let owner = HostAgentBackgroundActivationOwner.makeProduct()
        XCTAssertEqual(owner.snapshot().phase, .idle)
        let composition = HostAgentBackgroundRuntimeComposition.makeProduct()
        XCTAssertEqual(
            composition.commandAvailabilitySnapshot(),
            .unavailable
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundActivationOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentBackgroundRuntimeComposition.makeProduct"
        ))
        XCTAssertTrue(source.contains("reconnectOwner.start()"))
        XCTAssertTrue(source.contains("reconnectOwner.cancel()"))
        XCTAssertTrue(source.contains(
            "reconnectOwner.commandAvailabilitySnapshot()"
        ))
        XCTAssertTrue(source.contains("reconnectOwner.submitCommand("))
        XCTAssertTrue(source.contains("reconnectOwner.retryCommand("))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(appSource.contains("HostAgentBackgroundCommandRoute"))
    }

    private func commandProjection(
        pendingConnectionID: String?,
        activeConnectionID: String?,
        limitedSession: Bool = false
    ) throws -> HostAgentBackgroundProjectionView {
        let authority = HostAgentBackgroundProjectionAuthority()
        let binding = authority.beginSession()
        let peer = try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
        )
        binding.sink.publishInitialSnapshot(
            try commandSnapshot(
                pendingConnectionID: pendingConnectionID,
                activeConnectionID: activeConnectionID,
                limitedSession: limitedSession
            ),
            peerIdentity: peer,
            transition: .firstObservation
        )
        return authority.snapshot()
    }

    private func commandSnapshot(
        pendingConnectionID: String?,
        activeConnectionID: String?,
        limitedSession: Bool
    ) throws -> HostAgentXPCWireSnapshotResponse {
        let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let pending: Any = pendingConnectionID.map { connectionID in
            [
                "connectionId": connectionID,
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
            ] as [String: Any]
        } ?? NSNull()
        let active: Any = activeConnectionID.map { connectionID in
            [
                "connectionId": connectionID,
                "remoteId": "remote-2",
                "remoteName": "MBP",
                "remotePlatform": "macOS",
                "remoteMetadataTrust": "untrusted",
                "startedAt": 30,
                "initialCapabilities": [
                    "viewDisplay", "controlKeyboardMouse",
                ],
                "activeCapabilities": [
                    "viewDisplay", "controlKeyboardMouse",
                ],
                "inputAvailability": "available",
                "inputUnavailableReason": NSNull(),
            ] as [String: Any]
        } ?? NSNull()
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 8,
                    "hostInstanceId": "host-a",
                    "hostState": "ready",
                    "localId": "123456789",
                    "authenticatedConnectionCount": 1,
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
}

private enum ActivationTestError: Error {
    case creation
}

private final class ActivationRuntimeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ActivationFakeRuntime] = []
    private var creationCount = 0
    var failNextCreation = false
    var nextStartResult = true

    var runtimes: [ActivationFakeRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return creationCount
    }

    func make(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer
    ) throws -> HostAgentBackgroundActivationRuntime {
        lock.lock()
        creationCount += 1
        if failNextCreation {
            failNextCreation = false
            lock.unlock()
            throw ActivationTestError.creation
        }
        let startResult = nextStartResult
        nextStartResult = true
        let runtime = ActivationFakeRuntime(
            observer: observer,
            startAction: { startResult }
        )
        storage.append(runtime)
        lock.unlock()
        return runtime
    }
}

private final class ActivationFakeRuntime:
    HostAgentBackgroundActivationRuntime,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var healthAuthority: HostAgentBackgroundHealthAuthority
    private var startAction: @Sendable () -> Bool
    private var starts = 0
    private var cancels = 0
    private var refreshes = 0
    private var projection: HostAgentBackgroundProjectionView?
    private var commandAvailability:
        HostAgentXPCReconnectCommandAvailability = .unavailable
    private var commandIntents: [HostAgentXPCCommandIntent] = []
    private var commandRetries = 0
    private var commandObserver: HostAgentXPCSnapshotClient.CommandObserver?
    private var lastCommandObserver:
        HostAgentXPCSnapshotClient.CommandObserver?

    init(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer,
        startAction: @escaping @Sendable () -> Bool = { true }
    ) {
        self.startAction = startAction
        healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: observer
        )
    }

    var startCount: Int { locked { starts } }
    var cancelCount: Int { locked { cancels } }
    var refreshCount: Int { locked { refreshes } }
    var submittedIntents: [HostAgentXPCCommandIntent] {
        locked { commandIntents }
    }
    var retryCount: Int { locked { commandRetries } }

    func readinessSnapshot() -> HostAgentBackgroundReadinessView {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        return authority.snapshot()
    }

    func projectionSnapshot() -> HostAgentBackgroundProjectionView? {
        locked { projection }
    }

    func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    {
        locked { commandAvailability }
    }

    func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        guard commandAvailability == .available(route: route, state: .idle)
        else {
            lock.unlock()
            return false
        }
        commandIntents.append(intent)
        commandObserver = observer
        lastCommandObserver = observer
        commandAvailability = .available(
            route: route,
            state: .pausing(intent)
        )
        lock.unlock()
        return true
    }

    func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        guard case .available(route: route, state: .retryable) =
            commandAvailability
        else {
            lock.unlock()
            return false
        }
        commandObserver = observer
        lastCommandObserver = observer
        commandRetries += 1
        lock.unlock()
        return true
    }

    func startMonitoring() -> Bool {
        lock.lock()
        starts += 1
        let action = startAction
        lock.unlock()
        return action()
    }

    func refreshRegistrationObservation() {
        lock.lock()
        refreshes += 1
        let authority = healthAuthority
        lock.unlock()
        authority.refreshRegistration()
    }

    func cancelMonitoring() {
        lock.lock()
        cancels += 1
        commandAvailability = .unavailable
        let commandObserver = self.commandObserver
        self.commandObserver = nil
        lock.unlock()
        commandObserver?(.cancelled)
    }

    func replaceObserver(
        _ observer: @escaping HostAgentBackgroundHealthAuthority.Observer
    ) {
        lock.lock()
        healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: observer
        )
        lock.unlock()
    }

    func emitHealthy(projectionGeneration: UInt64) {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: projectionGeneration,
            handshake: .compatible,
            snapshot: .available,
            session: .available,
            rendezvous: .registered
        ))
    }

    func emitProjection(_ projection: HostAgentBackgroundProjectionView) {
        lock.lock()
        self.projection = projection
        let authority = healthAuthority
        lock.unlock()
        authority.acceptProjection(projection)
    }

    func setProjection(_ projection: HostAgentBackgroundProjectionView?) {
        lock.lock()
        self.projection = projection
        lock.unlock()
    }

    func setCommandAvailability(
        _ availability: HostAgentXPCReconnectCommandAvailability
    ) {
        lock.lock()
        commandAvailability = availability
        lock.unlock()
    }

    func publishCommand(_ result: HostAgentXPCSnapshotClientCommandResult) {
        let observer = locked { commandObserver }
        observer?(result)
    }

    func publishLateCommand(
        _ result: HostAgentXPCSnapshotClientCommandResult
    ) {
        let observer = locked { lastCommandObserver }
        observer?(result)
    }

    func emitInvalid(projectionGeneration: UInt64) {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: projectionGeneration,
            handshake: .disconnected,
            snapshot: .available,
            session: .available,
            rendezvous: .registered
        ))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ActivationViewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundActivationView] = []

    var values: [HostAgentBackgroundActivationView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundActivationView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ActivationCommandResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentXPCSnapshotClientCommandResult] = []

    var values: [HostAgentXPCSnapshotClientCommandResult] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentXPCSnapshotClientCommandResult) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
