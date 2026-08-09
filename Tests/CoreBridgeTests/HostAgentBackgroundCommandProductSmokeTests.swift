@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundCommandProductSmokeTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testHomeCommandTraversesAnonymousXPCAndRestoresAfterResnapshot()
        throws
    {
        let snapshotState = HostAgentSnapshotState()
        XCTAssertEqual(
            snapshotState.publish(
                try coreSnapshot(
                    activeCapabilities: [
                        "viewDisplay",
                        "controlKeyboardMouse",
                    ],
                    observedAt: 10
                ),
                eventSequence: 0,
                expectedHostInstanceID: hostID
            ),
            .published(generation: 1)
        )
        let eventState = try HostAgentEventState()
        let identity = try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        let executions = BackgroundCommandSmokeExecutionRecorder()
        let commandService = HostAgentXPCCommandService(
            identity: identity,
            authority: try HostAgentXPCCommandAdmissionAuthority(
                identity: identity
            ),
            prepareExecution: { execution in
                executions.prepare(execution)
            },
            publishResult: { result in
                switch eventState.ingestCommandResult(
                    result,
                    hostInstanceID: self.hostID,
                    sentAtUnixMilliseconds: 1_700_000_000_000
                ) {
                case .accepted, .unchanged:
                    return true
                case .rejected:
                    return false
                }
            },
            nowUnixMilliseconds: { 1_700_000_000_000 }
        )
        let monotonicClock = BackgroundCommandSmokeMonotonicClock()
        let handler = HostAgentXPCSnapshotSessionHandler(
            identity: identity,
            snapshotState: snapshotState,
            eventState: eventState,
            commandService: commandService,
            nowUnixMilliseconds: { 1_700_000_000_000 },
            monotonicMilliseconds: { monotonicClock.next() }
        )
        let listener = NSXPCListener.anonymous()
        let listenerDelegate = BackgroundCommandSmokeListenerDelegate(
            handler: handler
        )
        listener.delegate = listenerDelegate
        listener.resume()

        let endpoint = BackgroundCommandSmokeEndpoint(listener.endpoint)
        let presentationHolder = BackgroundCommandSmokeLockedValue<
            HostAgentBackgroundHomeCommandPresentationOwner?
        >(nil)
        let presentationViews = BackgroundCommandSmokeViewRecorder()
        let activationOwner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try BackgroundCommandSmokeRuntime(
                    observer: observer,
                    endpoint: endpoint
                )
            },
            observer: { _ in
                presentationHolder.value?.refresh()
            }
        )
        let presentationOwner =
            HostAgentBackgroundHomeCommandPresentationOwner.makeProduct(
                activationOwner: activationOwner,
                observer: { presentationViews.append($0) }
            )
        presentationHolder.set(presentationOwner)
        defer {
            presentationHolder.set(nil)
            _ = activationOwner.apply(.applicationWillTerminate)
            listener.invalidate()
        }

        XCTAssertTrue(activationOwner.apply(.hostEnabled))
        XCTAssertTrue(waitUntil {
            _ = presentationOwner.refresh()
            return presentationOwner.snapshot().command.availableActions.contains(
                .disableKeyboardAndMouse
            )
        })
        XCTAssertTrue(
            presentationOwner.snapshot().command.availableActions.contains(
                .disconnect
            )
        )

        XCTAssertTrue(presentationOwner.submit(.disableKeyboardAndMouse))
        XCTAssertTrue(waitUntil {
            presentationOwner.snapshot().result?.isTerminal == false
                && executions.started.count == 1
        })
        let execution = try XCTUnwrap(executions.started.first)
        XCTAssertEqual(execution.name, .disableInputForActiveSession)
        XCTAssertEqual(execution.connectionID, "host-a:session-1")
        XCTAssertTrue(presentationOwner.snapshot().command.isBusy)
        XCTAssertEqual(
            readOnlyPresentation(
                presentationOwner,
                activationOwner: activationOwner
            ).availableActions,
            []
        )

        XCTAssertEqual(
            commandService.acceptResult(try HostAgentXPCWireCommandResult(
                commandID: execution.commandID,
                status: .ok,
                detail: "completed"
            )),
            .published
        )
        XCTAssertTrue(waitUntil {
            presentationOwner.snapshot().result?.isTerminal == true
        })
        XCTAssertEqual(presentationOwner.snapshot().result?.tone, .success)
        XCTAssertEqual(
            presentationOwner.snapshot().result?.action,
            .disableKeyboardAndMouse
        )
        XCTAssertEqual(
            readOnlyPresentation(
                presentationOwner,
                activationOwner: activationOwner
            ).availableActions,
            []
        )

        XCTAssertEqual(
            snapshotState.publish(
                try coreSnapshot(
                    activeCapabilities: ["viewDisplay"],
                    observedAt: 11
                ),
                eventSequence: 2,
                expectedHostInstanceID: hostID
            ),
            .published(generation: 2)
        )
        XCTAssertEqual(
            eventState.ingest(try snapshotChangedEvent(eventID: 1)),
            .accepted(sequence: 2)
        )
        XCTAssertTrue(waitUntil {
            let view = presentationOwner.snapshot()
            return view.result == nil
                && view.command.availableActions == [.disconnect]
        })
        XCTAssertNil(presentationOwner.snapshot().failure)
        XCTAssertEqual(
            readOnlyPresentation(
                presentationOwner,
                activationOwner: activationOwner
            ).availableActions,
            [.disconnect]
        )
        XCTAssertGreaterThanOrEqual(presentationViews.views.count, 5)
    }

    private func readOnlyPresentation(
        _ presentationOwner:
            HostAgentBackgroundHomeCommandPresentationOwner,
        activationOwner: HostAgentBackgroundActivationOwner
    ) -> HostAgentBackgroundHomeCommandReadOnlyPresentation {
        let activation = activationOwner.snapshot()
        return HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                presentationOwner.snapshot(),
                phase: activation.phase,
                projection: activation.projection
            )
    }

    private func coreSnapshot(
        activeCapabilities: [String],
        observedAt: UInt64
    ) throws -> HostCoreSnapshot {
        let controlsKeyboardAndMouse = activeCapabilities.contains(
            "controlKeyboardMouse"
        )
        return try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 5,
                "hostInstanceId": hostID,
                "hostState": "ready",
                "localId": "123456789",
                "registrationStatus": "ready",
                "pendingApproval": NSNull(),
                "activeSession": [
                    "connectionId": "host-a:session-1",
                    "remoteId": "remote-2",
                    "remoteName": "MBP",
                    "remotePlatform": "macOS",
                    "remoteMetadataTrust": "untrusted",
                    "startedAt": 30,
                    "initialCapabilities": [
                        "viewDisplay",
                        "controlKeyboardMouse",
                    ],
                    "activeCapabilities": activeCapabilities,
                    "inputAvailability": controlsKeyboardAndMouse
                        ? "available"
                        : "disabled",
                    "inputUnavailableReason": controlsKeyboardAndMouse
                        ? NSNull()
                        : "remoteDisabled",
                ],
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
                "observedAt": observedAt,
            ]
        ))
    }

    private func snapshotChangedEvent(eventID: UInt64) throws
        -> HostCoreEvent
    {
        try XCTUnwrap(HostCoreEvent(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "eventId": eventID,
                "eventType": "snapshotChanged",
                "hostInstanceId": hostID,
                "sentAt": 1_700_000_000_001 as UInt64,
                "payload": [:],
            ]
        )))
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return predicate()
    }
}

private final class BackgroundCommandSmokeRuntime:
    HostAgentBackgroundActivationRuntime,
    @unchecked Sendable
{
    private let healthAuthority: HostAgentBackgroundHealthAuthority
    private let projectionAuthority: HostAgentBackgroundProjectionAuthority
    private let reconnectOwner: HostAgentXPCReconnectOwner

    init(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer,
        endpoint: BackgroundCommandSmokeEndpoint
    ) throws {
        let healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: observer
        )
        let projectionAuthority = HostAgentBackgroundProjectionAuthority(
            observer: { [weak healthAuthority] projection in
                healthAuthority?.acceptProjection(projection)
            }
        )
        let pollingQueue = DispatchQueue(
            label: "io.farpane.tests.background-command-smoke.polling"
        )
        let reconnectQueue = DispatchQueue(
            label: "io.farpane.tests.background-command-smoke.reconnect"
        )
        let reconnectOwner = HostAgentXPCReconnectOwner(
            projectionAuthority: projectionAuthority,
            schedule: HostAgentXPCReconnectOwner.productScheduler(
                queue: reconnectQueue
            ),
            jitter: { _ in 0 },
            makeSession: { previousPeerIdentity, sink in
                let relay = BackgroundCommandSmokeLifecycleRelay()
                let connection = NSXPCConnection(
                    listenerEndpoint: endpoint.value
                )
                let client = try HostAgentXPCSnapshotClient(
                    appBuildID: "app-build",
                    previousPeerIdentity: previousPeerIdentity,
                    transport: HostAgentXPCSnapshotClientConnectionTransport(
                        connection: connection
                    ),
                    makeRequestID: {
                        UUID().uuidString.lowercased()
                    },
                    nowUnixMilliseconds: { 1_700_000_000_000 },
                    onIdentityReplacementRequired: {
                        relay.identityReplacementRequired()
                    },
                    onConnectionEnded: {
                        relay.connectionDidEnd()
                    }
                )
                let lifecycle = HostAgentXPCSessionLifecycle(
                    client: client,
                    sink: sink,
                    makePollingOwner: { onResult, onTerminal in
                        HostAgentXPCEventPollingOwner.makeProduct(
                            client: client,
                            queue: pollingQueue,
                            onResult: onResult,
                            onTerminal: onTerminal
                        )
                    }
                )
                relay.bind(lifecycle)
                return lifecycle
            }
        )
        self.healthAuthority = healthAuthority
        self.projectionAuthority = projectionAuthority
        self.reconnectOwner = reconnectOwner
    }

    func readinessSnapshot() -> HostAgentBackgroundReadinessView {
        healthAuthority.snapshot()
    }

    func projectionSnapshot() -> HostAgentBackgroundProjectionView? {
        projectionAuthority.snapshot()
    }

    func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    {
        reconnectOwner.commandAvailabilitySnapshot()
    }

    @discardableResult
    func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        reconnectOwner.submitCommand(
            route: route,
            intent: intent,
            observer: observer
        )
    }

    @discardableResult
    func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        reconnectOwner.retryCommand(route: route, observer: observer)
    }

    @discardableResult
    func startMonitoring() -> Bool { reconnectOwner.start() }

    func refreshRegistrationObservation() {
        healthAuthority.refreshRegistration()
    }

    func cancelMonitoring() { reconnectOwner.cancel() }
}

private final class BackgroundCommandSmokeListenerDelegate:
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

private final class BackgroundCommandSmokeLifecycleRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var lifecycle: HostAgentXPCSessionLifecycle?

    func bind(_ lifecycle: HostAgentXPCSessionLifecycle) {
        lock.lock()
        self.lifecycle = lifecycle
        lock.unlock()
    }

    func identityReplacementRequired() {
        lockedLifecycle()?.identityReplacementRequired()
    }

    func connectionDidEnd() {
        lockedLifecycle()?.connectionDidEnd()
    }

    private func lockedLifecycle() -> HostAgentXPCSessionLifecycle? {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle
    }
}

private final class BackgroundCommandSmokeExecutionRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var startedStorage: [HostAgentXPCCommandExecution] = []

    var started: [HostAgentXPCCommandExecution] {
        lock.lock()
        defer { lock.unlock() }
        return startedStorage
    }

    func prepare(_ execution: HostAgentXPCCommandExecution)
        -> HostAgentXPCCommandQueueTicket
    {
        return HostAgentXPCCommandQueueTicket { [weak self] in
            self?.markStarted(execution)
        }
    }

    private func markStarted(_ execution: HostAgentXPCCommandExecution) {
        lock.lock()
        startedStorage.append(execution)
        lock.unlock()
    }
}

private final class BackgroundCommandSmokeMonotonicClock:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1_000
        return value
    }
}

private final class BackgroundCommandSmokeEndpoint: @unchecked Sendable {
    let value: NSXPCListenerEndpoint

    init(_ value: NSXPCListenerEndpoint) { self.value = value }
}

private final class BackgroundCommandSmokeViewRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundHomeCommandPresentationView] = []

    var views: [HostAgentBackgroundHomeCommandPresentationView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ view: HostAgentBackgroundHomeCommandPresentationView) {
        lock.lock()
        storage.append(view)
        lock.unlock()
    }
}

private final class BackgroundCommandSmokeLockedValue<Value>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

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
