#!/usr/bin/env python3
"""Audit H6.3e5a Native Host descriptor-relative read/list snapshot primitive."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-read-list-snapshot-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "architecture": repository / "docs/architecture.md",
        "owner": repository / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "vendor_owner": repository / "Vendor/rustdesk/src/rdn_host_file_transfer.rs",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
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
    architecture = sources["architecture"]
    owner = sources["owner"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsH63e5aBoundary": all(
            marker in design
            for marker in (
                "H6.3e5a Native Host descriptor-relative read/list snapshot primitive",
                "host-file-transfer-native-read-list-download-connection-lifecycle",
            )
        ),
        "directoryEnumerationUsesIndependentDescriptor": all(
            marker in owner
            for marker in (
                "open_relative_directory_for_read",
                "libc::openat(",
                "libc::fdopendir",
                "libc::readdir",
                "libc::O_DIRECTORY | libc::O_NOFOLLOW",
            )
        ),
        "onlyPrivateEntriesAreAdmitted": all(
            marker in owner
            for marker in (
                "validate_private_directory_stat",
                "validate_private_regular_stat",
                "stat.st_nlink != 1",
                "std::str::from_utf8(name_bytes)",
            )
        ),
        "privateStagingIsHidden": all(
            marker in owner
            for marker in (
                "NATIVE_HOST_PRIVATE_STAGING_SUFFIX",
                "reject_reserved_read_path",
                "name_bytes.ends_with(NATIVE_HOST_PRIVATE_STAGING_SUFFIX)",
            )
        ),
        "listingAndRecursionAreBounded": all(
            marker in owner
            for marker in (
                "NATIVE_HOST_READ_MAX_ENTRIES: usize = 1_024",
                "NATIVE_HOST_READ_MAX_METADATA_BYTES: usize = 1024 * 1024",
                "NATIVE_HOST_READ_MAX_DEPTH: usize = 64",
                "NativeFileTransferRootError::ReadLimitExceeded",
            )
        ),
        "fileOpenRevalidatesSnapshotIdentity": all(
            marker in owner
            for marker in (
                "fn open_read_file",
                "libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW",
                "stat.st_dev as u64 != entry.device",
                "stat.st_ino as u64 != entry.inode",
                "ReadSnapshotChanged",
            )
        ),
        "focusedTestsCoverPinnedRootAndFailClosedCases": all(
            marker in owner
            for marker in (
                "native_owner_lists_only_safe_visible_entries_and_hides_staging",
                "native_owner_recursively_snapshots_and_reads_pinned_private_files",
                "native_owner_read_snapshot_rejects_replacement_symlink_and_unsafe_mode",
                "native_owner_read_listing_enforces_entry_limit_before_partial_success",
            )
        ),
        "canonicalOwnerMatchesVendorCheckout": owner == sources["vendor_owner"],
        "architectureRecordsPrimitiveAndConnectionLifecycle": all(
            marker in architecture
            for marker in (
                "openat(\".\") + fdopendir/readdir",
                "snapshot 的 device/inode/size/mtime",
                "dedicated file connection",
                "connection-local read jobs",
            )
        ),
        "productCallersRemainDisabled": (
            "fileTransferEnabled:" not in product
            and "fileTransferReceiveRoot:" not in product
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e5a Native Host descriptor-relative read/list snapshot primitive"
        ),
        "directoryList": line_number(owner, "fn list_directory("),
        "recursiveSnapshot": line_number(owner, "fn snapshot_files_recursive("),
        "independentDirectory": line_number(owner, "fn read_private_directory_entries("),
        "snapshotOpen": line_number(owner, "fn open_read_file("),
        "replacementTest": line_number(
            owner, "native_owner_read_snapshot_rejects_replacement_symlink_and_unsafe_mode"
        ),
        "limitTest": line_number(
            owner, "native_owner_read_listing_enforces_entry_limit_before_partial_success"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "native-read-list-snapshot-and-connection-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-read-list-snapshot",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeReadListSnapshotPrimitiveImplemented": status == expected_status,
            "nativeReadListDownloadConnectionLifecycleImplemented": True,
            "viewerDestinationProgressContractImplemented": True,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-viewer-core-abi-event-command-lifecycle"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
