#!/usr/bin/env python3
"""Audit H6.3e1 Native Host file-service owner core composition."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-owner-core-audit"


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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
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
    connection = sources["connection"]
    product = sources["app"] + sources["agent"]

    evidence = {
        "designRecordsH63e1Boundary": all(
            marker in design
            for marker in (
                "H6.3e1 Native Host file-service owner core",
                "host-file-transfer-receive-root-config-contract",
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
        "ownerIsOnlyModuleVisibleRootAuthority": all(
            marker in source
            for marker in (
                "pub(crate) struct NativeHostFileServiceOwner",
                "struct NativeFileTransferRoot",
                "root: NativeFileTransferRoot",
            )
        ) and "pub(crate) struct NativeFileTransferRoot" not in source,
        "ownerAdmissionUsesSafeRoot": all(
            marker in source
            for marker in (
                "impl NativeHostFileServiceOwner",
                "pub(crate) fn open_existing(root_path: &Path)",
                "root: NativeFileTransferRoot::open_existing(root_path)?",
            )
        ),
        "ownerRoutesEverySafeRootOperation": all(
            marker in source
            for marker in (
                "self.root.create_new_file(relative_path)",
                "self.root.open_existing_file_for_resume(relative_path)",
                "self.root.create_directory(relative_path)",
                "self.root.remove_file(relative_path)",
                "self.root.remove_empty_directory(relative_path)",
                "self.root.rename_entry(source, destination)",
            )
        ),
        "recursiveRemovalFailsClosedBeforeMutation": all(
            marker in source
            for marker in (
                "if recursive {",
                "NativeFileTransferRootError::RecursiveRemovalUnsupported",
                "native_owner_rejects_recursive_remove_without_touching_tree",
            )
        ),
        "focusedTestsCoverOwnerComposition": all(
            marker in source
            for marker in (
                "native_owner_is_the_single_safe_root_mutation_authority",
                "native_owner_rejects_recursive_remove_without_touching_tree",
            )
        ),
        "errorsRemainFixedAndPathFree": (
            "impl fmt::Display for NativeFileTransferRootError" in source
            and "path.display()" not in source
            and "last_os_error().to_string()" not in source
        ),
        "bootstrapCopiesAndVerifiesCanonicalSource": all(
            marker in bootstrap
            for marker in (
                "host_file_transfer_source=",
                'cp "$host_file_transfer_source" "$vendor_dir/src/rdn_host_file_transfer.rs"',
                'cmp -s "$vendor_dir/src/rdn_host_file_transfer.rs" "$host_file_transfer_source"',
            )
        ),
        "receiveRootConfigAndConnectionWiringRemainAbsent": (
            "file_transfer_root" not in sources["header"]
            and "NativeHostFileServiceOwner" not in connection
            and "native_host_handle_fs" not in connection
        ),
        "productStillDoesNotOptIn": "fileTransferEnabled:" not in product,
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e1 Native Host file-service owner core"
        ),
        "moduleIsolation": line_number(host_bridge, "mod rdn_host_file_transfer;"),
        "owner": line_number(source, "pub(crate) struct NativeHostFileServiceOwner"),
        "ownerAdmission": line_number(
            source, "pub(crate) fn open_existing(root_path: &Path)"
        ),
        "privateRoot": line_number(source, "struct NativeFileTransferRoot"),
        "ownerCreate": line_number(source, "self.root.create_new_file(relative_path)"),
        "ownerRemove": line_number(
            source, "self.root.remove_empty_directory(relative_path)"
        ),
        "ownerRename": line_number(source, "self.root.rename_entry(source, destination)"),
        "recursiveGuard": line_number(source, "if recursive {"),
        "focusedTests": line_number(
            source, "fn native_owner_is_the_single_safe_root_mutation_authority"
        ),
        "bootstrapSource": line_number(bootstrap, "host_file_transfer_source="),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "native-file-service-owner-core-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-owner-core",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeHostFileServiceOwnerCoreImplemented": True,
            "safeRootImplementationModuleVisible": False,
            "recursiveRemovalImplemented": False,
            "receiveRootConfigImplemented": False,
            "connectionDispatchImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-receive-root-config-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == (
        "native-file-service-owner-core-implemented-product-off"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
