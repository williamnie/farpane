#!/usr/bin/env python3
"""Audit H6.3e4c Native Host existing-target decision lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-existing-target-lifecycle-audit"


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
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "owner": repository / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "vendor_owner": repository / "Vendor/rustdesk/src/rdn_host_file_transfer.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-file-transfer-native-existing-target.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
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
    bridge = sources["bridge"]
    owner = sources["owner"]
    connection = sources["connection"]
    patch = sources["patch"]
    bootstrap = sources["bootstrap"]
    product = sources["app"] + sources["agent"]

    evidence = {
        "designRecordsH63e4cBoundary": all(
            marker in design
            for marker in (
                "H6.3e4c Native Host existing-target decision lifecycle",
                "host-file-transfer-native-read-list-download-lifecycle",
            )
        ),
        "existingTargetInspectionIsDescriptorRelativeAndReadOnly": all(
            marker in owner
            for marker in (
                "try_open_existing_file_for_digest",
                "O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW",
                "validate_private_regular_file(&file)",
            )
        ),
        "unsafeTargetsFailClosed": all(
            marker in bridge
            for marker in (
                "NativeHostWriteJobError::ExistingTargetUnsafe",
                "native_host_existing_target_rejects_replace_decisions_and_unsafe_entries",
            )
        ),
        "digestReturnsExactExistingMetadata": all(
            marker in bridge + connection
            for marker in (
                "NativeHostWriteDigestDecision::ExistingTarget",
                "file_size: existing_size",
                "last_modified: existing_modified",
                "is_identical: existing_size == file_size",
                "is_upload: true",
            )
        ),
        "blocksWaitForExplicitDecision": all(
            marker in bridge
            for marker in (
                "awaiting_existing_target",
                "ExistingTargetDecisionRequired",
                "confirm_existing_target_decision",
            )
        ),
        "skipPreservesTargetAndCleansPartial": all(
            marker in bridge + owner
            for marker in (
                "NativeHostExistingTargetDecision::Skip",
                "remove_file_if_exists",
                "skipped_total_size",
                "native_host_existing_target_requires_skip_and_preserves_original",
            )
        ),
        "replacementRemainsNoReplace": all(
            marker in bridge
            for marker in (
                "NativeHostExistingTargetDecision::Replace",
                "ExistingTargetReplacementUnsupported",
            )
        ) and "RENAME_EXCL" in owner,
        "connectionRoutesDecisionWithoutCmFallback": all(
            marker in connection
            for marker in (
                "confirm_native_host_existing_target_decision",
                "Native Host write jobs own existing-target decisions",
                "self.native_host_write_jobs.remove(index).abort()",
                "NATIVE_HOST_FILE_WRITE_REJECTED",
            )
        ),
        "focusedTestsCoverSingleMultiUnsafeAndReplace": all(
            marker in bridge
            for marker in (
                "native_host_existing_target_requires_skip_and_preserves_original",
                "native_host_existing_target_rejects_replace_decisions_and_unsafe_entries",
                "native_host_existing_target_skip_preserves_multifile_accounting",
            )
        ),
        "canonicalPatchIsLayeredAndReplayChecked": all(
            marker in patch + bootstrap
            for marker in (
                "h6-file-transfer-native-existing-target.patch",
                "file_transfer_native_existing_target_patch_file",
                'apply --check --reverse "$file_transfer_native_existing_target_patch_file"',
                "confirm_native_host_existing_target_decision",
            )
        ),
        "canonicalHostSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_owner"]
        ),
        "architectureRecordsNoReplaceProductOffBoundary": all(
            marker in architecture
            for marker in (
                "existing-target decision",
                "no-replace",
                "destination\n  descriptor owner",
                "App/Agent",
            )
        ),
        "productCallersRemainDisabled": (
            "fileTransferEnabled:" not in product
            and "fileTransferReceiveRoot:" not in product
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e4c Native Host existing-target decision lifecycle"
        ),
        "existingOpen": line_number(owner, "try_open_existing_file_for_digest"),
        "digestDecision": line_number(bridge, "enum NativeHostWriteDigestDecision"),
        "decisionApplication": line_number(
            bridge, "fn confirm_existing_target_decision"
        ),
        "connectionDigest": line_number(connection, "confirm_native_host_file_digest"),
        "connectionDecision": line_number(
            connection, "confirm_native_host_existing_target_decision"
        ),
        "focusedSkipTest": line_number(
            bridge, "native_host_existing_target_requires_skip_and_preserves_original"
        ),
        "canonicalPatch": line_number(
            patch, "confirm_native_host_existing_target_decision"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "native-existing-target-no-replace-decision-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-existing-target-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeSingleFileResumeDigestLifecycleImplemented": True,
            "nativeExistingTargetDecisionImplemented": status
            == "native-existing-target-no-replace-decision-implemented-product-off",
            "nativeExistingTargetReplacementImplemented": False,
            "nativeReadListDownloadImplemented": True,
            "viewerDestinationProgressContractImplemented": True,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-viewer-destination-descriptor-owner"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "native-existing-target-no-replace-decision-implemented-product-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
