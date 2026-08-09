#!/usr/bin/env python3
"""Audit XPC v2 identity through App Host lifecycle observation."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-agent-xpc-process-identity-contract-audit"


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
        "handshake": (
            repository / "Sources/CoreBridge/HostAgentXPCWireHandshake.swift"
        ),
        "identity": (
            repository
            / "Sources/CoreBridge/HostAgentXPCProcessIdentityAuthority.swift"
        ),
        "client": (
            repository / "Sources/CoreBridge/HostAgentXPCSnapshotClient.swift"
        ),
        "snapshot": (
            repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
        ),
        "projection": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundProjectionAuthority.swift"
        ),
        "snapshot_service": (
            repository / "Sources/CoreBridge/HostAgentXPCSnapshotService.swift"
        ),
        "command_owner": (
            repository
            / "Sources/CoreBridge/HostAgentXPCCommandProcessOwner.swift"
        ),
        "runtime": (
            repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
        ),
        "process_owner": (
            repository
            / "Sources/VideoPipeline/"
            / "HostViewerConcurrencyEvidenceProcessOwner.swift"
        ),
        "writer": (
            repository
            / "Sources/VideoPipeline/HostViewerConcurrencyEvidence.swift"
        ),
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "app_observation": (
            repository
            / "Sources/CoreBridge/"
            / "HostAgentApplicationConcurrencyObservation.swift"
        ),
        "handshake_tests": (
            repository
            / "Tests/CoreBridgeTests/HostAgentXPCWireHandshakeTests.swift"
        ),
        "identity_tests": (
            repository
            / "Tests/CoreBridgeTests/"
            / "HostAgentXPCProcessIdentityAuthorityTests.swift"
        ),
        "client_tests": (
            repository
            / "Tests/CoreBridgeTests/HostAgentXPCSnapshotClientTests.swift"
        ),
        "app_observation_tests": (
            repository
            / "Tests/CoreBridgeTests/"
            / "HostAgentApplicationConcurrencyObservationTests.swift"
        ),
        "process_owner_tests": (
            repository
            / "Tests/VideoPipelineTests/"
            / "HostViewerConcurrencyEvidenceProcessOwnerTests.swift"
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

    handshake = sources["handshake"]
    identity = sources["identity"]
    client = sources["client"]
    snapshot = sources["snapshot"]
    projection = sources["projection"]
    snapshot_service = sources["snapshot_service"]
    command_owner = sources["command_owner"]
    runtime = sources["runtime"]
    process_owner = sources["process_owner"]
    writer = sources["writer"]
    app = sources["app"]
    app_observation = sources["app_observation"]
    handshake_tests = sources["handshake_tests"]
    identity_tests = sources["identity_tests"]
    client_tests = sources["client_tests"]
    app_observation_tests = sources["app_observation_tests"]
    process_owner_tests = sources["process_owner_tests"]

    evidence = {
        "handshakeImplementsStrictSchemaAndWireV2": all(
            marker in handshake
            for marker in (
                "currentSchemaVersion: UInt64 = 2",
                "currentWireVersion: UInt64 = 2",
                "Set(document.keys) == Set([",
                "unsupportedSchema(",
                "supportedWireVersions: [UInt64]",
                "[currentWireVersion]",
                '"agentProcessId"',
                '"agentProcessStartIdentitySHA256"',
                "validAgentProcessID",
                "validLowercaseSHA256",
            )
        ),
        "wireIdentityCarriesExactFiveValidatedFields": all(
            marker in handshake
            for marker in (
                "package struct HostAgentXPCWireAgentIdentity",
                "package let agentBuildID: String",
                "package let hostInstanceID: String",
                "package let agentBootID: String",
                "package let agentProcessID: Int32",
                "package let agentProcessStartIdentitySHA256: String",
                "knownIdentityPresence.allSatisfy({ $0 })",
                "knownIdentityPresence.allSatisfy({ !$0 })",
                "agentProcessID: identity.agentProcessID",
                "identity.agentProcessStartIdentitySHA256",
            )
        ),
        "agentIdentityAuthorityIsImmutableAndHostBound": all(
            marker in identity
            for marker in (
                "exactly one authoritative Host instance",
                "case waitingForHostInstance",
                "case ready(HostAgentXPCWireAgentIdentity)",
                "case invalidated",
                "case .waitingForHostInstance:",
                "case .ready(let identity):",
                "identity.hostInstanceID == hostInstanceID",
            )
        ),
        "productAuthorityCapturesAndHashesExactCurrentProcessOnce": all(
            marker in identity
            for marker in (
                "let processID = getpid()",
                "PROC_PIDTBSDINFO",
                "info.pbi_pid == UInt32(processID)",
                "info.pbi_start_tvsec > 0",
                "info.pbi_start_tvusec < 1_000_000",
                '"farpane.v1-concurrency.process-start.v1"',
                "var hasher = SHA256()",
                "agentProcessIdentitySnapshot()",
            )
        ),
        "authorityDerivedProcessIdentityIsSharedWithCommandOwner": (
            all(
                marker in runtime
                for marker in (
                    "xpcIdentityAuthority.agentProcessIdentitySnapshot()",
                    "agentProcessIdentity: agentProcessIdentity",
                )
            )
            and all(
                marker in command_owner
                for marker in (
                    "private let agentProcessIdentity:",
                    "HostAgentXPCWireAgentProcessIdentity",
                    "try agentProcessIdentity.bind(",
                )
            )
            and "getpid()" not in runtime
            and "PROC_PIDTBSDINFO" not in runtime
        ),
        "appPeerIdentityAcceptsOnlyHandshakeProcessIdentity": all(
            marker in client
            for marker in (
                "package struct HostAgentXPCSnapshotClientPeerIdentity",
                "package let agentProcessID: Int32",
                "package let agentProcessStartIdentitySHA256: String",
                "agentProcessID: response.agentProcessID",
                "response.agentProcessStartIdentitySHA256",
                "knownAgentProcessID: previousPeerIdentity?.agentProcessID",
                ".agentProcessStartIdentitySHA256",
            )
        ),
        "sameConnectionPinsFullIdentityAcrossTrafficAndReconnect": (
            all(
                marker in snapshot_service
                for marker in (
                    "private let identity: HostAgentXPCWireAgentIdentity",
                    "state = .negotiating",
                    "identity: identity",
                    "HostAgentXPCWireSnapshotResponse.make(",
                    "HostAgentXPCWireEventCursorResponse.make(",
                )
            )
            and all(
                marker in client
                for marker in (
                    "case fetchingSnapshot(HostAgentXPCSnapshotClientPeerIdentity)",
                    "case ready(",
                    "peerIdentity = try HostAgentXPCSnapshotClientPeerIdentity(",
                    "previousPeerIdentity == peerIdentity",
                )
            )
        ),
        "snapshotDoesNotClaimProcessIdentityAuthority": (
            "agentProcessID" not in snapshot
            and "agentProcessStartIdentitySHA256" not in snapshot
        ),
        "evidenceOwnerUsesTheSameKernelProcessStartShape": all(
            marker in process_owner
            for marker in (
                "processID: { getpid() }",
                "guard processID > 1 else { return nil }",
                "PROC_PIDTBSDINFO",
                "info.pbi_pid == UInt32(processID)",
                "info.pbi_start_tvsec > 0",
                "info.pbi_start_tvusec < 1_000_000",
            )
        ),
        "evidenceDigestIsDomainSeparatedAndRawIdentityFree": all(
            marker in writer
            for marker in (
                'domain: "farpane.v1-concurrency.process-start.v1"',
                "hasher.update(data: Data(domain.utf8))",
                "hasher.update(data: Data([0]))",
                "return hasher.finalize()",
            )
        ),
        "hostObservationRequiresExactAgentProcessIdentity": all(
            marker in writer
            for marker in (
                "let hostAgentProcessID: Int32",
                "let hostAgentProcessStartIdentitySHA256: String",
                "observation.hostAgentProcessID == identity.processID",
                "observation.hostAgentProcessStartIdentitySHA256",
            )
        ),
        "applicationHostCompositionUsesOnlyCoherentProjection": (
            all(
                marker in app
                for marker in (
                    "HostAgentApplicationConcurrencyObservationState()",
                    "defer { observeHostAgentApplicationConcurrencyEvidence() }",
                    "coherentConfigRevision: configRevision",
                    "sourceToken: activationView.generation",
                )
            )
            and all(
                marker in app_observation
                for marker in (
                    "case coherent(",
                    "case transportUnavailable",
                    "case evidenceUnavailable",
                    "coherentConfigRevision > 0",
                    "HostAgentConcurrencyRuntimeStatePolicy.classify(",
                    "if let scope, scope != candidateScope",
                    "failed = true",
                )
            )
        ),
        "applicationHostObservationUsesExactXPCProcessIdentity": (
            all(
                marker in app
                for marker in (
                    ".observeApplicationHostAgentRuntimeState(",
                    "observation.peerIdentity.hostInstanceID",
                    "observation.peerIdentity.agentBuildID",
                    "observation.peerIdentity.agentProcessID",
                    ".agentProcessStartIdentitySHA256",
                )
            )
            and all(
                marker in process_owner
                for marker in (
                    "public func observeApplicationHostAgentRuntimeState(",
                    "expectedObserverRole: .application",
                    "agentProcessID > 1",
                    "Self.isLowercaseSHA256(agentProcessStartIdentitySHA256)",
                    "configuredRole == expectedObserverRole",
                    "current.scope == scope",
                )
            )
            and "getpid()" not in app
            and "PROC_PIDTBSDINFO" not in app
            and "getpid()" not in app_observation
            and "PROC_PIDTBSDINFO" not in app_observation
        ),
        "applicationHostObservationFailClosedTestsExist": (
            all(
                marker in app_observation_tests
                for marker in (
                    "testCoherentProjectionDisconnectAndRecoveryUseOnePinnedScope",
                    "testIdentityOrConfigurationDriftFailsClosed",
                    "coherentConfigRevision: nil",
                    "XCTAssertTrue(state.snapshot().failed)",
                )
            )
            and all(
                marker in process_owner_tests
                for marker in (
                    "testApplicationRecordsOnlyExactHandshakeAgentProcessIdentity",
                    'String(repeating: "A", count: 64)',
                    'agentProcessID: 4_322',
                )
            )
        ),
        "v1AndMalformedProcessIdentityFailClosedInTests": (
            all(
                marker in handshake_tests
                for marker in (
                    '["schemaVersion": 1]',
                    "supportedWireVersions: [1]",
                    '["agentProcessId": 1]',
                    'String(repeating: "A", count: 64)',
                )
            )
            and all(
                marker in identity_tests
                for marker in (
                    "XCTAssertEqual(firstIdentity.agentProcessID, getpid())",
                    "HostViewerConcurrencyEvidenceDigest.processStartIdentity(",
                )
            )
            and all(
                marker in client_tests
                for marker in (
                    "handshakeRequest.knownAgentProcessID",
                    "previous.agentProcessStartIdentitySHA256",
                    "agentProcessID: 3_210",
                )
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "handshakeSchemaV2": line_number(
            handshake, "currentSchemaVersion: UInt64 = 2"
        ),
        "handshakeWireV2": line_number(
            handshake, "currentWireVersion: UInt64 = 2"
        ),
        "wireIdentity": line_number(
            handshake, "package struct HostAgentXPCWireAgentIdentity"
        ),
        "immutableIdentityAuthority": line_number(
            identity, "exactly one authoritative Host instance"
        ),
        "agentProcessIDWireField": line_number(
            handshake, "package let agentProcessID: Int32"
        ),
        "agentProcessStartWireField": line_number(
            handshake,
            "package let agentProcessStartIdentitySHA256: String",
        ),
        "productPIDAuthority": line_number(identity, "let processID = getpid()"),
        "productProcessStartAuthority": line_number(
            identity, "PROC_PIDTBSDINFO"
        ),
        "productProcessStartDigest": line_number(
            identity, '"farpane.v1-concurrency.process-start.v1"'
        ),
        "sharedCommandProcessIdentity": line_number(
            runtime, "agentProcessIdentity: agentProcessIdentity"
        ),
        "appPeerIdentity": line_number(
            client, "package struct HostAgentXPCSnapshotClientPeerIdentity"
        ),
        "appPeerProcessIdentity": line_number(
            client, "package let agentProcessID: Int32"
        ),
        "appPreviousProcessIdentity": line_number(
            client,
            "knownAgentProcessID: previousPeerIdentity?.agentProcessID",
        ),
        "reconnectFullIdentityComparison": line_number(
            client, "previousPeerIdentity == peerIdentity"
        ),
        "projectionPeerIdentity": line_number(
            projection,
            "let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity",
        ),
        "kernelProcessStart": line_number(process_owner, "PROC_PIDTBSDINFO"),
        "processStartDigest": line_number(
            writer, 'domain: "farpane.v1-concurrency.process-start.v1"'
        ),
        "requiredHostAgentPID": line_number(
            writer, "let hostAgentProcessID: Int32"
        ),
        "requiredHostAgentProcessStart": line_number(
            writer, "let hostAgentProcessStartIdentitySHA256: String"
        ),
        "applicationObservationComposition": line_number(
            app, "private func observeHostAgentApplicationConcurrencyEvidence()"
        ),
        "applicationObservationState": line_number(
            app_observation,
            "package final class HostAgentApplicationConcurrencyObservationState",
        ),
        "applicationEvidenceAPI": line_number(
            process_owner,
            "public func observeApplicationHostAgentRuntimeState(",
        ),
        "applicationAgentProcessID": line_number(
            app, "observation.peerIdentity.agentProcessID"
        ),
        "applicationAgentProcessStart": line_number(
            app, ".agentProcessStartIdentitySHA256"
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h5.3ag-application-host-lifecycle-observation",
        "status": (
            "application-host-observation-composed"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "targetContract": {
            "handshakeSchemaVersion": 2,
            "wireVersion": 2,
            "identityFields": [
                "agentBuildID",
                "hostInstanceID",
                "agentBootID",
                "agentProcessID",
                "agentProcessStartIdentitySHA256",
            ],
            "agentAuthority": {
                "processIDSource": "getpid",
                "processStartSource": "PROC_PIDTBSDINFO-same-pid",
                "processStartDigestDomain": (
                    "farpane.v1-concurrency.process-start.v1"
                ),
                "captureTiming": "once-before-xpc-identity-publication",
                "immutableLifetime": "host-agent-process",
            },
            "validation": {
                "requiresExactRequestAndResponseKeys": True,
                "requiresAgentProcessIDGreaterThanOne": True,
                "requiresLowercaseSHA256Hex": True,
                "requiresProcessStartDigestLength": 64,
                "requiresSameAcceptedHandshakeResponse": True,
                "requiresUnsupportedSchemaAndWireFailClosed": True,
            },
            "appBinding": {
                "acceptsIdentityOnlyFromCompatibleHandshakeV2": True,
                "pinsAllIdentityFieldsAcrossSnapshotAndCommands": True,
                "comparesAllIdentityFieldsAcrossReconnect": True,
                "publishesOnlyAfterSnapshotIdentityCoherence": True,
                "doesNotInferIdentityFromSnapshot": True,
            },
            "forbiddenInference": [
                "application-process-scan-for-host-agent-pid",
                "pid-without-process-start-identity",
                "agent-boot-id-as-process-start-identity",
                "snapshot-payload-as-process-identity-authority",
                "raw-process-start-identity-on-wire-or-in-evidence",
                "schema-v1-fallback-for-host-lifecycle-evidence",
                "caller-supplied-process-identity",
            ],
        },
        "nextImplementationBoundary": (
            "viewer-automatic-recovery-composition"
        ),
        "remainingBoundary": {
            "applicationHostObservationStillRequiresComposition": False,
            "viewerAutomaticRecoveryStillRequiresImplementation": True,
            "fiveScenarioValidatorStillRequiresImplementation": True,
            "installedAppAgentExecutionStillRequiresExecution": True,
            "noV1ConcurrencyMatrixPassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return (
        0
        if result["status"] == "application-host-observation-composed"
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
