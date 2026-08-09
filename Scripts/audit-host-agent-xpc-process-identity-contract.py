#!/usr/bin/env python3
"""Freeze the fail-closed HostAgent process-identity XPC v2 contract."""

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
    process_owner = sources["process_owner"]
    writer = sources["writer"]
    app = sources["app"]

    evidence = {
        "currentHandshakeIsStrictSchemaAndWireV1": all(
            marker in handshake
            for marker in (
                "currentSchemaVersion: UInt64 = 1",
                "currentWireVersion: UInt64 = 1",
                "Set(document.keys) == Set([",
                "unsupportedSchema(",
                "supportedWireVersions: [UInt64]",
                "[currentWireVersion]",
            )
        ),
        "currentHandshakeIdentityHasOnlyBuildHostAndBoot": (
            all(
                marker in handshake
                for marker in (
                    "package struct HostAgentXPCWireAgentIdentity",
                    "package let agentBuildID: String",
                    "package let hostInstanceID: String",
                    "package let agentBootID: String",
                )
            )
            and "agentProcessID" not in handshake
            and "agentProcessStartIdentitySHA256" not in handshake
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
        "appPeerIdentityAndProjectionOmitProcessIdentity": (
            all(
                marker in client
                for marker in (
                    "package struct HostAgentXPCSnapshotClientPeerIdentity",
                    "package let agentBuildID: String",
                    "package let hostInstanceID: String",
                    "package let agentBootID: String",
                )
            )
            and "agentProcessID" not in client
            and "agentProcessStartIdentitySHA256" not in client
            and "agentProcessID" not in projection
            and "agentProcessStartIdentitySHA256" not in projection
        ),
        "snapshotDoesNotClaimProcessIdentityAuthority": (
            "agentProcessID" not in snapshot
            and "agentProcessStartIdentitySHA256" not in snapshot
        ),
        "kernelProcessStartAuthorityAlreadyExists": all(
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
        "applicationHostCompositionRemainsFailClosed": (
            "recordHostRuntimeStateEvidence(force: true)" in app
            and "recordHostAgentObservation(" not in app
            and "observeHostAgentRuntimeState(" not in app
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "handshakeSchemaV1": line_number(
            handshake, "currentSchemaVersion: UInt64 = 1"
        ),
        "handshakeWireV1": line_number(
            handshake, "currentWireVersion: UInt64 = 1"
        ),
        "wireIdentity": line_number(
            handshake, "package struct HostAgentXPCWireAgentIdentity"
        ),
        "immutableIdentityAuthority": line_number(
            identity, "exactly one authoritative Host instance"
        ),
        "appPeerIdentity": line_number(
            client, "package struct HostAgentXPCSnapshotClientPeerIdentity"
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
        "failClosedApplicationComposition": line_number(
            app, "recordHostRuntimeStateEvidence(force: true)"
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h5.3ae-host-agent-process-identity-xpc-contract",
        "status": (
            "contract-frozen"
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
        "nextImplementationBoundary": "host-agent-xpc-wire-identity-v2",
        "remainingBoundary": {
            "sharedXPCSchemaStillRequiresVersionedImplementation": True,
            "applicationHostObservationStillRequiresComposition": True,
            "installedAppAgentExecutionStillRequiresExecution": True,
            "noV1ConcurrencyMatrixPassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "contract-frozen" else 1


if __name__ == "__main__":
    raise SystemExit(main())
