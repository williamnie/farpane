#!/usr/bin/env python3
"""Audit and freeze the section 15.2 item 7 recovery evidence boundary."""

from __future__ import annotations

import json
import sys
from pathlib import Path


SCHEMA = "farpane-host-performance-recovery-evidence-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "sampler": repository / "Scripts/sample-farpane-host-performance.sh",
        "validator": repository / "Scripts/validate-farpane-host-performance.py",
        "matrix": repository / "Scripts/validate-farpane-host-performance-matrix.py",
        "runtime_evidence": (
            repository / "Sources/VideoPipeline/HostRuntimeStateEvidence.swift"
        ),
        "media_evidence": (
            repository / "Sources/VideoPipeline/HostMediaTelemetryEvidence.swift"
        ),
        "sleep_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentSleepWakeRecoveryProcessOwner.swift"
        ),
        "network_composition": (
            repository
            / "Sources/RustDeskNative/HostAgentNetworkPathRecoveryComposition.swift"
        ),
        "network_poller": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryPollingOwner.swift"
        ),
        "display_audit": (
            repository / "Scripts/audit-host-display-reconfigure-contract.py"
        ),
        "host_snapshot": repository / "Sources/CoreBridge/HostControlClient.swift",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    sampler = sources["sampler"]
    validator = sources["validator"]
    matrix = sources["matrix"]
    runtime_evidence = sources["runtime_evidence"]
    media_evidence = sources["media_evidence"]
    sleep_owner = sources["sleep_owner"]
    network_composition = sources["network_composition"]
    network_poller = sources["network_poller"]
    display_audit = sources["display_audit"]
    host_snapshot = sources["host_snapshot"]

    evidence = {
        "samplerAdmitsRecoveryButDoesNotDefineTransitionProof": (
            "|recovery|battery-idle|" in sampler
            and '"recovery"' not in validator
        ),
        "baseMatrixExplicitlyLeavesItemSevenOpen": (
            '"coveredSection15_2Items": [1, 2, 3, 4, 5, 6, 8]'
            in matrix
            and '"uncoveredSection15_2Items": [7, 9, 10]'
            in matrix
        ),
        "sleepWakeHasExactEpochAndAuthoritativeReadyPublication": all(
            marker in sleep_owner
            for marker in (
                "publishSuspending: { epoch in",
                "publishRecoverySnapshot(",
                "recoveryStatus: .suspending",
                "publishAvailable: { epoch in",
                "recoveryStatus: .running",
                'registrationStatus: "ready"',
            )
        ) and all(
            marker in host_snapshot
            for marker in (
                "public let recoveryEpoch: UInt64",
                "public let recoveryStatus: HostRecoveryStatus",
            )
        ),
        "networkPathHasExactGenerationAndAuthoritativeConvergence": all(
            marker in network_composition
            for marker in (
                "pathGeneration, _ in",
                "pathGeneration: pathGeneration",
                "lifetime.recoverNetworkPath(",
                "return .snapshot(try lifetime.copySnapshot())",
                "snapshotCoordinator.requestPoll()",
            )
        ) and all(
            marker in network_poller
            for marker in (
                "snapshot.recoveryEpoch == recoveryEpoch",
                "snapshot.recoveryStatus == .running",
                'case ("ready", "ready"):',
                "return .converged",
            )
        ),
        "displayRecoveryHasPinnedAuthorityAndFreshRouteIdentity": all(
            marker in display_audit
            for marker in (
                '"authoritativeOwner": "pinned RustDesk monitor video service"',
                '"rebuildTrigger": "display-info inequality -> SWITCH"',
                '"replacementFreshness": "new connectionEpoch and codecEpoch"',
                '"realDisplayReconfigureStillRequiresInstalledMacAcceptance": True',
            )
        ),
        "runtimeStateDoesNotExposeRecoveryCorrelation": (
            'schema: "farpane-host-runtime-state"' in runtime_evidence
            and "schemaVersion: 2" in runtime_evidence
            and "recoveryEpoch" not in runtime_evidence
            and "recoveryStatus" not in runtime_evidence
            and "pathGeneration" not in runtime_evidence
            and "displayRevision" not in runtime_evidence
        ),
        "mediaTelemetryIsSanitizedButCannotProveRecoveryKind": (
            'static let schemaName = "farpane-media-telemetry"'
            in media_evidence
            and "let reconfigure: DropMetric" in media_evidence
            and "recoveryKind" not in media_evidence
            and "recoverySequence" not in media_evidence
            and "displayRevision" not in media_evidence
            and "connectionEpoch" not in media_evidence
            and "codecEpoch" not in media_evidence
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "samplerRecoveryAdmission": line_number(
            sampler, "|recovery|battery-idle|"
        ),
        "baseMatrixUncoveredItems": line_number(
            matrix, '"uncoveredSection15_2Items": [7, 9, 10]'
        ),
        "sleepWakePublication": line_number(
            sleep_owner, "publishSuspending: { epoch in"
        ),
        "networkGeneration": line_number(
            network_composition, "pathGeneration, _ in"
        ),
        "networkConvergence": line_number(
            network_poller, "snapshot.recoveryEpoch == recoveryEpoch"
        ),
        "displayAuthority": line_number(
            display_audit,
            '"authoritativeOwner": "pinned RustDesk monitor video service"',
        ),
        "runtimeEvidenceSchema": line_number(
            runtime_evidence, 'schema: "farpane-host-runtime-state"'
        ),
        "mediaEvidenceSchema": line_number(
            media_evidence, 'static let schemaName = "farpane-media-telemetry"'
        ),
    }

    target_contract = {
        "transitionEvidence": {
            "schema": "farpane-host-recovery-transition",
            "schemaVersion": 1,
            "requiredKinds": [
                "sleepWake",
                "networkPath",
                "displayReconfigure",
            ],
            "commonFields": [
                "sequence",
                "kind",
                "acceptedAt",
                "completedAt",
                "status",
                "hostInstanceScope",
                "buildIdentity",
            ],
            "authorityCorrelation": {
                "sleepWake": [
                    "recoveryEpoch",
                    "runningReadyConvergence",
                ],
                "networkPath": [
                    "pathGeneration",
                    "recoveryEpoch",
                    "runningReadyConvergence",
                ],
                "displayReconfigure": [
                    "previousDisplayRevision",
                    "replacementDisplayRevision",
                    "freshConnectionEpoch",
                    "freshCodecEpoch",
                ],
            },
        },
        "repetitionManifest": {
            "schema": "farpane-host-performance-recovery-manifest",
            "schemaVersion": 1,
            "requiredTransitionCount": 3,
            "requiredPostRecoveryScenario": "1080p30",
            "minimumPostRecoveryDurationSeconds": 600,
            "requiredRunCount": 3,
            "requiresSameMachineBuildAndHostScope": True,
            "requiresCompletedTransitionBeforeRun": True,
            "requiresSHA256SourceBinding": True,
            "rejectsPathEscapeSymlinkDuplicateAndOverwrite": True,
        },
        "forbiddenInference": [
            "scenario-name-only",
            "generic-disconnect-or-route-absence",
            "media-reconfigure-drop-count",
            "unbound-snapshot-ready-state",
        ],
    }

    remaining_boundary = {
        "sharedRecoveryEvidenceSchemaStillRequiresImplementation": True,
        "recoveryManifestValidatorStillRequiresImplementation": True,
        "allThreeTransitionsRequireInstalledMacExecution": True,
        "eachRecoveryRequiresFreshTenMinuteScenarioThreeRun": True,
        "noSection15_2ItemSevenPassIsClaimed": True,
        "batteryAndCombinedRoleEvidenceRemainSeparate": True,
    }
    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "checkpoint-required" if not missing else "contract-drift",
        "section15_2Item": 7,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "targetContract": target_contract,
        "remainingBoundary": remaining_boundary,
    }
    print(json.dumps(document, sort_keys=True, separators=(",", ":")))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
