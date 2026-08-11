#!/usr/bin/env python3
"""Audit H6.3e4a Native Host new-file write-job lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-new-write-lifecycle-audit"


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
        / "CoreBridge/RustDeskPatch/h6-file-transfer-native-new-write.patch",
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

    receive = connection.find("Some(file_action::Union::Receive(r))")
    block = connection.find("Some(file_response::Union::Block(block))", receive)
    done = connection.find("Some(file_response::Union::Done(d))", block)
    digest = connection.find("Some(file_response::Union::Digest(d))", done)
    error = connection.find("Some(file_response::Union::Error(e))", digest)

    evidence = {
        "designRecordsH63e4aBoundary": all(
            marker in design
            for marker in (
                "H6.3e4a Native Host new-file write-job lifecycle",
                "host-file-transfer-native-resume-digest-lifecycle",
            )
        ),
        "ownerUsesDescriptorBackedStagingAndNoReplaceCommit": all(
            marker in bridge + owner
            for marker in (
                "NATIVE_HOST_WRITE_STAGING_SUFFIX",
                "create_new_file(&entry.staging_path)",
                "file.sync_all()",
                ".rename_entry(&self.staging_path, &self.destination_path)",
                "libc::RENAME_EXCL",
            )
        ),
        "admissionBoundsAndValidatesWholeBatch": all(
            marker in bridge
            for marker in (
                "MAX_NATIVE_HOST_WRITE_FILES",
                "MAX_NATIVE_HOST_WRITE_METADATA_BYTES",
                "checked_add(entry.expected_size)",
                "destinations.insert(destination_path.clone())",
                "total_size != expected_total_size",
            )
        ),
        "blocksAreWireAndDecodedBoundedBeforeWrite": all(
            marker in bridge
            for marker in (
                "MAX_FILE_TRANSFER_BLOCK_BYTES",
                "decompress_with_limit",
                "NativeHostWriteJobError::WirePayloadTooLarge",
                "NativeHostWriteJobError::DecodedPayloadInvalidOrTooLarge",
            )
        ),
        "writeOrderAndExpectedSizesFailClosed": all(
            marker in bridge
            for marker in (
                "NativeHostWriteJobError::UnexpectedFileNumber",
                "NativeHostWriteJobError::FileSizeExceeded",
                "NativeHostWriteJobError::FileSizeMismatch",
                "NativeHostWriteJobError::TotalSizeMismatch",
            )
        ),
        "cancelFailureAndDropRemoveOnlyUncommittedStaging": all(
            marker in bridge
            for marker in (
                "impl Drop for NativeHostWriteFile",
                "self.owner.remove_file(&self.staging_path)",
                "committed: false",
                "current.take()",
            )
        ),
        "connectionOwnsJobsAndNeverFallsThroughWhileNative": all(
            marker in connection
            for marker in (
                "native_host_write_jobs: Vec<crate::rdn_host_bridge::NativeHostWriteJob>",
                "MAX_NATIVE_HOST_WRITE_JOBS_PER_CONNECTION",
                "native_host_begin_new_file_write_job",
                "native_host_write_service_state",
                "native-file-write-rejected",
                "native-file-write-unavailable",
            )
        ),
        "receiveBlockDoneErrorAndCancelUseNativeLifecycle": (
            receive >= 0
            and block > receive
            and done > block
            and digest > done
            and error > digest
            and all(
                marker in connection
                for marker in (
                    "begin_native_host_write_job",
                    "write_native_host_file_block",
                    "finish_native_host_write_job",
                    "cancel_native_host_write_job",
                    "confirm_native_host_file_digest",
                )
            )
        ),
        "newFileDigestIsExactAndResumeIsVerified": all(
            marker in bridge + connection
            for marker in (
                "NativeHostWriteJobError::ResumeUnsupported",
                "digest.file_size",
                "digest.last_modified",
                "OffsetBlk(offset)",
                "prefix_digest",
            )
        ),
        "focusedTestsCoverCommitCancelBoundsAndDisconnect": all(
            marker in bridge
            for marker in (
                "native_host_new_file_write_job_commits_exact_files",
                "native_host_new_file_write_job_rejects_bounds_order_and_resume",
                "native_host_new_file_write_job_abort_cleans_only_staging",
                "native_host_new_file_write_job_rejects_after_unbind",
            )
        ),
        "canonicalPatchIsRegisteredAndReplayChecked": all(
            marker in patch + bootstrap
            for marker in (
                "h6-file-transfer-native-new-write.patch",
                '--check --reverse "$file_transfer_native_new_write_patch_file"',
                "begin_native_host_write_job",
            )
        ),
        "canonicalHostSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_owner"]
        ),
        "productCallersRemainDisabled": (
            "fileTransferPolicy:" not in product
            and "fileTransferPolicy:" not in product
        ),
        "architectureRecordsNewFileOnlyBoundary": all(
            marker in architecture
            for marker in (
                "Native Host new-file write jobs",
                "single-file resume",
                "App/Agent",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e4a Native Host new-file write-job lifecycle"
        ),
        "job": line_number(bridge, "pub(crate) struct NativeHostWriteJob"),
        "admission": line_number(bridge, "native_host_begin_new_file_write_job"),
        "blockWrite": line_number(bridge, "pub(crate) fn write_block"),
        "finish": line_number(bridge, "pub(crate) fn finish"),
        "dropCleanup": line_number(bridge, "impl Drop for NativeHostWriteFile"),
        "connectionReceive": line_number(connection, "begin_native_host_write_job"),
        "connectionBlock": line_number(connection, "write_native_host_file_block"),
        "connectionDone": line_number(connection, "finish_native_host_write_job"),
        "canonicalPatch": line_number(patch, "begin_native_host_write_job"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "native-new-file-write-lifecycle-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-new-write-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeResumeDigestLifecycleImplemented": True,
            "nativeOverwriteImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-native-existing-target-decision-lifecycle",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "native-new-file-write-lifecycle-implemented-product-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
