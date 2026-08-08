@testable import CoreBridge
import XCTest

final class HostAgentBackgroundRegistrationPresentationPolicyTests:
    XCTestCase
{
    func testPromptPresentationDistinguishesPersistenceAndSystemApproval() {
        let persistence = presentation(for: persistencePromptView())
        XCTAssertEqual(persistence.statusText, "等待确认后台连接")
        XCTAssertEqual(persistence.errorText, "")
        XCTAssertEqual(persistence.tone, .attention)
        XCTAssertFalse(persistence.isBusy)

        let approval = presentation(for: approvalPromptView())
        XCTAssertEqual(approval.statusText, "等待系统授权")
        XCTAssertTrue(approval.errorText.contains("登录项与扩展"))
        XCTAssertEqual(approval.tone, .attention)
        XCTAssertTrue(approval.canRetry)
    }

    func testBusyPhasesUseProgressPresentationWithoutClaimingReady() {
        let expected: [
            (HostAgentBackgroundRegistrationUXPhase, String)
        ] = [
            (.preparingLegacyHost, "正在停止旧的被控端…"),
            (.registering, "正在注册后台组件…"),
            (.navigating, "正在打开登录项设置…"),
        ]

        for (phase, statusText) in expected {
            let output = presentation(for: view(phase))
            XCTAssertEqual(output.statusText, statusText)
            XCTAssertEqual(output.errorText, "")
            XCTAssertEqual(output.tone, .progress)
            XCTAssertTrue(output.isBusy)
            XCTAssertFalse(output.statusText.contains("可被连接"))
        }
    }

    func testMigrationBlockersKeepUserActionSemantics() {
        let activeSession = presentation(for: view(
            .migrationBlocked([.runtimeActive, .activeSession])
        ))
        XCTAssertEqual(activeSession.statusText, "后台连接尚未启用")
        XCTAssertTrue(activeSession.errorText.contains("远程会话"))

        let pendingApproval = presentation(for: view(
            .migrationBlocked([.runtimeActive, .pendingApproval])
        ))
        XCTAssertTrue(pendingApproval.errorText.contains("连接请求"))

        let residualOwnership = presentation(for: view(
            .migrationBlocked([.clientRetained])
        ))
        XCTAssertTrue(residualOwnership.errorText.contains("尚未完全停止"))

        for output in [activeSession, pendingApproval, residualOwnership] {
            XCTAssertEqual(output.tone, .attention)
            XCTAssertFalse(output.isBusy)
            XCTAssertTrue(output.canRetry)
        }
    }

    func testMigrationFailuresStaySanitizedAndDistinct() {
        let unavailable = presentation(for: view(
            .failed(.migration(.assessment(.evidenceUnavailable)))
        ))
        XCTAssertTrue(unavailable.errorText.contains("无法读取"))

        let inconsistent = presentation(for: view(
            .failed(.migration(.assessment(.inconsistentEvidence)))
        ))
        XCTAssertTrue(inconsistent.errorText.contains("状态不一致"))

        let stopFailure = presentation(for: view(
            .failed(.migration(.quiescenceRequestFailed))
        ))
        XCTAssertTrue(stopFailure.errorText.contains("无法确认"))
        XCTAssertTrue(stopFailure.errorText.contains("重新启动 FarPane"))

        for output in [unavailable, inconsistent, stopFailure] {
            XCTAssertEqual(output.statusText, "后台连接启用失败")
            XCTAssertEqual(output.tone, .failure)
            XCTAssertTrue(output.canRetry)
        }
    }

    func testRegistrationAndApprovalResultsDoNotClaimAgentReadiness() {
        let registered = presentation(for: view(
            .registered,
            registration: .enabled
        ))
        XCTAssertEqual(registered.statusText, "后台组件已注册")
        XCTAssertFalse(registered.statusText.contains("可被连接"))
        XCTAssertEqual(registered.tone, .success)

        let navigationRequested = presentation(for: view(
            .navigationRequested,
            registration: .requiresApproval
        ))
        XCTAssertEqual(navigationRequested.statusText, "等待系统授权")
        XCTAssertTrue(navigationRequested.errorText.contains("允许 FarPane"))
        XCTAssertEqual(navigationRequested.tone, .attention)

        let noLongerRequired = presentation(for: view(
            .approvalNoLongerRequired,
            registration: .enabled
        ))
        XCTAssertEqual(noLongerRequired.statusText, "后台组件已注册")
        XCTAssertFalse(noLongerRequired.isBusy)
    }

    func testRegistrationAndInternalFailuresUseBoundedCopy() {
        let buildFailure = presentation(for: view(
            .failed(.registration(.invalidCodeSignature))
        ))
        XCTAssertTrue(buildFailure.errorText.contains("当前构建"))

        let serviceFailure = presentation(for: view(
            .failed(.registration(.serviceUnavailable))
        ))
        XCTAssertTrue(serviceFailure.errorText.contains("后台组件状态"))

        let internalFailure = presentation(for: view(
            .failed(.invalidMigrationResult)
        ))
        XCTAssertTrue(internalFailure.errorText.contains("状态异常"))

        for output in [buildFailure, serviceFailure, internalFailure] {
            XCTAssertEqual(output.statusText, "后台连接启用失败")
            XCTAssertEqual(output.tone, .failure)
            XCTAssertFalse(output.isBusy)
            XCTAssertLessThanOrEqual(output.errorText.count, 64)
        }
    }

    func testIdleAndCancellationDoNotCreateErrors() {
        let idle = presentation(for: view(.idle))
        XCTAssertEqual(idle.statusText, "后台连接尚未启用")
        XCTAssertEqual(idle.errorText, "")
        XCTAssertEqual(idle.tone, .neutral)

        let cancelled = presentation(for: view(.cancelled))
        XCTAssertEqual(cancelled.statusText, "已取消后台连接设置")
        XCTAssertEqual(cancelled.errorText, "")
        XCTAssertEqual(cancelled.tone, .neutral)
    }

    func testAppOwnsLazyCompositionWithoutBeginningFlow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

        XCTAssertTrue(appSource.contains(
            "private lazy var hostAgentBackgroundRegistrationSheetDriver"
        ))
        XCTAssertTrue(appSource.contains(
            "private lazy var hostAgentBackgroundRegistrationMutationOwner"
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundRegistrationSheetDriver.makeProduct("
        ))
        XCTAssertTrue(appSource.contains(
            "mutationOwner: hostAgentBackgroundRegistrationMutationOwner"
        ))
        XCTAssertTrue(appSource.contains(
            "self?.prepareLegacyHostForBackgroundRegistration()"
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundRegistrationPresentationPolicy.presentation("
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundUnregistrationPresentation = nil"
        ))
        XCTAssertTrue(appSource.contains(
            "?? hostAgentBackgroundRegistrationPresentation?.statusText"
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundRegistrationPresentation?.errorText"
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundRegistrationSheetDriver.begin("
        ))
        XCTAssertFalse(homeSource.contains(
            "hostAgentBackgroundRegistrationSheetDriver"
        ))
        XCTAssertFalse(homeSource.contains(
            "HostAgentBackgroundRegistrationPresentationPolicy"
        ))
    }
}

private func presentation(
    for view: HostAgentBackgroundRegistrationUXView
) -> HostAgentBackgroundRegistrationPresentation {
    HostAgentBackgroundRegistrationPresentationPolicy.presentation(for: view)
}

private func view(
    _ phase: HostAgentBackgroundRegistrationUXPhase,
    registration: HostAgentBackgroundRegistrationStatus? = nil
) -> HostAgentBackgroundRegistrationUXView {
    HostAgentBackgroundRegistrationUXView(
        generation: 1,
        phase: phase,
        registration: registration
    )
}

private func persistencePromptView()
    -> HostAgentBackgroundRegistrationUXView
{
    let owner = promptOwner(registration: .enabled)
    _ = owner.apply(.requestBackgroundRegistration)
    return owner.snapshot()
}

private func approvalPromptView() -> HostAgentBackgroundRegistrationUXView {
    let owner = promptOwner(registration: .requiresApproval)
    _ = owner.apply(.requestBackgroundRegistration)
    _ = owner.apply(.confirmBackgroundRegistration)
    return owner.snapshot()
}

private func promptOwner(
    registration: HostAgentBackgroundRegistrationStatus
) -> HostAgentBackgroundRegistrationUXOwner {
    HostAgentBackgroundRegistrationUXOwner(
        performMigrationPreparation: {
            (
                true,
                HostAgentLegacyHostMigrationCoordinatorView(
                    phase: .readyForRegistration
                )
            )
        },
        performRegistration: {
            let phase: HostAgentBackgroundRegistrationMutationPhase =
                registration == .enabled ? .registered : .requiresApproval
            return (
                true,
                HostAgentBackgroundRegistrationMutationView(
                    generation: 1,
                    phase: phase,
                    registration: registration
                )
            )
        },
        performApprovalNavigation: {
            (
                false,
                HostAgentBackgroundApprovalNavigationView(
                    generation: 1,
                    phase: .notRequired,
                    registration: registration
                )
            )
        }
    )
}
