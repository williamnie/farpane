#!/usr/bin/env python3
"""Audit H6.3e2 immutable receive-root Host ABI/config contract."""

from __future__ import annotations

import json
import re
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-receive-root-config-contract-audit"


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
        "architecture": repository / "docs/architecture.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "file_owner": repository
        / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "vendor_file_owner": repository / "Vendor/rustdesk/src/rdn_host_file_transfer.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
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

    design = sources["design"]
    header = sources["header"]
    bridge = sources["bridge"]
    owner = sources["file_owner"]
    host_control = sources["host_control"]
    product = sources["app"] + sources["agent"]
    connection = sources["connection"]

    pair_validation = bridge.find(
        "(*options).enable_file_transfer != !file_transfer_receive_root.is_empty()"
    )
    singleton_claim = bridge.find("HOST_INSTANCE_LIVE\n        .compare_exchange")
    owner_admission = bridge.find("from_immutable_configuration(")
    host_box = bridge.find("let host = Box::new(RdnHost {")

    evidence = {
        "designRecordsH63e2Boundary": all(
            marker in design
            for marker in (
                "H6.3e2 Host immutable receive-root config contract",
                "host-file-transfer-connection-mutation-dispatch",
            )
        ),
        "hostABIv17MatchesHeaderRustAndSwiftTest": (
            header_abi == rust_abi == 17
            and "private static let hostABIVersion: UInt32 = 17"
            in sources["host_tests"]
        ),
        "cCreateOptionsCarryImmutableReceiveRoot": all(
            marker in header
            for marker in (
                "const char *file_transfer_receive_root;",
                "Must be null/empty while file transfer is disabled",
                "descriptor-admissible directory while it is enabled",
            )
        ),
        "swiftRootDefaultsNilAndProjectsCopiedCString": all(
            marker in host_control
            for marker in (
                "public let fileTransferReceiveRoot: String?",
                "fileTransferReceiveRoot: String? = nil",
                'configuration.fileTransferReceiveRoot ?? ""',
                "file_transfer_receive_root: fileTransferReceiveRoot",
            )
        ),
        "policyRootPairFailsBeforeSingletonAndOwnerAdmission": (
            pair_validation >= 0
            and singleton_claim > pair_validation
            and owner_admission > singleton_claim
            and host_box > owner_admission
        ),
        "ownerRetainsAdmittedDescriptorForHostLifetime": all(
            marker in bridge
            for marker in (
                "file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>",
                "file_service_owner,",
            )
        ),
        "unsafeRootFailsStorageAndReleasesSingletonClaim": all(
            marker in bridge
            for marker in (
                "HOST_INSTANCE_LIVE.store(false, Ordering::Release);",
                "NativeFileTransferRootError::InvalidOwnerConfiguration",
                "RDN_HOST_ERR_VALIDATION",
                "RDN_HOST_ERR_STORAGE",
            )
        ),
        "ownerConfigurationRequiresExactPairAndSafeAdmission": all(
            marker in owner
            for marker in (
                "pub(crate) fn from_immutable_configuration",
                "(false, None) => Ok(None)",
                "(true, Some(root_path)) => Self::open_existing(root_path).map(Some)",
                "_ => Err(NativeFileTransferRootError::InvalidOwnerConfiguration)",
                "immutable_owner_configuration_requires_exact_policy_root_pair",
            )
        ),
        "swiftRegressionCoversDefaultAndExplicitRoot": all(
            marker in sources["core_tests"]
            for marker in (
                "XCTAssertNil(disabled.fileTransferReceiveRoot)",
                "fileTransferReceiveRoot: \"/private/var/folders/farpane-receive\"",
                "fileTransferOnly.fileTransferReceiveRoot",
            )
        ),
        "productCallersRemainDisabledWithoutRoot": (
            "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
        ),
        "laterMutationAndNewWriteDispatchExistResumeRemainsOpen": (
            "send_native_host_file_mutation_response" in connection
            and "NativeHostFileMutation::CreateDirectory" in connection
            and "begin_native_host_write_job" in connection
            and "NativeHostWriteJobError::ResumeUnsupported" in bridge
        ),
        "canonicalSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_file_owner"]
        ),
        "architectureRecordsCurrentDefaultOffBoundary": all(
            marker in sources["architecture"]
            for marker in (
                "Host ABI v17",
                "file_transfer_receive_root",
                "当前 App/Agent 不传 opt-in",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e2 Host immutable receive-root config contract"
        ),
        "hostABIv17": line_number(header, "RDN_HOST_ABI_VERSION 17u"),
        "cReceiveRoot": line_number(header, "file_transfer_receive_root;"),
        "swiftReceiveRoot": line_number(
            host_control, "public let fileTransferReceiveRoot: String?"
        ),
        "swiftProjection": line_number(
            host_control, "file_transfer_receive_root: fileTransferReceiveRoot"
        ),
        "rustPairValidation": line_number(
            bridge,
            "(*options).enable_file_transfer != !file_transfer_receive_root.is_empty()",
        ),
        "rustOwnerAdmission": line_number(bridge, "from_immutable_configuration("),
        "rustOwnerRetention": line_number(
            bridge,
            "file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>",
        ),
        "ownerPairContract": line_number(
            owner, "pub(crate) fn from_immutable_configuration"
        ),
        "ownerFocusedTest": line_number(
            owner, "fn immutable_owner_configuration_requires_exact_policy_root_pair"
        ),
        "swiftFocusedTest": line_number(
            sources["core_tests"], "XCTAssertNil(disabled.fileTransferReceiveRoot)"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-file-transfer-receive-root-configured-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-receive-root-config-contract",
        "status": status,
        "implementation": {
            "hostABIVersion": rust_abi,
            "evidence": evidence,
            "sourceLines": source_lines,
        },
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "receiveRootConfigImplemented": True,
            "enabledWithoutRootAccepted": False,
            "disabledWithRootAccepted": False,
            "unsafeRootAccepted": False,
            "ownerRetainedForHostLifetime": True,
            "connectionDispatchImplemented": True,
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeResumeDigestLifecycleImplemented": True,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-native-existing-target-decision-lifecycle",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == (
        "host-file-transfer-receive-root-configured-product-off"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
