@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHomeCommandPresentationOwnerTests:
    XCTestCase
{
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testRefreshSubmitQueuedAndCompletionRemainSerialized()
        throws
    {
        let fixture = try commandFixture(epoch: 9)
        let dependencies = PresentationOwnerDependencies(fixture: fixture)
        let recorder = PresentationOwnerRecorder()
        let ownerHolder = PresentationOwnerLockedValue<
            HostAgentBackgroundHomeCommandPresentationOwner?
        >(nil)
        let reentrant = PresentationOwnerLockedValue<[Bool]>([])
        let owner = makeOwner(dependencies) { view in
            recorder.append(view)
            if view.command.isBusy {
                reentrant.withValue {
                    $0.append(ownerHolder.value?.submit(.disconnect) ?? true)
                }
            }
        }
        ownerHolder.set(owner)

        XCTAssertEqual(owner.snapshot().generation, 0)
        XCTAssertEqual(dependencies.observationCount, 0)
        XCTAssertTrue(owner.refresh())
        XCTAssertEqual(
            owner.snapshot().command.availableActions,
            HostAgentBackgroundHomeCommandAction.allCases
        )

        XCTAssertTrue(owner.submit(.approveIncoming))
        let submission = try XCTUnwrap(dependencies.submissions.first)
        XCTAssertEqual(submission.intent.commandID, "command-1")
        XCTAssertEqual(submission.intent.name, .approveIncoming)
        XCTAssertEqual(
            submission.intent.connectionID,
            "host-a:pending-1"
        )
        XCTAssertTrue(owner.snapshot().command.isBusy)
        XCTAssertEqual(
            owner.snapshot().command.activeAction,
            .approveIncoming
        )

        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        XCTAssertEqual(
            owner.snapshot().result?.statusText,
            "允许连接已排队，等待后台确认…"
        )
        XCTAssertFalse(owner.snapshot().result?.isTerminal ?? true)

        dependencies.publish(.completed(
            try HostAgentXPCWireCommandResult(
                commandID: submission.intent.commandID,
                status: .ok,
                detail: "ok"
            )
        ))
        XCTAssertEqual(owner.snapshot().result?.tone, .success)
        XCTAssertTrue(owner.snapshot().result?.isTerminal ?? false)
        XCTAssertFalse(owner.snapshot().command.isBusy)
        XCTAssertEqual(owner.snapshot().failure, nil)
        XCTAssertEqual(dependencies.commandIDCount, 1)
        XCTAssertTrue(reentrant.value.allSatisfy { !$0 })
        XCTAssertEqual(
            recorder.views.map(\.generation),
            Array(1...recorder.views.count).map(UInt64.init)
        )
    }

    func testRetryReusesOriginalSubmissionAndCommandID() throws {
        let fixture = try commandFixture(epoch: 9)
        let dependencies = PresentationOwnerDependencies(fixture: fixture)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.disconnect))
        let submission = try XCTUnwrap(dependencies.submissions.first)
        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.resultUnknown)

        XCTAssertTrue(owner.snapshot().command.canRetry)
        XCTAssertTrue(owner.snapshot().result?.canRetry ?? false)
        XCTAssertTrue(owner.retry())
        XCTAssertEqual(dependencies.retryCount, 1)
        XCTAssertEqual(dependencies.commandIDCount, 1)
        XCTAssertEqual(dependencies.retainedIntent, submission.intent)
        XCTAssertTrue(owner.snapshot().command.isBusy)

        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.completed(
            try HostAgentXPCWireCommandResult(
                commandID: submission.intent.commandID,
                status: .ok,
                detail: "ok"
            )
        ))
        XCTAssertEqual(owner.snapshot().result?.tone, .success)
        XCTAssertFalse(owner.snapshot().result?.canRetry ?? true)
        XCTAssertEqual(dependencies.commandIDCount, 1)
    }

    func testReadOnlyProjectionMapsBusyRetryAndTerminalWithoutActions()
        throws
    {
        let fixture = try commandFixture(epoch: 9)
        let dependencies = PresentationOwnerDependencies(fixture: fixture)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        var display =
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                owner.snapshot(),
                phase: dependencies.activationSnapshot.phase,
                projection: dependencies.activationSnapshot.projection
            )
        XCTAssertEqual(
            display.availableActions,
            HostAgentBackgroundHomeCommandAction.allCases
        )
        XCTAssertNil(display.retryAction)
        XCTAssertTrue(owner.submit(.disconnect))
        let submission = try XCTUnwrap(dependencies.submissions.first)

        XCTAssertEqual(
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
                .presentation(
                    owner.snapshot(),
                    phase: nil,
                    projection: dependencies.activationSnapshot.projection
                ),
            .unavailable
        )
        let unavailableHealth = HostAgentBackgroundHealthAuthority(
            initialRegistration: .notRegistered,
            observeRegistration: { .notRegistered }
        )
        if let projection = dependencies.activationSnapshot.projection {
            unavailableHealth.acceptProjection(projection)
        }
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
                .presentation(
                    owner.snapshot(),
                    phase: .monitoring(
                        epoch: 9,
                        readiness: unavailableHealth.snapshot()
                    ),
                    projection: dependencies.activationSnapshot.projection
                ),
            .unavailable
        )

        display =
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                owner.snapshot(),
                phase: dependencies.activationSnapshot.phase,
                projection: dependencies.activationSnapshot.projection
            )
        XCTAssertEqual(display.activeAction, .disconnect)
        XCTAssertEqual(display.statusText, "正在提交断开连接…")
        XCTAssertEqual(display.errorText, "")
        XCTAssertFalse(display.canRetry)
        XCTAssertEqual(display.availableActions, [])
        XCTAssertNil(display.retryAction)

        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.resultUnknown)
        display = HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                owner.snapshot(),
                phase: dependencies.activationSnapshot.phase,
                projection: dependencies.activationSnapshot.projection
            )
        XCTAssertNil(display.activeAction)
        XCTAssertEqual(
            display.errorText,
            "连接中断，无法确认断开连接结果；可重试同一操作。"
        )
        XCTAssertTrue(display.canRetry)
        XCTAssertEqual(display.availableActions, [])
        XCTAssertEqual(display.retryAction, .disconnect)

        XCTAssertTrue(owner.retry())
        display = HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                owner.snapshot(),
                phase: dependencies.activationSnapshot.phase,
                projection: dependencies.activationSnapshot.projection
            )
        XCTAssertEqual(display.activeAction, .disconnect)
        XCTAssertFalse(display.canRetry)
        XCTAssertEqual(display.availableActions, [])
        XCTAssertNil(display.retryAction)

        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.completed(
            try HostAgentXPCWireCommandResult(
                commandID: submission.intent.commandID,
                status: .ok,
                detail: "ok"
            )
        ))
        display = HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
            .presentation(
                owner.snapshot(),
                phase: dependencies.activationSnapshot.phase,
                projection: dependencies.activationSnapshot.projection
            )
        XCTAssertNil(display.activeAction)
        XCTAssertEqual(display.statusText, "断开连接已完成。")
        XCTAssertEqual(display.errorText, "")
        XCTAssertFalse(display.canRetry)
        XCTAssertEqual(display.availableActions, [])
        XCTAssertNil(display.retryAction)
    }

    func testOwnerAwareRoutingNeverFallsBackAcrossLegacyAndBackground()
        throws
    {
        let fixture = try commandFixture(epoch: 9)
        let dependencies = PresentationOwnerDependencies(fixture: fixture)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        let visible = HostAgentHomeCommandVisibleTargets(
            approvalConnectionID: "host-a:pending-1",
            sessionConnectionID: "host-a:session-1",
            enabledActions:
                HostAgentBackgroundHomeCommandAction.allCases
        )

        for action in HostAgentBackgroundHomeCommandAction.allCases {
            let connectionID = connectionID(for: action)
            XCTAssertEqual(
                commandRoute(
                    request: .perform(
                        action: action,
                        connectionID: connectionID
                    ),
                    owner: .background,
                    visible: visible,
                    fixture: fixture,
                    commandView: owner.snapshot(),
                    legacyCommandsAvailable: true
                ),
                .background(action: action)
            )
            XCTAssertEqual(
                commandRoute(
                    request: .perform(
                        action: action,
                        connectionID: connectionID
                    ),
                    owner: .legacy,
                    visible: visible,
                    fixture: fixture,
                    commandView: nil,
                    legacyCommandsAvailable: true
                ),
                .legacy(action: action, connectionID: connectionID)
            )
        }

        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .approveIncoming,
                    connectionID: "host-a:session-1"
                ),
                owner: .background,
                visible: visible,
                fixture: fixture,
                commandView: owner.snapshot(),
                legacyCommandsAvailable: true
            ),
            .none
        )
        let approvalOnly = HostAgentHomeCommandVisibleTargets(
            approvalConnectionID: "host-a:pending-1",
            sessionConnectionID: "host-a:session-1",
            enabledActions: [.approveIncoming]
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .rejectIncoming,
                    connectionID: "host-a:pending-1"
                ),
                owner: .background,
                visible: approvalOnly,
                fixture: fixture,
                commandView: owner.snapshot(),
                legacyCommandsAvailable: true
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .rejectIncoming,
                    connectionID: "host-a:pending-1"
                ),
                owner: .legacy,
                visible: approvalOnly,
                fixture: fixture,
                commandView: nil,
                legacyCommandsAvailable: true
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .disconnect,
                    connectionID: "host-a:pending-1"
                ),
                owner: .legacy,
                visible: visible,
                fixture: fixture,
                commandView: nil,
                legacyCommandsAvailable: true
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .retry(connectionID: "host-a:session-1"),
                owner: .legacy,
                visible: visible,
                fixture: fixture,
                commandView: nil,
                legacyCommandsAvailable: true
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .approveIncoming,
                    connectionID: "host-a:pending-1"
                ),
                owner: .legacy,
                visible: visible,
                fixture: fixture,
                commandView: nil,
                legacyCommandsAvailable: false
            ),
            .none
        )
        XCTAssertEqual(
            HostAgentHomeCommandRoutingPolicy.route(
                request: .perform(
                    action: .approveIncoming,
                    connectionID: "host-a:pending-1"
                ),
                owner: .background,
                visibleTargets: visible,
                legacyCommandsAvailable: true,
                phase: nil,
                projection: fixture.activation.projection,
                commandView: owner.snapshot()
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .approveIncoming,
                    connectionID: "host-a:pending-1"
                ),
                owner: .unavailable,
                visible: visible,
                fixture: fixture,
                commandView: owner.snapshot(),
                legacyCommandsAvailable: true
            ),
            .none
        )
    }

    func testBackgroundRoutingRequiresExactIdleOrRetryableState()
        throws
    {
        let first = try commandFixture(epoch: 9)
        let second = try commandFixture(epoch: 10)
        let dependencies = PresentationOwnerDependencies(fixture: first)
        let owner = makeOwner(dependencies)
        let visible = HostAgentHomeCommandVisibleTargets(
            approvalConnectionID: "host-a:pending-1",
            sessionConnectionID: "host-a:session-1",
            enabledActions:
                HostAgentBackgroundHomeCommandAction.allCases
        )
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.disconnect))
        let submission = try XCTUnwrap(dependencies.submissions.first)

        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .disconnect,
                    connectionID: "host-a:session-1"
                ),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .retry(connectionID: "host-a:session-1"),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .none
        )

        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.resultUnknown)
        XCTAssertEqual(
            commandRoute(
                request: .retry(connectionID: "host-a:session-1"),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .backgroundRetry(action: .disconnect)
        )
        XCTAssertEqual(
            commandRoute(
                request: .retry(connectionID: "host-a:pending-1"),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .none
        )
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .disconnect,
                    connectionID: "host-a:session-1"
                ),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .none
        )

        XCTAssertTrue(owner.retry())
        dependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        dependencies.publish(.completed(
            try HostAgentXPCWireCommandResult(
                commandID: submission.intent.commandID,
                status: .ok,
                detail: "ok"
            )
        ))
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .disconnect,
                    connectionID: "host-a:session-1"
                ),
                owner: .background,
                visible: visible,
                fixture: first,
                commandView: owner.snapshot()
            ),
            .none
        )

        dependencies.replace(with: second)
        XCTAssertTrue(owner.refresh())
        XCTAssertEqual(
            commandRoute(
                request: .perform(
                    action: .disconnect,
                    connectionID: "host-a:session-1"
                ),
                owner: .background,
                visible: visible,
                fixture: second,
                commandView: owner.snapshot()
            ),
            .background(action: .disconnect)
        )
    }

    func testDispatchExecutesExactlyOneOwnerAndNeverFallsBack() {
        var calls: [String] = []
        let performLegacy:
            HostAgentHomeCommandDispatchPolicy.PerformLegacy =
            { action, connectionID in
                calls.append("legacy:\(action):\(connectionID)")
                return true
            }
        let submitBackground:
            HostAgentHomeCommandDispatchPolicy.SubmitBackground =
            { action in
                calls.append("background:\(action)")
                return false
            }
        let retryBackground:
            HostAgentHomeCommandDispatchPolicy.RetryBackground =
            { action in
                calls.append("retry:\(action)")
                return true
            }

        XCTAssertFalse(HostAgentHomeCommandDispatchPolicy.dispatch(
            route: .none,
            performLegacy: performLegacy,
            submitBackground: submitBackground,
            retryBackground: retryBackground
        ))
        XCTAssertEqual(calls, [])

        XCTAssertTrue(HostAgentHomeCommandDispatchPolicy.dispatch(
            route: .legacy(
                action: .approveIncoming,
                connectionID: "host-a:pending-1"
            ),
            performLegacy: performLegacy,
            submitBackground: submitBackground,
            retryBackground: retryBackground
        ))
        XCTAssertEqual(calls, [
            "legacy:approveIncoming:host-a:pending-1",
        ])

        calls = []
        XCTAssertFalse(HostAgentHomeCommandDispatchPolicy.dispatch(
            route: .background(action: .disconnect),
            performLegacy: performLegacy,
            submitBackground: submitBackground,
            retryBackground: retryBackground
        ))
        XCTAssertEqual(calls, ["background:disconnect"])

        calls = []
        XCTAssertTrue(HostAgentHomeCommandDispatchPolicy.dispatch(
            route: .backgroundRetry(action: .disableClipboard),
            performLegacy: performLegacy,
            submitBackground: submitBackground,
            retryBackground: retryBackground
        ))
        XCTAssertEqual(calls, ["retry:disableClipboard"])
    }

    func testRouteReplacementDropsOldAttemptAndLateCallback() throws {
        let first = try commandFixture(epoch: 9)
        let second = try commandFixture(epoch: 10)
        let dependencies = PresentationOwnerDependencies(fixture: first)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.approveIncoming))
        XCTAssertEqual(dependencies.observerCount, 1)

        dependencies.replace(with: second)
        XCTAssertTrue(owner.refresh())
        XCTAssertEqual(owner.snapshot().command.route, second.route)
        XCTAssertNil(owner.snapshot().result)
        XCTAssertNil(owner.snapshot().failure)
        XCTAssertTrue(owner.submit(.rejectIncoming))
        XCTAssertEqual(dependencies.observerCount, 2)
        let current = owner.snapshot()

        dependencies.publishLate(index: 0, result: .cancelled)

        XCTAssertEqual(owner.snapshot(), current)
        XCTAssertEqual(owner.snapshot().command.route, second.route)
        XCTAssertEqual(
            owner.snapshot().command.activeAction,
            .rejectIncoming
        )
    }

    func testForeignAckFailsClosedUntilAReplacementRoute() throws {
        let first = try commandFixture(epoch: 9)
        let second = try commandFixture(epoch: 10)
        let dependencies = PresentationOwnerDependencies(fixture: first)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.approveIncoming))
        let submission = try XCTUnwrap(dependencies.submissions.first)
        let foreignIntent = HostAgentXPCCommandIntent(
            commandID: submission.intent.commandID,
            name: .approveIncoming,
            connectionID: "host-b:pending-1"
        )
        let foreignAccepted = try acceptedResponse(
            for: foreignIntent,
            hostInstanceID: "host-b",
            agentBootID: "287fd5f2-98b7-4183-ac81-6973cef9a610"
        )

        dependencies.publishForeignAccepted(foreignAccepted)

        XCTAssertEqual(owner.snapshot().failure, .invalidResult)
        XCTAssertEqual(owner.snapshot().command, .unavailable)
        XCTAssertFalse(owner.refresh())
        XCTAssertFalse(owner.submit(.rejectIncoming))

        dependencies.replace(with: second)
        XCTAssertTrue(owner.refresh())
        XCTAssertNil(owner.snapshot().failure)
        XCTAssertEqual(owner.snapshot().command.route, second.route)
        XCTAssertTrue(owner.snapshot().command.availableActions.contains(
            .rejectIncoming
        ))
    }

    func testTerminalResultBeforeAcceptedFailsClosedUntilReplacementRoute()
        throws
    {
        let first = try commandFixture(epoch: 9)
        let second = try commandFixture(epoch: 10)
        let dependencies = PresentationOwnerDependencies(fixture: first)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.disconnect))
        let submission = try XCTUnwrap(dependencies.submissions.first)

        dependencies.publish(.completed(
            try HostAgentXPCWireCommandResult(
                commandID: submission.intent.commandID,
                status: .ok,
                detail: "ok"
            )
        ))

        XCTAssertEqual(owner.snapshot().failure, .invalidResult)
        XCTAssertEqual(owner.snapshot().command, .unavailable)
        XCTAssertNil(owner.snapshot().result)
        XCTAssertFalse(owner.refresh())

        dependencies.replace(with: second)
        XCTAssertTrue(owner.refresh())
        XCTAssertNil(owner.snapshot().failure)
        XCTAssertEqual(owner.snapshot().command.route, second.route)
    }

    func testDuplicateAcceptedFailsClosed() throws {
        let fixture = try commandFixture(epoch: 9)
        let dependencies = PresentationOwnerDependencies(fixture: fixture)
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.refresh())
        XCTAssertTrue(owner.submit(.approveIncoming))
        let submission = try XCTUnwrap(dependencies.submissions.first)
        let accepted = try acceptedResponse(for: submission.intent)

        dependencies.publish(.accepted(accepted))
        XCTAssertNil(owner.snapshot().failure)
        dependencies.publish(.accepted(accepted))

        XCTAssertEqual(owner.snapshot().failure, .invalidResult)
        XCTAssertEqual(owner.snapshot().command, .unavailable)
        XCTAssertNil(owner.snapshot().result)
    }

    func testRejectedSubmitAndRetryAreTypedAndFailClosed() throws {
        let first = try commandFixture(epoch: 9)
        let second = try commandFixture(epoch: 10)
        let submitDependencies = PresentationOwnerDependencies(
            fixture: first
        )
        submitDependencies.acceptSubmissions = false
        let submitOwner = makeOwner(submitDependencies)
        XCTAssertTrue(submitOwner.refresh())

        XCTAssertFalse(submitOwner.submit(.approveIncoming))
        XCTAssertEqual(
            submitOwner.snapshot().failure,
            .submissionRejected
        )
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
                .presentation(
                    submitOwner.snapshot(),
                    phase: submitDependencies.activationSnapshot.phase,
                    projection:
                        submitDependencies.activationSnapshot.projection
                ).errorText,
            "后台未接收操作；请根据最新状态重试。"
        )
        XCTAssertEqual(submitOwner.snapshot().command, .unavailable)
        submitDependencies.replace(with: second)
        XCTAssertTrue(submitOwner.refresh())
        XCTAssertNil(submitOwner.snapshot().failure)

        let retryDependencies = PresentationOwnerDependencies(
            fixture: first
        )
        let retryOwner = makeOwner(retryDependencies)
        XCTAssertTrue(retryOwner.refresh())
        XCTAssertTrue(retryOwner.submit(.disconnect))
        let submission = try XCTUnwrap(retryDependencies.submissions.first)
        retryDependencies.publish(.accepted(
            try acceptedResponse(for: submission.intent)
        ))
        retryDependencies.publish(.resultTimedOut)
        retryDependencies.acceptRetries = false

        XCTAssertFalse(retryOwner.retry())
        XCTAssertEqual(retryOwner.snapshot().failure, .retryRejected)
        XCTAssertEqual(
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy
                .presentation(
                    retryOwner.snapshot(),
                    phase: retryDependencies.activationSnapshot.phase,
                    projection:
                        retryDependencies.activationSnapshot.projection
                ).errorText,
            "后台未接收重试；请根据最新状态重试。"
        )
        XCTAssertEqual(retryOwner.snapshot().command, .unavailable)
        XCTAssertEqual(retryDependencies.commandIDCount, 1)
    }

    func testProductFactoryIsInertAndAppDispatchesOnlyValidatedRoutes()
        throws
    {
        let activationOwner = HostAgentBackgroundActivationOwner.makeProduct()
        let owner =
            HostAgentBackgroundHomeCommandPresentationOwner.makeProduct(
                activationOwner: activationOwner
            )
        XCTAssertEqual(owner.snapshot().generation, 0)
        XCTAssertEqual(owner.snapshot().command, .unavailable)
        XCTAssertEqual(activationOwner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ownerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundHomeCommandPresentationOwner.swift"
            ),
            encoding: .utf8
        )
        let readOnlySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy.swift"
            ),
            encoding: .utf8
        )
        let routingSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentHomeCommandRoutingPolicy.swift"
            ),
            encoding: .utf8
        )
        let dispatchSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentHomeCommandDispatchPolicy.swift"
            ),
            encoding: .utf8
        )
        for forbidden in [
            "import AppKit", "import SwiftUI", "HostControlClient",
            "UserDefaults", "SMAppService",
        ] {
            XCTAssertFalse(ownerSource.contains(forbidden), forbidden)
        }
        XCTAssertTrue(ownerSource.contains(
            "activationOwner.commandAvailabilitySnapshot()"
        ))
        XCTAssertTrue(ownerSource.contains("activationOwner.submitCommand("))
        XCTAssertTrue(ownerSource.contains("activationOwner.retryCommand("))
        XCTAssertFalse(readOnlySource.contains("HostControlClient"))
        XCTAssertFalse(readOnlySource.contains(".submit("))
        XCTAssertFalse(readOnlySource.contains(".retry("))
        XCTAssertFalse(routingSource.contains("HostControlClient"))
        XCTAssertFalse(routingSource.contains(".submit("))
        XCTAssertFalse(routingSource.contains("retryCommand("))
        for forbidden in [
            "import AppKit", "import SwiftUI", "HostControlClient",
            "UserDefaults", "SMAppService",
        ] {
            XCTAssertFalse(dispatchSource.contains(forbidden), forbidden)
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
        XCTAssertEqual(appSource.components(
            separatedBy:
                "HostAgentBackgroundHomeCommandPresentationOwner.makeProduct("
        ).count - 1, 1)
        XCTAssertTrue(appSource.contains(
            "activationOwner: hostAgentBackgroundActivationOwner"
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy"
        ))
        XCTAssertTrue(appSource.contains(
            "dispatchHostHomeCommand(.perform("
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentHomeCommandRoutingPolicy.route("
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentHomeCommandDispatchPolicy.dispatch("
        ))
        XCTAssertEqual(
            appSource.components(separatedBy: ".submit(action)").count - 1,
            1
        )
        XCTAssertEqual(
            appSource.components(separatedBy: ".retry()").count - 1,
            1
        )
        XCTAssertTrue(appSource.contains(
            "approval.enabledActions.contains(.approve)"
        ))
        XCTAssertTrue(appSource.contains(
            "session.enabledActions.contains(.disconnect)"
        ))
        XCTAssertTrue(appSource.contains(
            "dispatchHostHomeCommand(.retry("
        ))
        XCTAssertTrue(readOnlySource.contains(
            "availableActions: availableActions"
        ))
        XCTAssertTrue(readOnlySource.contains(
            "retryAction: retryAction"
        ))
        XCTAssertTrue(homeSource.contains(
            "onRetryHostCommand?(retry.connectionID)"
        ))
        XCTAssertFalse(homeSource.contains(
            "HostAgentBackgroundHomeCommandPresentationView"
        ))
        XCTAssertFalse(homeSource.contains(
            "HostAgentHomeCommandRoute"
        ))
    }

    private func commandRoute(
        request: HostAgentHomeCommandRequest,
        owner: HostAgentHomeCommandOwner,
        visible: HostAgentHomeCommandVisibleTargets,
        fixture: CommandFixture,
        commandView: HostAgentBackgroundHomeCommandPresentationView?,
        legacyCommandsAvailable: Bool = false
    ) -> HostAgentHomeCommandRoute {
        HostAgentHomeCommandRoutingPolicy.route(
            request: request,
            owner: owner,
            visibleTargets: visible,
            legacyCommandsAvailable: legacyCommandsAvailable,
            phase: fixture.activation.phase,
            projection: fixture.activation.projection,
            commandView: commandView
        )
    }

    private func connectionID(
        for action: HostAgentBackgroundHomeCommandAction
    ) -> String {
        switch action {
        case .approveIncoming, .rejectIncoming:
            return "host-a:pending-1"
        case .disableKeyboardAndMouse, .disableClipboard,
             .disableSystemAudio, .disconnect:
            return "host-a:session-1"
        }
    }

    private func makeOwner(
        _ dependencies: PresentationOwnerDependencies,
        observer:
            @escaping HostAgentBackgroundHomeCommandPresentationOwner.Observer
            = { _ in }
    ) -> HostAgentBackgroundHomeCommandPresentationOwner {
        HostAgentBackgroundHomeCommandPresentationOwner(
            observeActivation: { dependencies.activationSnapshot },
            observeAvailability: { dependencies.availabilitySnapshot },
            submit: { route, intent, callback in
                dependencies.submit(
                    route: route,
                    intent: intent,
                    observer: callback
                )
            },
            retry: { route, callback in
                dependencies.retry(route: route, observer: callback)
            },
            makeCommandID: { dependencies.nextCommandID() },
            observer: observer
        )
    }

    private func commandFixture(epoch: UInt64) throws -> CommandFixture {
        let projectionAuthority = HostAgentBackgroundProjectionAuthority()
        let binding = projectionAuthority.beginSession()
        let peer = try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
        binding.sink.publishInitialSnapshot(
            try commandSnapshot(),
            peerIdentity: peer,
            transition: .firstObservation
        )
        let projection = projectionAuthority.snapshot()
        let healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        healthAuthority.acceptProjection(projection)
        let phase = HostAgentBackgroundActivationPhase.monitoring(
            epoch: epoch,
            readiness: healthAuthority.snapshot()
        )
        return CommandFixture(
            activation:
                HostAgentBackgroundHomeCommandActivationSnapshot(
                    phase: phase,
                    projection: projection
                ),
            route: HostAgentBackgroundCommandRoute(
                activationEpoch: epoch,
                projectionGeneration: projection.generation,
                reconnectRoute: HostAgentXPCReconnectCommandRoute(
                    sessionGeneration: epoch,
                    peerIdentity: peer
                )
            )
        )
    }

    private func commandSnapshot()
        throws -> HostAgentXPCWireSnapshotResponse
    {
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
        let capabilities = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
            "writeClipboard", "hearSystemAudio",
        ]
        let active: [String: Any] = [
            "connectionId": "host-a:session-1",
            "remoteId": "remote-2",
            "remoteName": "MBP",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 30,
            "initialCapabilities": capabilities,
            "activeCapabilities": capabilities,
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ]
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 7,
                    "hostInstanceId": "host-a",
                    "hostState": "ready",
                    "localId": "123456789",
                    "sessionAvailability": "available",
                    "sessionUnavailableReason": NSNull(),
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
    let activation: HostAgentBackgroundHomeCommandActivationSnapshot
    let route: HostAgentBackgroundCommandRoute
}

private final class PresentationOwnerDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var activation: HostAgentBackgroundHomeCommandActivationSnapshot
    private var availability: HostAgentBackgroundCommandAvailability
    private var submitted:
        [HostAgentBackgroundHomeCommandSubmission] = []
    private var observers: [HostAgentXPCSnapshotClient.CommandObserver] = []
    private var retained: HostAgentXPCCommandIntent?
    private var observations = 0
    private var identifiers = 0
    private var retries = 0
    var acceptSubmissions = true
    var acceptRetries = true

    init(fixture: CommandFixture) {
        activation = fixture.activation
        availability = .available(route: fixture.route, state: .idle)
    }

    var activationSnapshot:
        HostAgentBackgroundHomeCommandActivationSnapshot
    {
        locked {
            observations += 1
            return activation
        }
    }

    var availabilitySnapshot: HostAgentBackgroundCommandAvailability {
        locked { availability }
    }

    var observationCount: Int { locked { observations } }
    var commandIDCount: Int { locked { identifiers } }
    var retryCount: Int { locked { retries } }
    var observerCount: Int { locked { observers.count } }
    var submissions: [HostAgentBackgroundHomeCommandSubmission] {
        locked { submitted }
    }
    var retainedIntent: HostAgentXPCCommandIntent? { locked { retained } }

    func nextCommandID() -> String {
        locked {
            identifiers += 1
            return "command-\(identifiers)"
        }
    }

    func submit(
        route: HostAgentBackgroundCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        locked {
            guard acceptSubmissions,
                  availability == .available(route: route, state: .idle)
            else { return false }
            let submission = HostAgentBackgroundHomeCommandSubmission(
                route: route,
                intent: intent
            )
            submitted.append(submission)
            retained = intent
            observers.append(observer)
            availability = .available(route: route, state: .pausing(intent))
            return true
        }
    }

    func retry(
        route: HostAgentBackgroundCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        locked {
            guard acceptRetries,
                  let retained,
                  availability == .available(
                    route: route,
                    state: .retryable(retained)
                  )
            else { return false }
            retries += 1
            observers.append(observer)
            availability = .available(
                route: route,
                state: .pausing(retained)
            )
            return true
        }
    }

    func publish(_ result: HostAgentXPCSnapshotClientCommandResult) {
        let observer: HostAgentXPCSnapshotClient.CommandObserver? = locked {
            guard let observer = observers.last,
                  case .available(let route, _) = availability,
                  let retained
            else { return nil }
            updateAvailability(
                for: result,
                route: route,
                intent: retained
            )
            return observer
        }
        observer?(result)
    }

    func publishForeignAccepted(
        _ accepted: HostAgentXPCWireCommandAcceptedResponse
    ) {
        let observer: HostAgentXPCSnapshotClient.CommandObserver? = locked {
            guard let observer = observers.last,
                  case .available(let route, _) = availability,
                  let retained
            else { return nil }
            availability = .available(
                route: route,
                state: .awaitingResult(retained)
            )
            return observer
        }
        observer?(.accepted(accepted))
    }

    func publishLate(
        index: Int,
        result: HostAgentXPCSnapshotClientCommandResult
    ) {
        let observer = locked {
            observers.indices.contains(index) ? observers[index] : nil
        }
        observer?(result)
    }

    func replace(with fixture: CommandFixture) {
        locked {
            activation = fixture.activation
            availability = .available(route: fixture.route, state: .idle)
            retained = nil
        }
    }

    private func updateAvailability(
        for result: HostAgentXPCSnapshotClientCommandResult,
        route: HostAgentBackgroundCommandRoute,
        intent: HostAgentXPCCommandIntent
    ) {
        switch result {
        case .accepted:
            availability = .available(
                route: route,
                state: .awaitingResult(intent)
            )
        case .completed, .invalidRequest:
            availability = .available(route: route, state: .idle)
        case .resultUnknown, .resultTimedOut:
            availability = .available(
                route: route,
                state: .retryable(intent)
            )
        case .invalidResponse, .disconnected, .acceptanceTimedOut,
             .cancelled, .invalidState:
            availability = .unavailable
        }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PresentationOwnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage:
        [HostAgentBackgroundHomeCommandPresentationView] = []

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

private final class PresentationOwnerLockedValue<Value>:
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

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
