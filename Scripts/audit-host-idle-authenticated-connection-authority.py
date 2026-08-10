#!/usr/bin/env python3
"""Audit and freeze the Host idle authenticated-connection authority gap."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SCHEMA = "farpane-host-idle-authenticated-connection-authority-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def version(pattern: str, source: str, label: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing {label}")
    return int(match.group(1))


def section(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset <= start_offset:
        return ""
    return source[start_offset:end_offset]


def ordered(source: str, *markers: str) -> bool:
    offset = 0
    for marker in markers:
        found = source.find(marker, offset)
        if found < 0:
            return False
        offset = found + len(marker)
    return True


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "client": repository / "Sources/CoreBridge/HostControlClient.swift",
        "snapshot_state": (
            repository / "Sources/CoreBridge/HostAgentSnapshotState.swift"
        ),
        "xpc_snapshot": (
            repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
        ),
        "runtime_state": (
            repository / "Sources/VideoPipeline/HostRuntimeStateEvidence.swift"
        ),
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "idle_validator": repository / "Scripts/validate-farpane-host-idle.py",
        "matrix_validator": (
            repository / "Scripts/validate-farpane-host-performance-matrix.py"
        ),
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
        print(
            json.dumps(
                {
                    "schema": SCHEMA,
                    "status": "audit-failed",
                    "error": str(error),
                },
                sort_keys=True,
            )
        )
        return 1

    patch = sources["patch"]
    connection = sources["connection"]
    count_helper = section(
        connection,
        "fn authenticated_connection_counts() -> (usize, usize)",
        '#[cfg(feature = "rdn-native-host")]\nfn send_native_host_wakelock_command',
    )
    auth_admission = section(
        connection,
        "pub struct AuthedConnID(i32, AuthConnType);",
        "fn check_wake_lock()",
    )
    auth_drop = section(
        connection,
        "impl Drop for AuthedConnID",
        "pub struct ControlPermissionsID",
    )
    snapshot_json = section(
        sources["bridge"],
        "fn snapshot_json(&mut self) -> Value",
        "fn now_unix_millis",
    )
    client_snapshot = section(
        sources["client"],
        "public struct HostCoreSnapshot",
        "public enum HostSessionAvailability",
    )
    snapshot_projection = section(
        sources["snapshot_state"],
        "package struct HostAgentSnapshotProjection",
        "package struct HostAgentSnapshotStateView",
    )
    xpc_payload = section(
        sources["xpc_snapshot"],
        "package struct HostAgentXPCWireSnapshotPayload",
        "package struct HostAgentXPCWireSnapshotResponse",
    )
    runtime_record = section(
        sources["runtime_state"],
        "private struct Record",
        "private let outputURL",
    )
    runtime_record_call = section(
        sources["app"],
        "private func recordHostRuntimeStateEvidence",
        "private func handleHostCoreEvent",
    )

    current_evidence = {
        "hostABIV13AndSnapshotV8AreImplemented": (
            rust_abi == 13 and header_abi == 13 and snapshot_schema == 8
        ),
        "authedConnectionsIsTheAllTypeAuthority": (
            "pub static ref AUTHED_CONNS" in connection
            and "let connections = AUTHED_CONNS.lock().unwrap();" in count_helper
            and "(connections.len(), remote_count)" in count_helper
            and "conn_type == AuthConnType::Remote" in count_helper
        ),
        "authenticatedAdmissionAndRAIIDropOwnTheList": (
            ordered(
                auth_admission,
                "let mut authed_connections = AUTHED_CONNS.lock().unwrap();",
                "authed_connections.push(AuthedConn {",
                "drop(authed_connections);",
                "Self::check_wake_lock();",
            )
            and ordered(
                auth_drop,
                "impl Drop for AuthedConnID",
                "AUTHED_CONNS.lock().unwrap().retain",
                "Self::check_wake_lock();",
            )
        ),
        "sleepAssertionAlreadyConsumesTheSameTotalCount": (
            "let (conn_count, remote_count) = authenticated_connection_counts();"
            in patch
            and "WakeLockCommand::Update {" in patch
            and "conn_count," in patch
            and "remote_count," in patch
        ),
        "hostSnapshotExportsStrictAuthenticatedCount": (
            "native_host_authenticated_connection_count()" in snapshot_json
            and '"authenticatedConnectionCount".into()' in snapshot_json
            and "public let authenticatedConnectionCount: UInt64" in client_snapshot
            and 'json["authenticatedConnectionCount"]' in client_snapshot
            and "strictSnapshotUInt64" in client_snapshot
        ),
        "agentProjectionAndXPCPreserveAuthenticatedCount": (
            "authenticatedConnectionCount = snapshot.authenticatedConnectionCount"
            in snapshot_projection
            and "package let authenticatedConnectionCount: UInt64" in xpc_payload
            and '"authenticatedConnectionCount": authenticatedConnectionCount'
            in xpc_payload
            and "guard schemaVersion == 8" in xpc_payload
        ),
        "runtimeStateSchemaV2RecordsOneSelectedAuthority": (
            "let schemaVersion: Int" in runtime_record
            and "schemaVersion: 2" in sources["runtime_state"]
            and "let authenticatedConnectionCount: UInt64?" in runtime_record
            and "let usesLegacyHost" in runtime_record_call
            and "backgroundPayload?.authenticatedConnectionCount"
            in runtime_record_call
            and "hostSnapshot?.authenticatedConnectionCount"
            in runtime_record_call
        ),
        "idleValidatorDerivesAllConnectionAbsence": (
            '"authenticatedConnectionCoverage": "all-rustdesk-authenticated-types"'
            in sources["idle_validator"]
            and 'record["authenticatedConnectionCount"] == 0'
            in sources["idle_validator"]
            and '"allAuthenticatedConnectionsProvenAbsent": bool(valid_records)'
            in sources["idle_validator"]
            and '"allAuthenticatedConnectionsProvenAbsent": True'
            not in sources["idle_validator"]
        ),
        "baseMatrixCorrectlyRequiresPositiveAbsenceProof": (
            'source.get("allAuthenticatedConnectionsProvenAbsent") is not True'
            in sources["matrix_validator"]
            and "idle evidence does not prove all authenticated connections absent"
            in sources["matrix_validator"]
        ),
    }
    missing = [name for name, present in current_evidence.items() if not present]

    target_contract = {
        "hostABIVersion": 13,
        "hostSnapshotSchemaVersion": 8,
        "hostSnapshotField": "authenticatedConnectionCount",
        "authority": "RustDesk server AUTHED_CONNS length across every AuthConnType",
        "countSemantics": [
            "incrementOnlyAfterAuthenticatedAdmission",
            "includeRemoteFileTransferPortForwardViewCameraAndTerminalTypes",
            "decrementByAuthedConnIDRAIIDrop",
            "snapshotReadsTheSameMutexProtectedList",
            "noActiveSessionOrMediaRouteInference",
        ],
        "swiftContract": [
            "HostCoreSnapshotStrictUInt64",
            "HostAgentSnapshotProjectionPreservesCount",
            "HostAgentXPCNestedPayloadSchema8PreservesCount",
            "unknownMissingBooleanOrFractionalCountFailsClosed",
        ],
        "runtimeStateSchemaVersion": 2,
        "runtimeStateContract": [
            "recordOptionalCountFromLegacyHostCoreOrCoherentBackgroundXPC",
            "readyIdleRecordsRequirePresentCount",
            "everyAcceptedIdleRecordRequiresCountZero",
            "allAuthenticatedConnectionsProvenAbsentDerivedNeverHardcoded",
        ],
        "forbiddenSubstitutes": [
            "activeSessionIsNull",
            "mediaRouteActiveIsFalse",
            "mediaPipelineActiveIsFalse",
            "sleepAssertionCountIsZero",
        ],
        "xpcOuterWireVersionChangeRequired": False,
    }
    remaining_boundary = {
        "sharedHostSnapshotAndRuntimeEvidenceSchemaChangeRequired": False,
        "backgroundAndLegacyRuntimeStateCallSitesNeedOneAuthority": False,
        "builtCoreLifecycleAndStrictDecoderTestsRequired": False,
        "realHostReadyNoConnection600SecondRunRequired": True,
        "dualArchitectureBaseMatrixStillHasNoRealData": True,
    }
    source_lines = {
        "authedConnectionsDeclaration": line_number(patch, "pub static ref AUTHED_CONNS"),
        "allTypeCountHelper": line_number(
            connection, "fn authenticated_connection_counts() -> (usize, usize)"
        ),
        "authenticatedAdmission": line_number(
            connection, "authed_connections.push(AuthedConn {"
        ),
        "authenticatedDrop": line_number(
            connection, "AUTHED_CONNS.lock().unwrap().retain"
        ),
        "hostSnapshotBuilder": line_number(
            sources["bridge"], "fn snapshot_json(&mut self) -> Value"
        ),
        "swiftHostSnapshot": line_number(
            sources["client"], "public struct HostCoreSnapshot"
        ),
        "agentSnapshotProjection": line_number(
            sources["snapshot_state"], "package struct HostAgentSnapshotProjection"
        ),
        "xpcSnapshotPayload": line_number(
            sources["xpc_snapshot"], "package struct HostAgentXPCWireSnapshotPayload"
        ),
        "runtimeStateRecord": line_number(
            sources["runtime_state"], "private struct Record"
        ),
        "idleDerivedAbsenceProof": line_number(
            sources["idle_validator"],
            '"allAuthenticatedConnectionsProvenAbsent": bool(valid_records)',
        ),
        "matrixPositiveProofGate": line_number(
            sources["matrix_validator"],
            'source.get("allAuthenticatedConnectionsProvenAbsent") is not True',
        ),
    }
    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "implemented" if not missing else "audit-failed",
        "implementation": {
            "hostABIVersion": rust_abi,
            "headerABIVersion": header_abi,
            "snapshotSchemaVersion": snapshot_schema,
            "evidence": current_evidence,
            "sourceLines": source_lines,
        },
        "targetContract": target_contract,
        "remainingBoundary": remaining_boundary,
        "missingEvidence": missing,
    }
    print(json.dumps(document, indent=2, sort_keys=True))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
