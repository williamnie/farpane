@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHomeReadinessPresentationPolicyTests:
    XCTestCase
{
    func testInactivePresentationUsesOnlyAuthoritativeRegistration() {
        XCTAssertEqual(
            presentation(phase: nil, registration: .notRegistered),
            expected("后台组件未注册")
        )
        XCTAssertEqual(
            presentation(phase: .disabled, registration: .requiresApproval),
            expected("等待系统允许后台组件")
        )
        XCTAssertEqual(
            presentation(phase: .terminated, registration: .enabled),
            expected("后台组件已注册，尚未开始状态观察")
        )
        XCTAssertEqual(
            presentation(phase: nil, registration: .serviceUnavailable),
            expected("后台组件注册状态不可用")
        )
    }

    func testStartingDoesNotClaimAgentRunningOrReady() {
        XCTAssertEqual(
            presentation(
                phase: .starting(epoch: 1),
                registration: .enabled
            ),
            expected("正在连接后台组件…", isBusy: true)
        )
    }

    func testMonitoringMapsEveryAvailabilityWithoutReadyInflation() {
        assertMonitoring(
            readiness(
                handshake: .disconnected,
                snapshot: .unavailable,
                rendezvous: .checking
            ),
            equals: expected("正在连接后台组件…", isBusy: true)
        )
        assertMonitoring(
            readiness(
                handshake: .incompatible,
                snapshot: .unavailable,
                rendezvous: .offline
            ),
            equals: expected(
                "后台组件版本不兼容",
                errorText: "后台组件版本与 FarPane 不兼容。"
            )
        )
        assertMonitoring(
            readiness(snapshot: .unavailable, rendezvous: .checking),
            equals: expected("正在同步后台状态…", isBusy: true)
        )
        assertMonitoring(
            readiness(rendezvous: .offline),
            equals: expected(
                "后台组件尚未连接服务器",
                isRunning: true
            )
        )
        assertMonitoring(
            readiness(session: .limitedSessionUnavailable),
            equals: expected(
                "当前 Mac 会话不可用",
                isRunning: true
            )
        )
        assertMonitoring(
            readiness(),
            equals: expected(
                "可被连接",
                isRunning: true,
                isReady: true
            )
        )
    }

    func testRegistrationAlwaysPrecedesHealthyRuntimeSignals() {
        assertMonitoring(
            readiness(registration: .notRegistered),
            equals: expected("后台组件未注册")
        )
        assertMonitoring(
            readiness(registration: .requiresApproval),
            equals: expected("等待系统允许后台组件")
        )
        assertMonitoring(
            readiness(registration: .serviceUnavailable),
            equals: expected("后台组件注册状态不可用")
        )
    }

    func testInvalidRuntimeEvidenceIsSanitizedAndNotRunning() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 1,
            handshake: .disconnected,
            snapshot: .available,
            session: .available,
            rendezvous: .registered
        ))

        assertMonitoring(
            authority.snapshot(),
            equals: expected(
                "后台组件状态无效",
                errorText: "后台组件状态证据不一致；已停止观察。"
            )
        )
    }

    func testActivationFailuresUseBoundedStablePresentation() {
        let cases: [(
            HostAgentBackgroundActivationFailure,
            HostAgentBackgroundHomeReadinessPresentation
        )] = [
            (
                .runtimeCreation,
                expected(
                    "无法连接后台组件",
                    errorText: "无法创建后台状态观察；可以稍后重试。"
                )
            ),
            (
                .runtimeStartRejected,
                expected(
                    "无法连接后台组件",
                    errorText: "后台状态观察未能启动；可以稍后重试。"
                )
            ),
            (
                .invalidHealthSequence,
                expected(
                    "后台组件状态无效",
                    errorText: "后台组件状态顺序不一致；已停止观察。"
                )
            ),
            (
                .runtimeHealthRejected,
                expected(
                    "后台组件状态无效",
                    errorText: "后台组件状态证据无效；已停止观察。"
                )
            ),
            (
                .generationExhausted,
                expected(
                    "后台组件状态不可用",
                    errorText: "后台状态计数已耗尽；请重新启动 FarPane。"
                )
            ),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(
                presentation(
                    phase: .failed(failure),
                    registration: .enabled
                ),
                expected
            )
        }
    }

    func testHomeSeparatesRunningReadyAndCommandAvailability() throws {
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
            "HostAgentBackgroundHomeReadinessPresentationPolicy.presentation("
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundActivationView = view"
        ))
        XCTAssertTrue(appSource.contains(
            ": hostReadiness.isReady"
        ))
        XCTAssertTrue(appSource.contains(
            "allowsHostCommands: usesLegacyHost && hostRuntimeActive"
        ))
        XCTAssertTrue(homeSource.contains("var isReady: Bool"))
        XCTAssertTrue(homeSource.contains("var allowsHostCommands: Bool"))
        XCTAssertTrue(homeSource.contains(
            "host.isReady || host.isStreaming"
        ))
        XCTAssertFalse(homeSource.contains(
            "host.statusText == \"可被连接\""
        ))
        XCTAssertEqual(homeSource.components(
            separatedBy: "snapshot.host.allowsHostCommands"
        ).count - 1, 4)
    }
}

private func presentation(
    phase: HostAgentBackgroundActivationPhase?,
    registration: HostAgentBackgroundRegistrationStatus
) -> HostAgentBackgroundHomeReadinessPresentation {
    HostAgentBackgroundHomeReadinessPresentationPolicy.presentation(
        phase: phase,
        registration: registration
    )
}

private func expected(
    _ statusText: String,
    errorText: String = "",
    isRunning: Bool = false,
    isReady: Bool = false,
    isBusy: Bool = false
) -> HostAgentBackgroundHomeReadinessPresentation {
    HostAgentBackgroundHomeReadinessPresentation(
        isRunning: isRunning,
        isReady: isReady,
        isBusy: isBusy,
        statusText: statusText,
        errorText: errorText
    )
}

private func readiness(
    registration: HostAgentBackgroundRegistrationStatus = .enabled,
    handshake: HostAgentBackgroundHandshakeStatus = .compatible,
    snapshot: HostAgentBackgroundSnapshotStatus = .available,
    session: HostAgentBackgroundSessionStatus? = nil,
    rendezvous: HostAgentBackgroundRendezvousStatus = .registered
) -> HostAgentBackgroundReadinessView {
    let authority = HostAgentBackgroundHealthAuthority(
        initialRegistration: registration,
        observeRegistration: { registration }
    )
    authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
        projectionGeneration: 1,
        handshake: handshake,
        snapshot: snapshot,
        session: session ?? (
            snapshot == .available ? .available : .unavailable
        ),
        rendezvous: rendezvous
    ))
    return authority.snapshot()
}

private func assertMonitoring(
    _ readiness: HostAgentBackgroundReadinessView,
    equals expected: HostAgentBackgroundHomeReadinessPresentation,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        presentation(
            phase: .monitoring(epoch: 1, readiness: readiness),
            registration: readiness.registration
        ),
        expected,
        file: file,
        line: line
    )
}
