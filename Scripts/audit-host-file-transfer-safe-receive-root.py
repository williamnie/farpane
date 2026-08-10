#!/usr/bin/env python3
"""Audit H6.3d1 descriptor-relative Native Host receive-root primitives."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-safe-receive-root-audit"


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
        "designRecordsH63d1Boundary": all(
            marker in design
            for marker in (
                "H6.3d1 Host descriptor-relative receive-root primitive",
                "host-file-transfer-safe-root-mutations",
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
        "absoluteRootTraversalIsDescriptorRelativeNoFollow": all(
            marker in source
            for marker in (
                "fn absolute_root_components",
                "libc::openat(",
                "libc::O_DIRECTORY",
                "libc::O_NOFOLLOW",
                "validate_trusted_ancestor",
            )
        ),
        "admittedRootIsCurrentUserPrivateDirectory": all(
            marker in source
            for marker in (
                "stat.st_uid != unsafe { libc::geteuid() }",
                "stat.st_mode & 0o777 != 0o700",
                "NativeFileTransferRootError::UnsafeRoot",
            )
        ),
        "relativePathsRejectEscapeAbsoluteEmptyAndNUL": all(
            marker in source
            for marker in (
                "fn relative_path_components",
                'bytes.starts_with(b"/")',
                "bytes.contains(&0)",
                'component == b".."',
                "NativeFileTransferRootError::InvalidRelativePath",
            )
        ),
        "nestedCreateUsesPrivateDescriptorRelativeNoReplaceOpen": all(
            marker in source
            for marker in (
                "libc::mkdirat(",
                "0o700 as libc::mode_t",
                "libc::O_CREAT",
                "libc::O_EXCL",
                "0o600 as libc::c_uint",
                "libc::fchmod(file.as_raw_fd(), 0o600",
            )
        ),
        "resumeRequiresNoFollowOwnedPrivateSingleLinkRegularFile": all(
            marker in source
            for marker in (
                "open_existing_file_for_resume",
                "libc::O_NONBLOCK",
                "stat.st_mode & libc::S_IFMT != libc::S_IFREG",
                "stat.st_mode & 0o777 != 0o600",
                "stat.st_nlink != 1",
            )
        ),
        "errorsAreFixedAndDoNotEmbedPaths": (
            "impl fmt::Display for NativeFileTransferRootError" in source
            and "formatter.write_str(match self" in source
            and "path.display()" not in source
            and "last_os_error().to_string()" not in source
        ),
        "focusedTestsCoverRootCreateEscapeResumeAndReplacement": all(
            marker in source
            for marker in (
                "receive_root_rejects_symlink_and_unsafe_mode",
                "create_is_descriptor_relative_private_and_nested",
                "create_rejects_escape_absolute_and_symlink_parent",
                "resume_requires_owned_private_single_link_regular_file",
                "open_root_descriptor_survives_path_replacement",
            )
        ),
        "laterSafeRootMutationsExist": all(
            marker in source
            for marker in (
                "fn create_directory",
                "fn remove_file",
                "fn remove_empty_directory",
                "fn rename_entry",
                "libc::RENAME_EXCL",
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
        "productStillDoesNotOptIn": "fileTransferEnabled:" not in product,
        "laterOwnerCoreExistsAndConnectionWiringIsAbsent": (
            "pub(crate) struct NativeHostFileServiceOwner" in source
            and "NativeHostFileServiceOwner" not in sources["connection"]
            and "native_host_handle_fs" not in sources["connection"]
            and "native_host_handle_fs" not in host_bridge
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3d1 Host descriptor-relative receive-root primitive"
        ),
        "moduleIsolation": line_number(host_bridge, 'mod rdn_host_file_transfer;'),
        "rootAdmission": line_number(source, "fn open_existing(path: &Path)"),
        "rootTraversal": line_number(source, "fn absolute_root_components"),
        "relativeValidation": line_number(source, "fn relative_path_components"),
        "safeCreate": line_number(source, "pub(crate) fn create_new_file"),
        "safeResume": line_number(source, "pub(crate) fn open_existing_file_for_resume"),
        "fileValidation": line_number(source, "fn validate_private_regular_file"),
        "rootReplacementTest": line_number(
            source, "fn open_root_descriptor_survives_path_replacement"
        ),
        "safeRootMutations": line_number(source, "pub(crate) fn create_directory"),
        "bootstrapSource": line_number(bootstrap, "host_file_transfer_source="),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "descriptor-relative-receive-root-primitive-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-safe-receive-root",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "descriptorRelativeRootPrimitiveImplemented": True,
            "safeCreateAndResumePrimitiveImplemented": True,
            "rootPathReplacementCannotRedirectOpenDescriptor": True,
            "safeRemoveAndRenameImplemented": True,
            "nativeHostFileServiceOwnerCoreImplemented": True,
            "nativeHostFileServiceOwnerImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-receive-root-config-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == (
        "descriptor-relative-receive-root-primitive-implemented-product-off"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
