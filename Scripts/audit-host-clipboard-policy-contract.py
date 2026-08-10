#!/usr/bin/env python3
"""Audit the H6.2 clipboard read/write policy representation boundary."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-policy-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "host_bridge": repository
        / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_host_bridge": repository
        / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "xpc_snapshot": repository
        / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift",
        "core_tests": repository
        / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "xpc_tests": repository
        / "Tests/CoreBridgeTests/HostAgentXPCWireSnapshotTests.swift",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(
            json.dumps(
                {
                    "schema": SCHEMA,
                    "schemaVersion": 1,
                    "status": "audit-failed",
                    "error": str(error),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1

    design = sources["design"]
    host_bridge = sources["host_bridge"]
    connection = sources["connection"]
    host_control = sources["host_control"]
    xpc_snapshot = sources["xpc_snapshot"]
    core_tests = sources["core_tests"]
    xpc_tests = sources["xpc_tests"]

    evidence = {
        "designRequiresIndependentReadWritePolicy": all(
            marker in design
            for marker in (
                "read/write 分权",
                "默认支持小型文本",
                "H6.2 剪贴板富类型",
            )
        ),
        "rustPolicyOwnsIndependentDirections": all(
            marker in host_bridge
            for marker in (
                "struct NativeClipboardPolicy",
                "remote_read: bool",
                "remote_write: bool",
                "pub(crate) fn new(remote_read: bool, remote_write: bool)",
            )
        ),
        "rustCapabilityProjectionIsIndependent": all(
            marker in host_bridge
            for marker in (
                "if self.clipboard.remote_read",
                'names.push("readClipboard")',
                "if self.clipboard.remote_write",
                'names.push("writeClipboard")',
            )
        ),
        "rustSubsetPolicyIsIndependent": all(
            marker in host_bridge
            for marker in (
                "(!self.remote_read || other.remote_read)",
                "(!self.remote_write || other.remote_write)",
                "self.clipboard.is_subset_of(other.clipboard)",
            )
        ),
        "canonicalAndVendoredHostBridgeMatch": (
            host_bridge == sources["vendor_host_bridge"]
        ),
        "coreSnapshotNoLongerRequiresClipboardPair": (
            'capabilitySet.contains("readClipboard")\n'
            '                == capabilitySet.contains("writeClipboard")'
            not in host_control
        ),
        "xpcSnapshotNoLongerRequiresClipboardPair": (
            "requiresClipboardPair" not in xpc_snapshot
            and "validCapabilities(_ values: [String])" in xpc_snapshot
        ),
        "fourStateRustPolicyTestExists": all(
            marker in host_bridge
            for marker in (
                "native_clipboard_policy_represents_read_and_write_independently",
                "let read_only = NativeClipboardPolicy::new(true, false)",
                "let write_only = NativeClipboardPolicy::new(false, true)",
                "let bidirectional = NativeClipboardPolicy::new(true, true)",
            )
        ),
        "swiftContractsCoverBothAsymmetricPolicies": all(
            marker in core_tests + xpc_tests
            for marker in (
                "readOnlyClipboard",
                "writeOnlyClipboard",
                '"viewDisplay", "controlKeyboardMouse", "readClipboard"',
                '"viewDisplay", "controlKeyboardMouse", "writeClipboard"',
            )
        ),
        "runtimeDataPathRemainsDefaultOff": all(
            marker in host_bridge + connection
            for marker in (
                "OPTION_ENABLE_CLIPBOARD",
                '(config::keys::OPTION_ENABLE_CLIPBOARD, "N")',
                "self.clipboard && !self.disable_clipboard",
                "active_policy().allows_remote_read()",
                "native_host_allows_remote_clipboard_write(",
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    source_lines = {
        "designClipboardPolicy": line_number(design, "### 12.2 剪贴板"),
        "rustPolicy": line_number(host_bridge, "struct NativeClipboardPolicy"),
        "rustReadProjection": line_number(
            host_bridge, "if self.clipboard.remote_read"
        ),
        "rustWriteProjection": line_number(
            host_bridge, "if self.clipboard.remote_write"
        ),
        "rustPolicyTest": line_number(
            host_bridge,
            "native_clipboard_policy_represents_read_and_write_independently",
        ),
        "coreSnapshotValidator": line_number(
            host_control, "private static func validCapabilities("
        ),
        "xpcSnapshotValidator": line_number(
            xpc_snapshot, "fileprivate static func validCapabilities("
        ),
        "connectionClipboardGate": line_number(
            connection, "self.clipboard && !self.disable_clipboard"
        ),
    }
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "clipboard-read-write-policy-contract"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-clipboard-policy-representation",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "readWritePolicyRepresentable": True,
            "clipboardDataPathEnabled": False,
            "boundedSmallTextImplemented": True,
            "richClipboardImplemented": False,
        },
        "remainingBoundary": {
            "independentRevocationCommandsRequired": False,
            "directionalXPCUIRequired": False,
            "eventDrivenDynamicBackoffRequired": False,
            "temporaryObjectCleanupRequired": False,
            "viewerSmallTextClipboardAPIRequired": False,
            "explicitProductEnablementRequired": True,
        },
        "nextImplementationBoundary": "viewer-pasteboard-owner-and-explicit-enablement-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "clipboard-read-write-policy-contract" else 1


if __name__ == "__main__":
    raise SystemExit(main())
