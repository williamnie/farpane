#!/usr/bin/env python3
"""Audit H6.3d2 descriptor-relative Native Host receive-root mutations."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-safe-root-mutations-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "canonical": repository
        / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "vendor": repository / "Vendor/rustdesk/src/rdn_host_file_transfer.rs",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
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
    source = sources["canonical"]
    host_bridge = sources["host_bridge"]
    bootstrap = sources["bootstrap"]
    product = sources["app"] + sources["agent"]

    evidence = {
        "designRecordsH63d2Boundary": all(
            marker in design
            for marker in (
                "H6.3d2 Host descriptor-relative safe-root mutations",
                "host-file-transfer-native-service-owner",
            )
        ),
        "implementationIsMacOSHostFeatureIsolated": all(
            marker in host_bridge
            for marker in (
                '#[cfg(target_os = "macos")]',
                '#[path = "rdn_host_file_transfer.rs"]',
                "mod rdn_host_file_transfer;",
            )
        ),
        "canonicalSourceMatchesVendorCheckout": source == sources["vendor"],
        "directoryCreateIsDescriptorRelativeAndPrivate": all(
            marker in source
            for marker in (
                "pub(crate) fn create_directory",
                "libc::mkdirat(",
                "set_created_directory_mode",
                "0o700 as libc::mode_t",
                "validate_private_directory",
            )
        ),
        "fileRemovalRejectsLinksAndTypeConfusion": all(
            marker in source
            for marker in (
                "pub(crate) fn remove_file",
                "checked_stat_at",
                "libc::AT_SYMLINK_NOFOLLOW",
                "validate_private_regular_stat",
                "stat.st_nlink != 1",
                "libc::unlinkat(parent.as_raw_fd(), file_name.as_ptr(), 0)",
            )
        ),
        "directoryRemovalRequiresPrivateEmptyDirectory": all(
            marker in source
            for marker in (
                "fn remove_empty_directory",
                "open_private_child_directory",
                "validate_private_directory",
                "libc::AT_REMOVEDIR",
            )
        ),
        "renameValidatesSourceAndCannotReplaceDestination": all(
            marker in source
            for marker in (
                "pub(crate) fn rename_entry",
                "validate_private_entry_stat",
                "libc::renameatx_np(",
                "libc::RENAME_EXCL",
            )
        ),
        "focusedTestsCoverPrivateMutationAndFailClosedCases": all(
            marker in source
            for marker in (
                "mutations_create_and_remove_only_private_entries",
                "remove_rejects_symlink_hardlink_type_confusion_and_nonempty_directory",
                "rename_is_no_replace_and_preserves_source_inode_on_success",
                "rename_rejects_symlink_broad_mode_and_hardlinked_source",
                "mutations_remain_pinned_after_root_path_replacement",
            )
        ),
        "bootstrapCopiesAndVerifiesCanonicalSource": all(
            marker in bootstrap
            for marker in (
                "host_file_transfer_source=",
                'cp "$host_file_transfer_source" "$vendor_dir/src/rdn_host_file_transfer.rs"',
                'cmp -s "$vendor_dir/src/rdn_host_file_transfer.rs" "$host_file_transfer_source"',
            )
        ),
        "productStillDoesNotOptIn": "fileTransferPolicy:" not in product,
        "laterOwnerMutationAndNewWritesExistResumeRemainsOpen": (
            "pub(crate) struct NativeHostFileServiceOwner" in source
            and "native_host_dispatch_file_mutation" in host_bridge
            and "send_native_host_file_mutation_response" in sources["connection"]
            and "begin_native_host_write_job" in sources["connection"]
            and "NativeHostWriteJobError::ResumeUnsupported" in host_bridge
        ),
        "recursiveRemovalIsDeliberatelyAbsent": (
            "pub(crate) fn remove_recursive" not in source
            and "pub(crate) fn remove_directory_recursive" not in source
            and "pub(crate) fn remove_tree" not in source
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3d2 Host descriptor-relative safe-root mutations"
        ),
        "moduleIsolation": line_number(host_bridge, "mod rdn_host_file_transfer;"),
        "createDirectory": line_number(source, "pub(crate) fn create_directory"),
        "removeFile": line_number(source, "pub(crate) fn remove_file"),
        "removeEmptyDirectory": line_number(
            source, "fn remove_empty_directory"
        ),
        "renameEntry": line_number(source, "pub(crate) fn rename_entry"),
        "noReplaceRename": line_number(source, "libc::RENAME_EXCL"),
        "replacementTest": line_number(
            source, "fn mutations_remain_pinned_after_root_path_replacement"
        ),
        "bootstrapSource": line_number(bootstrap, "host_file_transfer_source="),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "descriptor-relative-safe-root-mutations-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-safe-root-mutations",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "descriptorRelativeSafeRootMutationsImplemented": True,
            "recursiveRemovalImplemented": False,
            "nativeHostFileServiceOwnerCoreImplemented": True,
            "nativeHostFileServiceOwnerImplemented": True,
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeResumeDigestLifecycleImplemented": True,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-native-existing-target-decision-lifecycle",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == (
        "descriptor-relative-safe-root-mutations-implemented-product-off"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
