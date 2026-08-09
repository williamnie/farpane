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
        "client": repository / "Sources/CoreBridge/HostControlClient.swift",
        "snapshot_state": (
            repository / "Sources/CoreBridge/HostAgentSnapshotState.swift"
        ),
        "xpc_snapshot": (
            repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
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
        "presentation": (
            repository / "Sources/CoreBridge/HostApplicationLifecyclePolicy.swift"
        ),
        "media": (
            repository
            / "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        ),
        "polling": (
            repository
            / "Sources/RustDeskNative/HostAgentSnapshotPollingOwner.swift"
        ),
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
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
        "hostABIV10AndSnapshotV7AreCurrent": (
            rust_abi == 10 and header_abi == 10 and snapshot_schema == 7
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
                    'intValue == 7',
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
        "xpcAndHomeDoNotYetPublishTopLevelSessionTuple": (
            "sessionAvailability" not in sources["xpc_snapshot"]
            and "sessionUnavailableReason" not in sources["xpc_snapshot"]
            and "sessionAvailability" not in sources["home_snapshot"]
            and "sessionUnavailableReason" not in sources["home_snapshot"]
        ),
        "backgroundReadinessCanStillBecomeReadyWithoutSessionEvidence": (
            all(
                marker in component_health
                for marker in (
                    "registration: HostAgentBackgroundRegistrationStatus",
                    "handshake: HostAgentBackgroundHandshakeStatus",
                    "snapshot: HostAgentBackgroundSnapshotStatus",
                    "rendezvous: HostAgentBackgroundRendezvousStatus",
                    "return .ready",
                )
            )
            and "session" not in component_health.lower()
            and 'statusText: "可被连接"' in sources["home_readiness"]
            and "isReady: true" in sources["home_readiness"]
        ),
        "backgroundHomeUsesOnlyNestedInputPresentation": (
            "HostSessionInputPresentationPolicy.presentation(" in background_home
            and "HostSessionPresentationPolicy.presentation(" not in background_home
            and "HostActiveAquaSessionAuthority" not in background_home
            and "画面采集已暂停" in sources["presentation"]
        ),
        "periodicAgentPollCopiesCoreButDoesNotPublishSessionTransition": (
            all(
                marker in sources["polling"]
                for marker in (
                    "repeating: .milliseconds(500)",
                    "snapshotCoordinator.requestPoll()",
                )
            )
            and "session" not in sources["polling"].lower()
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
        "hostABIVersion": 10,
        "snapshotSchemaVersion": 7,
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
            "publishSchema7SnapshotTransition",
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
        "backgroundHome": line_number(
            sources["app"],
            "private func backgroundHostActiveSessionHomeSnapshot(",
        ),
        "agentPoll": line_number(
            sources["polling"],
            "repeating: .milliseconds(500)",
        ),
    }

    document = {
        "schema": SCHEMA,
        "schemaVersion": 2,
        "status": "core-contract-implemented" if not missing else "audit-drift",
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
            "xpcTransitionProjectionNotImplementedByAudit": True,
            "installedLockLoginWindowFUSAcceptanceStillRequired": True,
            "secureInputRemainsSeparateDecision": True,
        },
    }
    print(json.dumps(document, sort_keys=True))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
