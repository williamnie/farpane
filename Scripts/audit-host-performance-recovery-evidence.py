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
        "sleep_core_owner": (
            repository
            / "Sources/CoreBridge/HostAgentSleepWakeRecoveryOwner.swift"
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
        "display_provenance_audit": (
            repository / "Scripts/audit-host-display-recovery-provenance.py"
        ),
        "display_evidence_owner": (
            repository
            / "Sources/VideoPipeline/HostDisplayReconfigureEvidenceOwner.swift"
        ),
        "media_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        ),
        "host_snapshot": repository / "Sources/CoreBridge/HostControlClient.swift",
        "recovery_writer": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidence.swift"
        ),
        "recovery_process_owner": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidenceProcessOwner.swift"
        ),
        "host_process": (
            repository / "Sources/RustDeskNative/HostAgentProcess.swift"
        ),
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
    sleep_core_owner = sources["sleep_core_owner"]
    network_composition = sources["network_composition"]
    network_poller = sources["network_poller"]
    display_audit = sources["display_audit"]
    display_provenance_audit = sources["display_provenance_audit"]
    display_evidence_owner = sources["display_evidence_owner"]
    media_owner = sources["media_owner"]
    host_snapshot = sources["host_snapshot"]
    recovery_writer = sources["recovery_writer"]
    recovery_process_owner = sources["recovery_process_owner"]
    host_process = sources["host_process"]

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
        "displayRecoveryHasPinnedAuthorityAndTypedFreshRouteIdentity": all(
            marker in display_audit
            for marker in (
                '"authoritativeOwner": "pinned RustDesk monitor video service"',
                '"rebuildTrigger": "display-info inequality -> SWITCH"',
                '"new connectionEpoch and codecEpoch; exact-next displayRevision "',
                '"realDisplayReconfigureStillRequiresInstalledMacAcceptance": True',
            )
        ) and all(
            marker in display_provenance_audit
            for marker in (
                '"status": "display-callback-implemented"',
                '"acceptedEventType": "mediaDisplayReconfigureStarted"',
                '"mustMatchAcceptedMarkerExactly": True',
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
        "sanitizedBoundedTransitionWriterImplemented": all(
            marker in recovery_writer
            for marker in (
                '"FARPANE_HOST_RECOVERY_OUTPUT"',
                "public static let maximumRecordCount: UInt64 = 128",
                'schema: "farpane-host-recovery-transition"',
                "schemaVersion: 1",
                "status: .completed",
                "hostInstanceScopeSHA256:",
                "buildIdentitySHA256:",
                "case .sleepWake(let recoveryEpoch):",
                "case .networkPath(let pathGeneration, let recoveryEpoch):",
                "case .displayReconfigure(",
                "let runningReadyConverged = true",
                "let freshRouteConverged = true",
                "replacementConnectionEpoch > previousConnectionEpoch",
                "replacementCodecEpoch > previousCodecEpoch",
                "completedMonotonicNanoseconds > acceptedMonotonicNanoseconds",
                "Data().write(to: standardizedURL, options: .withoutOverwriting)",
                "outputHandle = try FileHandle(forWritingTo: standardizedURL)",
                "try outputHandle.seekToEnd()",
            )
        ),
        "processLifetimeDigestAuthorityImplemented": (
            all(
                marker in recovery_process_owner
                for marker in (
                    "import CryptoKit",
                    '"farpane.host-recovery.scope.v1"',
                    '"farpane.host-recovery.build.v1"',
                    "maximumIdentityUTF8Bytes = 512",
                    "hasher.update(data: Data([0]))",
                    "HostRecoveryTransitionEvidenceWriter.configured(",
                    "status = configuredWriter == nil ? .disabled : .active",
                    "status = .unavailable",
                    "writer = nil",
                    "while configurationInFlight || sleepWakeAcceptanceInFlight",
                    "|| displayReconfigureAcceptanceInFlight || recordInFlight",
                )
            )
            and all(
                marker in host_process
                for marker in (
                    "HostRecoveryTransitionEvidenceProcessOwner()",
                    "_ = recoveryEvidenceOwner.configure(",
                    "hostInstanceID: hostInstanceID",
                    "buildIdentity: expectedAgentBuildID",
                    "recoveryEvidenceOwner.cancelAndWait()",
                )
            )
            and "guard recoveryEvidenceOwner.configure(" not in host_process
            and "FARPANE_HOST_RECOVERY_SCOPE_SHA256" not in recovery_writer
            and "FARPANE_HOST_RECOVERY_BUILD_SHA256" not in recovery_writer
        ),
        "sleepWakeTransitionCallbackConnected": (
            all(
                marker in sleep_core_owner
                for marker in (
                    "operations.recoveryAccepted(epoch)",
                    "with: .running(epoch: epoch)",
                    "operations.recoveryCompleted(epoch)",
                )
            )
            and sleep_core_owner.find("operations.recoveryAccepted(epoch)")
            < sleep_core_owner.find("operations.recoveryCompleted(epoch)")
            and all(
                marker in sleep_owner
                for marker in (
                    "recoveryEvidenceOwner.acceptSleepWake(",
                    "recoveryEvidenceOwner.recordSleepWakeCompleted(",
                )
            )
            and all(
                marker in recovery_process_owner
                for marker in (
                    "pendingSleepWakeAcceptance",
                    "sleepWakeAcceptanceInFlight",
                    "acceptSleepWake(recoveryEpoch: UInt64)",
                    "recordSleepWakeCompleted(recoveryEpoch: UInt64)",
                    "acceptance.recoveryEpoch == recoveryEpoch",
                    "correlation: .sleepWake(recoveryEpoch: recoveryEpoch)",
                )
            )
            and "recoveryEvidenceOwner: recoveryEvidenceOwner" in host_process
        ),
        "networkPathTransitionCallbackConnected": (
            all(
                marker in network_poller
                for marker in (
                    "recoveryAccepted(pathGeneration, recoveryEpoch)",
                    "let shouldRecordCompleted: Bool",
                    "shouldRecordCompleted = outcome == .converged",
                    "recoveryCompleted(pathGeneration, recoveryEpoch)",
                    "completionInFlight = false",
                )
            )
            and network_poller.find(
                "recoveryAccepted(pathGeneration, recoveryEpoch)"
            )
            < network_poller.find(
                "recoveryCompleted(pathGeneration, recoveryEpoch)"
            )
            and all(
                marker in network_composition
                for marker in (
                    "recoveryEvidenceOwner.acceptNetworkPath(",
                    "recoveryEvidenceOwner.recordNetworkPathCompleted(",
                )
            )
            and all(
                marker in recovery_process_owner
                for marker in (
                    "pendingNetworkPathAcceptance",
                    "networkPathAcceptanceInFlight",
                    "acceptNetworkPath(",
                    "recordNetworkPathCompleted(",
                    "acceptance.pathGeneration == pathGeneration",
                    "acceptance.recoveryEpoch == recoveryEpoch",
                    "correlation: .networkPath(",
                )
            )
            and "guard pathGeneration > 0 else" in recovery_writer
            and "guard pathGeneration > 0 else" in recovery_process_owner
            and host_process.count(
                "recoveryEvidenceOwner: recoveryEvidenceOwner"
            ) == 3
        ),
        "displayReconfigureTransitionCallbackConnected": (
            all(
                marker in display_evidence_owner
                for marker in (
                    "acceptDisplayReconfigure(",
                    "observeStart(",
                    "observeReconfigure(",
                    "recordDisplayReconfigureCompleted(",
                    "discardDisplayReconfigure(",
                    "pollingOwner.cancelAndWait()",
                )
            )
            and all(
                marker in media_owner
                for marker in (
                    'case "mediaDisplayReconfigureStarted":',
                    "displayEvidenceOwner.accept(",
                    "displayEvidenceOwner.observeStart(",
                    "displayEvidenceOwner.observeReconfigure(",
                    "snapshot.pendingOperationCount == 0",
                    "snapshot.desiredRoute == route",
                    "snapshot.activeRoute == route",
                )
            )
            and all(
                marker in recovery_process_owner
                for marker in (
                    "pendingDisplayReconfigureAcceptance",
                    "acceptDisplayReconfigure(",
                    "recordDisplayReconfigureCompleted(",
                    "replacementDisplayRevision == previousDisplayRevision + 1",
                    "replacementConnectionEpoch > previousConnectionEpoch",
                    "replacementCodecEpoch > previousCodecEpoch",
                )
            )
            and host_process.find("mediaPipelineOwner.cancelAndWait()")
            < host_process.find("recoveryEvidenceOwner.cancelAndWait()")
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
        "recoveryWriterSchema": line_number(
            recovery_writer, 'schema: "farpane-host-recovery-transition"'
        ),
        "recoveryDigestAuthority": line_number(
            recovery_process_owner, '"farpane.host-recovery.scope.v1"'
        ),
        "recoveryProcessComposition": line_number(
            host_process, "_ = recoveryEvidenceOwner.configure("
        ),
        "sleepWakeEvidenceAcceptance": line_number(
            sleep_core_owner, "operations.recoveryAccepted(epoch)"
        ),
        "sleepWakeEvidenceCompletion": line_number(
            sleep_core_owner, "operations.recoveryCompleted(epoch)"
        ),
        "networkEvidenceAcceptance": line_number(
            network_poller,
            "recoveryAccepted(pathGeneration, recoveryEpoch)",
        ),
        "networkEvidenceCompletion": line_number(
            network_poller,
            "recoveryCompleted(pathGeneration, recoveryEpoch)",
        ),
        "displayEvidenceAcceptance": line_number(
            display_evidence_owner, "acceptDisplayReconfigure("
        ),
        "displayEvidenceCompletion": line_number(
            display_evidence_owner, "recordDisplayReconfigureCompleted("
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
                "acceptedMonotonicNanoseconds",
                "completedMonotonicNanoseconds",
                "status",
                "hostInstanceScopeSHA256",
                "buildIdentitySHA256",
            ],
            "authorityCorrelation": {
                "sleepWake": [
                    "recoveryEpoch",
                    "runningReadyConverged",
                ],
                "networkPath": [
                    "pathGeneration",
                    "recoveryEpoch",
                    "runningReadyConverged",
                ],
                "displayReconfigure": [
                    "previousDisplayRevision",
                    "replacementDisplayRevision",
                    "previousConnectionEpoch",
                    "replacementConnectionEpoch",
                    "previousCodecEpoch",
                    "replacementCodecEpoch",
                    "freshRouteConverged",
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
        "recoveryManifestValidatorStillRequiresImplementation": True,
        "allThreeTransitionsRequireInstalledMacExecution": True,
        "eachRecoveryRequiresFreshTenMinuteScenarioThreeRun": True,
        "noSection15_2ItemSevenPassIsClaimed": True,
        "batteryAndCombinedRoleEvidenceRemainSeparate": True,
    }
    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "display-callback-implemented"
            if not missing
            else "contract-drift"
        ),
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
