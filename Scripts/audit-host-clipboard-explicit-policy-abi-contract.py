#!/usr/bin/env python3
"""Audit the H6.2i1 Host clipboard explicit-policy ABI seam."""

from __future__ import annotations

import json
import re
from pathlib import Path


SCHEMA = "farpane-host-clipboard-explicit-policy-abi-contract-audit"


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
        "bootstrap": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "core_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
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
    product_sources = sources["app"] + sources["agent"]
    tests = sources["core_tests"] + sources["host_tests"] + bridge

    policy_call = bridge.find(
        "apply_native_host_optional_capability_policy(host.clipboard_transfer_policy);"
    )
    identity_read = bridge.find("host.local_id = config::Config::get_id();")
    evidence = {
        "designRecordsBoundedH6Step": all(
            marker in sources["design"]
            for marker in (
                "H6.2i1 Host small-text clipboard explicit-policy ABI seam",
                "host-clipboard-bootstrap-home-opt-in-contract",
            )
        ),
        "hostABIV14RetainsSmallTextPolicy": header_abi == rust_abi == 14,
        "cCreateOptionsCarryIndependentDirections": all(
            marker in header
            for marker in (
                "bool enable_clipboard_read;",
                "bool enable_clipboard_write;",
            )
        ),
        "swiftDirectionsDefaultOffAndRemainIndependent": all(
            marker in host_control
            for marker in (
                "clipboardReadEnabled: Bool = false",
                "clipboardWriteEnabled: Bool = false",
                "enable_clipboard_read: configuration.clipboardReadEnabled",
                "enable_clipboard_write: configuration.clipboardWriteEnabled",
            )
        ),
        "rustCopiesPolicyIntoHostLifetime": all(
            marker in bridge
            for marker in (
                "clipboard_transfer_policy: NativeClipboardTransferPolicy",
                "(*options).enable_clipboard_read",
                "(*options).enable_clipboard_write",
                "broker.clipboard_transfer_policy = host.clipboard_transfer_policy",
            )
        ),
        "upstreamBooleanIsOnlyAnExplicitAdapter": all(
            marker in bridge
            for marker in (
                "fn native_host_clipboard_option(policy: NativeClipboardTransferPolicy)",
                "if policy.any_enabled()",
                '"Y"',
                '"N"',
            )
        ),
        "policyIsPersistedBeforeIdentityAndReadBackExactly": (
            policy_call >= 0
            and identity_read >= 0
            and policy_call < identity_read
            and "native_host_clipboard_option(clipboard_policy)" in bridge
            and "PersistenceMismatch" in bridge
        ),
        "fileAndAudioRemainAlwaysDisabled": all(
            marker in bridge
            for marker in (
                "NATIVE_HOST_ALWAYS_DISABLED_OPTION_KEYS",
                "OPTION_ENABLE_FILE_TRANSFER",
                "OPTION_ENABLE_AUDIO",
                'Config::set_option(key.to_owned(), "N".to_owned())',
            )
        ),
        "productCallersPassOneExplicitPolicy": (
            "clipboardPolicy: currentHostClipboardPolicy()" in sources["app"]
            and "clipboardReadEnabled: clipboardPolicy.allowRemoteRead"
            in sources["app"]
            and "configuration.clipboardPolicy.allowRemoteRead"
            in sources["agent"]
            and "configuration.clipboardPolicy.allowRemoteWrite"
            in sources["agent"]
        ),
        "legacyBootstrapAndCoreDefaultsRemainOff": (
            "public static let disabled = Self(" in sources["bootstrap"]
            and "clipboardReadEnabled: Bool = false" in host_control
            and "clipboardWriteEnabled: Bool = false" in host_control
        ),
        "directionalDefaultsAndPersistedPolicyHaveTests": all(
            marker in tests
            for marker in (
                "testHostClipboardDirectionsDefaultOffAndRemainIndependent",
                "native_host_optional_data_capabilities_require_explicit_clipboard_policy",
                "host_storage_readback_accepts_explicit_clipboard_opt_in_only",
                "enableClipboardRead: false",
                "enableClipboardWrite: false",
            )
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2i1 Host small-text clipboard explicit-policy ABI seam",
        ),
        "hostABIV14": line_number(header, "RDN_HOST_ABI_VERSION 14u"),
        "cReadDirection": line_number(header, "bool enable_clipboard_read;"),
        "cWriteDirection": line_number(header, "bool enable_clipboard_write;"),
        "swiftReadDefault": line_number(
            host_control, "clipboardReadEnabled: Bool = false"
        ),
        "swiftWriteDefault": line_number(
            host_control, "clipboardWriteEnabled: Bool = false"
        ),
        "rustPolicyCopy": line_number(
            bridge, "(*options).enable_clipboard_read"
        ),
        "policyApplication": line_number(
            bridge,
            "apply_native_host_optional_capability_policy(host.clipboard_transfer_policy);",
        ),
        "policyReadback": line_number(
            bridge, "native_host_clipboard_option(clipboard_policy)"
        ),
        "rustPolicyTest": line_number(
            bridge,
            "native_host_optional_data_capabilities_require_explicit_clipboard_policy",
        ),
        "swiftPolicyTest": line_number(
            sources["core_tests"],
            "testHostClipboardDirectionsDefaultOffAndRemainIndependent",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-clipboard-explicit-policy-abi-ready-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-clipboard-explicit-policy-abi-seam",
        "status": status,
        "implementation": {
            "hostABIVersion": rust_abi,
            "evidence": evidence,
            "sourceLines": source_lines,
        },
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostDirectionsRepresentable": True,
            "hostDirectionsDefaultOff": True,
            "hostProductExplicitOptInCapable": True,
            "endToEndSmallTextExplicitOptInCapable": True,
            "richClipboardEnabled": False,
            "richClipboardTransportCapable": True,
            "fileTransferEnabled": False,
            "systemAudioEnabled": False,
        },
        "remainingBoundary": {
            "backgroundBootstrapPropagationRequired": False,
            "homeOptInControlsRequired": False,
            "installedTwoMacAcceptanceRequired": True,
            "richPayloadTransferRequired": False,
        },
        "nextImplementationBoundary": "host-rich-text-bootstrap-home-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-clipboard-explicit-policy-abi-ready-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
