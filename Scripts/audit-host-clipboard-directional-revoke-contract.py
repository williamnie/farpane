#!/usr/bin/env python3
"""Audit the H6.2d1 Host Core clipboard directional revoke contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-directional-revoke-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "core_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "xpc_wire": repository / "Sources/CoreBridge/HostAgentXPCWireCommand.swift",
        "home_policy": repository
        / "Sources/CoreBridge/HostAgentBackgroundHomeCommandPolicy.swift",
        "upstream_patch": repository
        / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    design = sources["design"]
    bridge = sources["bridge"]
    connection = sources["connection"]
    host_control = sources["host_control"]
    core_tests = sources["core_tests"]
    patch = sources["upstream_patch"]
    evidence = {
        "designRecordsBoundedCoreBoundary": all(
            marker in design
            for marker in (
                "H6.2d1 independent directional revoke Host Core contract",
                "H6.2d2",
            )
        ),
        "connectionOwnsMaximumAndActivePolicy": all(
            marker in connection
            for marker in (
                "struct NativeClipboardPermissionState",
                "maximum: u8",
                "active: AtomicU8",
                "native_clipboard_permissions: Option<Arc<",
            )
        ),
        "runtimeCannotExceedConfiguredMaximum": all(
            marker in bridge + connection
            for marker in (
                "restricted_to(clipboard)",
                "if enabled && self.maximum & bit != 0",
                "maximum_policy()",
            )
        ),
        "readRevokeHasExactCoreCommand": all(
            marker in bridge
            for marker in (
                "DisableClipboardRead",
                'name: "clipboard-read".to_owned()',
                '"disableClipboardReadForActiveSession"',
                "session-clipboard-read-disable-queued",
            )
        ),
        "writeRevokeHasExactCoreCommand": all(
            marker in bridge
            for marker in (
                "DisableClipboardWrite",
                'name: "clipboard-write".to_owned()',
                '"disableClipboardWriteForActiveSession"',
                "session-clipboard-write-disable-queued",
            )
        ),
        "legacyBidirectionalAliasRemains": all(
            marker in bridge + connection + host_control
            for marker in (
                '"disableClipboardForActiveSession"',
                'name: "clipboard".to_owned()',
                "set_legacy_enabled(enabled)",
            )
        ),
        "dataPlaneConsumesPerConnectionActivePolicy": all(
            marker in connection
            for marker in (
                "active_policy().allows_remote_read()",
                "active_policy().allows_remote_write()",
                "native_host_outgoing_clipboard_message_is_allowed(",
                "native_host_allows_remote_clipboard_write(&self",
            )
        ),
        "snapshotProjectsMaximumThenActivePolicy": all(
            marker in connection
            for marker in (
                "fn native_session_initial_capabilities(",
                ".map(|permissions| permissions.maximum_policy())",
                "fn native_session_active_capabilities(",
                ".map(|permissions| permissions.active_policy())",
            )
        ),
        "approvalRequestsRespectLocalMaximum": all(
            marker in connection
            for marker in (
                "let mut requested_capabilities",
                "if clipboard.allows_remote_read()",
                "if clipboard.allows_remote_write()",
            )
        ),
        "swiftDirectAPIAndConvergenceAreDirectional": all(
            marker in host_control + core_tests
            for marker in (
                "case clipboardRead",
                "case clipboardWrite",
                'return ["readClipboard"]',
                'return ["writeClipboard"]',
                "intent: .disable(.clipboardRead)",
                "intent: .disable(.clipboardWrite)",
            )
        ),
        "testsAndTrackedSourcesCarryTheContract": all(
            marker in bridge + connection + patch
            for marker in (
                "native_active_session_commands_are_exact_scoped_and_fail_closed",
                "native_clipboard_permissions_revoke_directions_without_exceeding_maximum",
                "NativeClipboardPermissionState",
            )
        ) and bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.2d1 independent directional revoke Host Core contract"
        ),
        "permissionState": line_number(
            connection, "struct NativeClipboardPermissionState"
        ),
        "outgoingGate": line_number(
            connection, "native_host_outgoing_clipboard_message_is_allowed("
        ),
        "incomingGate": line_number(
            connection, "native_host_allows_remote_clipboard_write(&self"
        ),
        "initialSnapshot": line_number(
            connection, "fn native_session_initial_capabilities("
        ),
        "activeSnapshot": line_number(
            connection, "fn native_session_active_capabilities("
        ),
        "approvalProjection": line_number(
            connection, "let mut requested_capabilities"
        ),
        "readCommand": line_number(
            bridge, '"disableClipboardReadForActiveSession"'
        ),
        "writeCommand": line_number(
            bridge, '"disableClipboardWriteForActiveSession"'
        ),
        "rustStateTest": line_number(
            connection,
            "native_clipboard_permissions_revoke_directions_without_exceeding_maximum",
        ),
        "swiftCapability": line_number(host_control, "case clipboardRead"),
        "swiftConvergenceTest": line_number(
            core_tests, "intent: .disable(.clipboardRead)"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "independent-directional-revoke-core-contract"
        if not missing and not missing_lines
        else "audit-failed"
    )
    xpc_directional = all(
        marker in sources["xpc_wire"]
        for marker in (
            "disableClipboardReadForActiveSession",
            "disableClipboardWriteForActiveSession",
        )
    )
    home_directional = all(
        marker in sources["home_policy"]
        for marker in ("disableClipboardRead", "disableClipboardWrite")
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-independent-directional-revoke-host-core",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostCoreDirectionalRevokeImplemented": True,
            "swiftDirectDirectionalAPIImplemented": True,
            "legacyBidirectionalAliasPreserved": True,
            "directionalXPCImplemented": xpc_directional,
            "directionalHomeControlsImplemented": home_directional,
            "clipboardEnabledByDefault": False,
        },
        "remainingBoundary": {
            "directionalXPCUIRequired": not (xpc_directional and home_directional),
            "eventDrivenDynamicBackoffRequired": False,
            "temporaryObjectCleanupRequired": True,
            "explicitProductEnablementRequired": True,
        },
        "nextImplementationBoundary": "temporary-clipboard-object-cleanup-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "independent-directional-revoke-core-contract" else 1


if __name__ == "__main__":
    raise SystemExit(main())
