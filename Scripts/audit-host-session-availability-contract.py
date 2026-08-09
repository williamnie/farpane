#!/usr/bin/env python3
"""Freeze H5.2 top-level active-Aqua availability and UI contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SCHEMA = "farpane-host-session-availability-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def version(pattern: str, source: str, label: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing {label}")
    return int(match.group(1))


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def section(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset <= start_offset:
        return ""
    return source[start_offset:end_offset]


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "service": repository / "Vendor/rustdesk/src/server/service.rs",
        "client": repository / "Sources/CoreBridge/HostControlClient.swift",
        "snapshot_state": (
            repository / "Sources/CoreBridge/HostAgentSnapshotState.swift"
        ),
        "event_state": (
            repository / "Sources/CoreBridge/HostAgentEventState.swift"
        ),
        "xpc_snapshot": (
            repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
        ),
        "xpc_event": (
            repository / "Sources/CoreBridge/HostAgentXPCWireEvent.swift"
        ),
        "readiness": (
            repository / "Sources/CoreBridge/HostAgentBackgroundReadinessPolicy.swift"
        ),
        "home_readiness": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundHomeReadinessPresentationPolicy.swift"
        ),
        "home_snapshot": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundHomeSnapshotProjectionPolicy.swift"
        ),
        "projection": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundProjectionAuthority.swift"
        ),
        "health": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundHealthAuthority.swift"
        ),
        "command": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundCommandRoute.swift"
        ),
        "home_command": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundHomeCommandPolicy.swift"
        ),
        "activation": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundActivationOwner.swift"
        ),
        "presentation": (
            repository / "Sources/CoreBridge/HostApplicationLifecyclePolicy.swift"
        ),
        "media": (
            repository
            / "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        ),
        "route_owner": (
            repository
            / "Sources/VideoPipeline/HostMediaPipelineRouteOwner.swift"
        ),
        "polling": (
            repository
            / "Sources/RustDeskNative/HostAgentSnapshotPollingOwner.swift"
        ),
        "process": repository / "Sources/RustDeskNative/HostAgentProcess.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home_view": repository / "Sources/RustDeskNative/HomeView.swift",
        "design": repository / "docs/host-mode-design.md",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        rust_abi = version(
            r"const HOST_ABI_VERSION: u32 = (\d+);",
            sources["bridge"],
            "Rust Host ABI version",
        )
        header_abi = version(
            r"#define RDN_HOST_ABI_VERSION (\d+)u",
            sources["header"],
            "C Host ABI version",
        )
        snapshot_schema = version(
            r"const SNAPSHOT_SCHEMA_VERSION: u32 = (\d+);",
            sources["bridge"],
            "Host snapshot schema version",
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    patch = sources["patch"]
    snapshot_json = section(
        sources["bridge"],
        "fn snapshot_json(&mut self) -> Value",
        "fn now_unix_millis",
    )
    client_snapshot = section(
        sources["client"],
        "public struct HostCoreSnapshot",
        "public enum HostSessionInputAvailability",
    )
    component_health = section(
        sources["readiness"],
        "package struct HostAgentBackgroundComponentHealth",
        "package var isReady",
    )
    background_home = section(
        sources["app"],
        "private func backgroundHostActiveSessionHomeSnapshot(",
        "private func backgroundHostCommandRetryHomeSnapshot(",
    )

    current_evidence = {
        "hostABIV12AndSnapshotV8PreserveSessionAvailability": (
            rust_abi == 12 and header_abi == 12 and snapshot_schema == 8
        ),
        "rustActiveAquaAuthorityFailsClosed": all(
            marker in patch
            for marker in (
                "fn active_aqua_session_from_flags(",
                "pub fn is_active_aqua_session() -> bool",
                '"kCGSSessionOnConsoleKey"',
                '"kCGSessionLoginDoneKey"',
                '"CGSSessionScreenIsLocked"',
                "_ => return false",
            )
        ),
        "finalInputAdapterAlreadyRechecksTheSameAuthority": all(
            marker in patch
            for marker in (
                "native_host_platform_input_authorities() -> (bool, bool)",
                "native_host_platform_input_permission_allows(configured: bool)",
                "&& active_aqua_session",
                "input_adapter_gate_allows(gate)",
            )
        ),
        "activeSessionAlreadyCarriesLimitedSessionUnavailable": (
            all(
                marker in sources["bridge"]
                for marker in (
                    "NativeSessionInputUnavailableReason::SessionUnavailable",
                    'Self::SessionUnavailable => "sessionUnavailable"',
                    'Self::Limited(_) => "limited"',
                    '"inputAvailability": self.input_availability.name()',
                    '"inputUnavailableReason": self.input_availability.reason()',
                )
            )
            and all(
                marker in sources["client"]
                for marker in (
                    "case limited",
                    "case sessionUnavailable",
                    "(.limited, .sessionUnavailable, false)",
                )
            )
        ),
        "connectionTimerPublishesPlatformTransitions": (
            all(
                marker in patch
                for marker in (
                    "second_timer.tick()",
                    "sync_native_host_platform_input_permission_transition().await",
                    "sync_native_session_capabilities();",
                    "native_host_update_session_capabilities(",
                )
            )
            and 'emit_bound_event(&binding, "snapshotChanged", json!({}));'
                in sources["bridge"]
        ),
        "legacyInProcessUIAndMediaHaveALocalAquaOverride": all(
            marker in sources["app"]
            for marker in (
                "HostActiveAquaSessionAuthority.currentSessionIsAvailable()",
                "syncHostMediaCaptureAvailability(",
                "suspendHostMediaPipelineForSessionUnavailable()",
                "HostSessionPresentationPolicy.presentation(",
            )
        ),
        "nativeMediaRejectsAndRetiresUnavailableSession": (
            patch.count(
                "!crate::rdn_host_bridge::native_host_session_is_available()"
            ) >= 2
            and 'bail!("native host session is unavailable")' in patch
            and "let route = NativeRouteGuard(route);" in patch
            and "if !native_host_session_is_available() {"
                in sources["bridge"]
            and "post-transition payload copies or queue insertion"
                in sources["bridge"]
        ),
        "topLevelHostSnapshotTupleIsStrictAndInternallyProjected": (
            all(
                marker in snapshot_json
                for marker in (
                    "native_host_session_availability_payload(",
                    'map.insert("sessionAvailability"',
                    '"sessionUnavailableReason".into()',
                )
            )
            and all(
                marker in client_snapshot
                for marker in (
                    'intValue == 8',
                    'json["sessionAvailability"] as? String',
                    'json["sessionUnavailableReason"]',
                    'case (.available, nil), (.limited, .sessionUnavailable):',
                )
            )
            and all(
                marker in sources["snapshot_state"]
                for marker in (
                    "package let sessionAvailability: HostSessionAvailability",
                    "package let sessionUnavailableReason: HostSessionUnavailableReason?",
                    "sessionAvailability = snapshot.sessionAvailability",
                    "sessionUnavailableReason = snapshot.sessionUnavailableReason",
                )
            )
        ),
        "xpcPublishesStrictTopLevelSessionTuple": (
            all(
                marker in sources["xpc_snapshot"]
                for marker in (
                    "schemaVersion: 8",
                    "package let sessionAvailability: HostSessionAvailability",
                    "package let sessionUnavailableReason: HostSessionUnavailableReason?",
                    "case (.available, nil), (.limited, .sessionUnavailable):",
                    '"sessionAvailability": sessionAvailability.rawValue',
                    '"sessionUnavailableReason": sessionUnavailableReason?.rawValue',
                )
            )
        ),
        "backgroundProjectionDerivesTypedSessionEvidence": (
            all(
                marker in sources["projection"]
                for marker in (
                    "package var sessionStatus: HostAgentBackgroundSessionStatus",
                    "case (.available, nil):",
                    "case (.limited, .sessionUnavailable):",
                    "return .limitedSessionUnavailable",
                )
            )
            and "session: projection.sessionStatus" in sources["health"]
        ),
        "backgroundReadinessWithdrawsReadyForLimitedSession": (
            all(
                marker in component_health
                for marker in (
                    "registration: HostAgentBackgroundRegistrationStatus",
                    "handshake: HostAgentBackgroundHandshakeStatus",
                    "snapshot: HostAgentBackgroundSnapshotStatus",
                    "session: HostAgentBackgroundSessionStatus",
                    "rendezvous: HostAgentBackgroundRendezvousStatus",
                    "case .limitedSessionUnavailable:",
                    "return .sessionUnavailable",
                    "return .ready",
                )
            )
            and "session == .unavailable" in component_health
            and "session != .unavailable" in component_health
            and "锁屏、登录窗口或其他用户会话暂不支持"
                in sources["home_readiness"]
            and 'statusText: "可被连接"' in sources["home_readiness"]
            and "isReady: true" in sources["home_readiness"]
        ),
        "limitedHomeHidesApprovalAndRetainsSession": (
            "payload.sessionAvailability == .available"
                in sources["home_snapshot"]
            and "pendingApproval: pendingApproval" in sources["home_snapshot"]
            and "activeSession: payload.activeSession" in sources["home_snapshot"]
        ),
        "limitedCommandPolicyAllowsOnlyExactDisconnect": (
            all(
                marker in sources["command"]
                for marker in (
                    "package enum HostAgentBackgroundSessionCommandPolicy",
                    "case (.limited, .sessionUnavailable):",
                    "return name == .disconnectSession",
                    "payload.activeSession?.connectionID == connectionID",
                )
            )
            and "HostAgentBackgroundSessionCommandPolicy.allows("
                in sources["home_command"]
            and "if payload.sessionAvailability == .limited"
                in sources["home_command"]
            and "HostAgentBackgroundSessionCommandPolicy.allows("
                in sources["activation"]
        ),
        "detailedHomeLimitedPresentationConsumesTopLevelTuple": (
            all(
                marker in sources["presentation"]
                for marker in (
                    "sessionAvailability: HostSessionAvailability",
                    "sessionUnavailableReason: HostSessionUnavailableReason?",
                    "case (.limited, .sessionUnavailable):",
                    "inputUnavailableReason != .sessionUnavailable",
                    "inputAvailability == .limited",
                    "inputUnavailableReason == .sessionUnavailable",
                    "当前版本不支持在锁屏、登录窗口或其他用户会话中远程操作",
                    "画面采集已暂停，远程键盘与鼠标不可用",
                )
            )
            and all(
                marker in sources["home_snapshot"]
                for marker in (
                    "activeSessionPresentation: HostSessionInputPresentation?",
                    "allowsSessionMutationCommands: Bool",
                    "sessionAvailability: payload.sessionAvailability",
                    "sessionUnavailableReason: payload.sessionUnavailableReason",
                )
            )
            and "backgroundSnapshot.activeSessionPresentation"
                in background_home
            and background_home.count(
                "backgroundSnapshot.allowsSessionMutationCommands"
            ) == 3
            and "HostActiveAquaSessionAuthority" not in background_home
            and "button.isHidden = !capabilityAvailable"
                in sources["home_view"]
        ),
        "periodicAgentPollPublishesBoundedSemanticSessionTransition": (
            all(
                marker in sources["polling"]
                for marker in (
                    "repeating: .milliseconds(500)",
                    "snapshotCoordinator.requestPoll()",
                )
            )
            and all(
                marker in sources["snapshot_state"]
                for marker in (
                    "publishSessionTransitionIfNeeded(",
                    "previous.sessionAvailability != snapshot.sessionAvailability",
                    "eventState.ingestSnapshotChanged(",
                    "eventSequence: sequence",
                )
            )
            and all(
                marker in sources["event_state"]
                for marker in (
                    "case snapshotChanged(sentAtUnixMilliseconds: UInt64)",
                    "package func ingestSnapshotChanged(",
                    "evictIfNeededLocked()",
                )
            )
            and all(
                marker in sources["xpc_event"]
                for marker in (
                    "case .snapshotChanged(let sentAtUnixMilliseconds):",
                    "payload: .snapshotChanged",
                )
            )
            and all(
                marker in sources["process"]
                for marker in (
                    "HostAgentSnapshotRefreshCoordinator(",
                    "eventState: eventState",
                )
            )
        ),
        "sameSessionInputRecoveryRevalidatesTCCAndLatchesRevocation": (
            all(
                marker in patch
                for marker in (
                    "struct NativeHostPlatformInputState",
                    "accessibility_latched: bool",
                    "aqua_restore_armed: bool",
                    "native_host_platform_input_authorities()",
                    "sync_native_host_platform_input_permission_transition().await",
                    "self.accessibility_latched = false;",
                    "if !self.accessibility_latched",
                    "native_host_platform_input_state_separates_aqua_recovery_from_tcc_latch",
                )
            )
        ),
        "nativeMediaRecoveryRetryIsBounded": all(
            marker in sources["service"]
            for marker in (
                "let mut error_timeout = HIBERNATE_TIMEOUT;",
                "error_timeout *= 2;",
                "if error_timeout > MAX_ERROR_TIMEOUT",
                "error_timeout = MAX_ERROR_TIMEOUT;",
                "thread::sleep(time::Duration::from_millis(error_timeout));",
            )
        ),
        "limitedRouteRetiresBeforeFreshFailClosedEpoch": (
            all(
                marker in patch
                for marker in (
                    "struct NativeRouteGuard",
                    "native_media_end_route(&self.0);",
                    "let route = NativeRouteGuard(route);",
                    'bail!("native host session is unavailable")',
                )
            )
            and all(
                marker in sources["bridge"]
                for marker in (
                    "fn next_native_media_epoch(counter: &AtomicU64) -> Option<u64>",
                    "current.checked_add(1)",
                    'ok_or("native media connection epoch is exhausted")',
                    'ok_or("native media codec epoch is exhausted")',
                    '"command": "startCapture"',
                    '"command": "stopCapture"',
                    "native_media_epoch_is_monotonic_and_exhaustion_safe",
                )
            )
        ),
        "swiftReplacementDrainsOldRouteAndRejectsLateCallbacks": all(
            marker in sources["route_owner"]
            for marker in (
                "generation == operationGeneration",
                "stopCurrentOnQueue(matching: nil)",
                "current?.generation == callbackGeneration",
                "current?.route == route",
                "current.pipeline.cancel()",
                "blockingStop(current.pipeline)",
            )
        ),
        "designRequiresTopLevelLimitedAndUnsupportedUI": all(
            marker in sources["design"]
            for marker in (
                "Host 进入 `limited/sessionUnavailable`",
                "暂停采集或只保留有界恢复信令",
                "权威降级为 unsupported/limited",
                "不因 launchd 进程存在伪装 ready",
            )
        ),
    }
    missing = [name for name, present in current_evidence.items() if not present]

    target_contract = {
        "hostABIVersion": 12,
        "snapshotSchemaVersion": 8,
        "topLevelTuple": {
            "available": {
                "sessionAvailability": "available",
                "sessionUnavailableReason": None,
            },
            "limited": {
                "sessionAvailability": "limited",
                "sessionUnavailableReason": "sessionUnavailable",
            },
        },
        "singleAuthority": "pinned Rust active Aqua CGSession policy",
        "transitionSequence": [
            "observeStrictAquaTupleWithoutPrompt",
            "retireOrRejectNativeMediaRouteWhileLimited",
            "publishSchema8SnapshotTransition",
            "propagateThroughAgentSnapshotAndXPCResnapshot",
            "withdrawBackgroundReadyAndApprovalActions",
            "presentUnsupportedLimitedWithDisconnectOnlyForExistingSession",
            "onSameSessionRecoveryRevalidateTCCAndUseFreshMediaEpochs",
        ],
        "forbiddenSideEffects": [
            "inputInjectionWhileLimited",
            "captureOrEncodedSubmissionWhileLimited",
            "localSwiftAuthorityOverridingRustTuple",
            "readyDerivedFromLaunchAgentOrRegistrationAlone",
            "approvalOrNewControlActionsWhileLimited",
            "automaticTCCPrompt",
            "identityPasswordOrServerConfigurationMutation",
        ],
    }
    source_lines = {
        "rustAquaPolicy": line_number(patch, "fn active_aqua_session_from_flags("),
        "inputTransitionPoll": line_number(
            patch,
            "sync_native_host_platform_input_permission_transition().await",
        ),
        "snapshotJSON": line_number(
            sources["bridge"],
            "fn snapshot_json(&mut self) -> Value",
        ),
        "nativeMediaGate": line_number(
            patch,
            "!crate::rdn_host_bridge::native_host_session_is_available()",
        ),
        "swiftSnapshot": line_number(
            sources["client"],
            "public struct HostCoreSnapshot",
        ),
        "backgroundReadiness": line_number(
            sources["readiness"],
            "package struct HostAgentBackgroundComponentHealth",
        ),
        "backgroundSessionProjection": line_number(
            sources["projection"],
            "package var sessionStatus: HostAgentBackgroundSessionStatus",
        ),
        "backgroundSessionCommandPolicy": line_number(
            sources["command"],
            "package enum HostAgentBackgroundSessionCommandPolicy",
        ),
        "backgroundHome": line_number(
            sources["app"],
            "private func backgroundHostActiveSessionHomeSnapshot(",
        ),
        "backgroundHomeSessionPresentation": line_number(
            sources["home_snapshot"],
            "activeSessionPresentation: HostSessionInputPresentation?",
        ),
        "homeCapabilityButtonVisibility": line_number(
            sources["home_view"],
            "button.isHidden = !capabilityAvailable",
        ),
        "agentPoll": line_number(
            sources["polling"],
            "repeating: .milliseconds(500)",
        ),
        "xpcSnapshotTuple": line_number(
            sources["xpc_snapshot"],
            "package let sessionAvailability: HostSessionAvailability",
        ),
        "agentSemanticTransition": line_number(
            sources["snapshot_state"],
            "publishSessionTransitionIfNeeded(",
        ),
        "inputTCCRecoveryLatch": line_number(
            patch,
            "native_host_platform_input_state_separates_aqua_recovery_from_tcc_latch",
        ),
        "boundedMediaServiceRetry": line_number(
            sources["service"],
            "let mut error_timeout = HIBERNATE_TIMEOUT;",
        ),
        "freshMediaEpochAllocator": line_number(
            sources["bridge"],
            "fn next_native_media_epoch(counter: &AtomicU64) -> Option<u64>",
        ),
        "swiftRouteGenerationIsolation": line_number(
            sources["route_owner"],
            "private func handleAccessUnit(",
        ),
    }

    document = {
        "schema": SCHEMA,
        "schemaVersion": 6,
        "status": (
            "same-session-recovery-ownership-verified"
            if not missing
            else "audit-drift"
        ),
        "implementation": {
            "hostABIVersion": rust_abi,
            "snapshotSchemaVersion": snapshot_schema,
            "evidence": current_evidence,
            "sourceLines": source_lines,
        },
        "targetContract": target_contract,
        "missingEvidence": missing,
        "remainingBoundary": {
            "sharedABINotImplementedByAudit": False,
            "backgroundMediaSuspensionNotImplementedByAudit": False,
            "xpcTransitionProjectionNotImplementedByAudit": False,
            "backgroundReadinessAndCommandWithdrawalNotImplementedByAudit": False,
            "detailedHomeLimitedPresentationStillRequired": False,
            "sameSessionRecoveryOwnershipStillRequired": False,
            "installedLockLoginWindowFUSAcceptanceStillRequired": True,
            "secureInputRemainsSeparateDecision": True,
        },
    }
    print(json.dumps(document, sort_keys=True))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
