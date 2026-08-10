#!/usr/bin/env python3
"""Audit the H6.3a Host file-transfer explicit-policy ABI seam."""

from __future__ import annotations

import json
import re
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-explicit-policy-abi-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def version(pattern: str, source: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing version pattern: {pattern}")
    return int(match.group(1))


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "core_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        header_abi = version(
            r"#define RDN_HOST_ABI_VERSION (\d+)u", sources["header"]
        )
        rust_abi = version(
            r"const HOST_ABI_VERSION: u32 = (\d+);", sources["bridge"]
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    header = sources["header"]
    bridge = sources["bridge"]
    host_control = sources["host_control"]
    connection = sources["connection"]
    product_sources = sources["app"] + sources["agent"]
    policy_call = bridge.find("apply_native_host_optional_capability_policy(")
    identity_read = bridge.find("host.local_id = config::Config::get_id();")

    evidence = {
        "designRecordsH63aBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.3a Host file-transfer explicit-policy ABI seam",
                "host-file-transfer-security-boundary-audit",
            )
        ),
        "hostABIv17RetainsFilePolicy": header_abi == rust_abi == 17,
        "cCreateOptionsCarryDedicatedFilePolicy": (
            "bool enable_file_transfer;" in header
        ),
        "swiftPolicyDefaultsOffAndProjectsToC": all(
            marker in host_control
            for marker in (
                "public let fileTransferEnabled: Bool",
                "fileTransferEnabled: Bool = false",
                "enable_file_transfer: configuration.fileTransferEnabled",
            )
        ),
        "rustCopiesImmutableCreatePolicy": all(
            marker in bridge
            for marker in (
                "file_transfer_enabled: bool",
                "file_transfer_enabled: (*options).enable_file_transfer",
            )
        ),
        "policyIsPersistedBeforeIdentityAndReadBackExactly": (
            policy_call >= 0
            and identity_read >= 0
            and policy_call < identity_read
            and "native_host_file_transfer_option(file_transfer_enabled)" in bridge
            and "PersistenceMismatch" in bridge
        ),
        "audioRemainsUnconditionallyDisabled": all(
            marker in bridge
            for marker in (
                "NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS",
                "OPTION_ENABLE_AUDIO",
                'Config::set_option(key.to_owned(), "N".to_owned())',
            )
        ),
        "upstreamLoginConsumesSameFilePermission": all(
            marker in connection
            for marker in (
                "Some(login_request::Union::FileTransfer(ft))",
                "keys::OPTION_ENABLE_FILE_TRANSFER",
                'self.send_login_error("No permission of file transfer")',
                "self.file_transfer = Some((ft.dir, ft.show_hidden));",
            )
        ),
        "productCallersDoNotEnableFileTransfer": (
            "fileTransferEnabled: true" not in product_sources
            and "fileTransferEnabled:" not in product_sources
        ),
        "defaultAndExplicitReadbackHaveTests": all(
            marker in (sources["core_tests"] + bridge)
            for marker in (
                "XCTAssertFalse(disabled.fileTransferEnabled)",
                "fileTransferEnabled: true",
                "host_storage_readback_accepts_explicit_file_transfer_opt_in_only",
                "native_host_file_transfer_option(false)",
                "native_host_file_transfer_option(true)",
            )
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.3a Host file-transfer explicit-policy ABI seam"
        ),
        "hostABIv17": line_number(header, "RDN_HOST_ABI_VERSION 17u"),
        "cFilePolicy": line_number(header, "bool enable_file_transfer;"),
        "swiftDefault": line_number(host_control, "fileTransferEnabled: Bool = false"),
        "rustPolicyCopy": line_number(
            bridge, "file_transfer_enabled: (*options).enable_file_transfer"
        ),
        "policyApplication": line_number(
            bridge, "apply_native_host_optional_capability_policy("
        ),
        "policyReadback": line_number(
            bridge, "native_host_file_transfer_option(file_transfer_enabled)"
        ),
        "upstreamLoginGate": line_number(
            connection, "Some(login_request::Union::FileTransfer(ft))"
        ),
        "swiftPolicyTest": line_number(
            sources["core_tests"], "fileTransferOnly = HostServerConfiguration("
        ),
        "rustReadbackTest": line_number(
            bridge, "host_storage_readback_accepts_explicit_file_transfer_opt_in_only"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-file-transfer-abi-capable-product-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-explicit-policy-abi-seam",
        "status": status,
        "implementation": {
            "hostABIVersion": rust_abi,
            "evidence": evidence,
            "sourceLines": source_lines,
        },
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostFileTransferEnabledByDefault": False,
            "hostFileTransferABICapable": True,
            "hostFileTransferProductEnabled": False,
            "viewerFileTransferImplemented": False,
            "filePromiseClipboardEnabled": False,
            "installedTwoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-security-boundary-audit",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-file-transfer-abi-capable-product-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
