#!/usr/bin/env python3
"""Audit H6.3e4b Native Host single-file resume/digest lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-resume-digest-lifecycle-audit"


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
        / "CoreBridge/RustDeskPatch/h6-file-transfer-native-resume-digest.patch",
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
        "designRecordsH63e4bBoundary": all(
            marker in design
            for marker in (
                "H6.3e4b Native Host single-file resume/digest lifecycle",
                "host-file-transfer-native-existing-target-decision-lifecycle",
            )
        ),
        "resumeOpensOnlyDescriptorValidatedPrivateStaging": all(
            marker in owner + bridge
            for marker in (
                "try_open_existing_file_for_resume",
                "O_RDWR | libc::O_NONBLOCK | libc::O_NOFOLLOW",
                "validate_private_regular_file(&file)",
                "NativeHostWriteFile::resume",
            )
        ),
        "checkpointBindsMetadataOffsetAndPrefixDigest": all(
            marker in bridge
            for marker in (
                "NATIVE_HOST_RESUME_XATTR_NAME",
                "NATIVE_HOST_RESUME_METADATA_MAGIC",
                "expected_size",
                "modified_time",
                "committed_size",
                "prefix_digest",
                "Sha256",
            )
        ),
        "checkpointIsDurableBeforeOffsetIsAdvertised": all(
            marker in bridge
            for marker in (
                "native_host_write_resume_metadata",
                "native_host_set_resume_metadata",
                "file.sync_all()",
                "native_host_read_and_verify_resume_prefix",
            )
        ),
        "resumeIsSingleFileExactAndUint32Bounded": all(
            marker in bridge
            for marker in (
                "NativeHostWriteJobError::ResumeUnsupported",
                "self.entries.len() != 1",
                "u32::try_from(resumed.written_size)",
                "entry.expected_size != file_size",
                "entry.modified_time != last_modified",
            )
        ),
        "concurrentJobsCannotShareAStagingPath": all(
            marker in owner + bridge
            for marker in (
                "reserve_write_paths",
                "NativeHostWriteReservations",
                "NativeFileTransferRootError::WritePathBusy",
                "_reservations:",
                "native_host_write_job_reserves_staging_path_until_drop",
            )
        ),
        "disconnectPreservesButExplicitAbortCleansStaging": all(
            marker in bridge + connection
            for marker in (
                "preserve_for_resume",
                "pub(crate) fn abort",
                "job.abort()",
                "cancel_native_host_write_job",
            )
        ),
        "connectionReturnsVerifiedOffsetNotConstantZero": all(
            marker in connection
            for marker in (
                "let decision = self.native_host_write_jobs[index].confirm_file_digest",
                "NativeHostWriteDigestDecision::ConfirmedOffset(offset)",
                "file_transfer_send_confirm_request::Union::OffsetBlk(offset)",
            )
        ) and "confirm_native_host_new_file_digest" not in connection,
        "focusedTestsCoverResumeTamperAbortAndUnbind": all(
            marker in bridge
            for marker in (
                "native_host_single_file_resume_reuses_verified_checkpoint",
                "native_host_resume_rejects_tampered_or_mismatched_checkpoint",
                "native_host_resume_abort_removes_checkpointed_staging",
                "native_host_resume_rejects_after_unbind",
                "native_host_write_job_reserves_staging_path_until_drop",
            )
        ),
        "canonicalPatchIsLayeredAndReplayChecked": all(
            marker in patch + bootstrap
            for marker in (
                "h6-file-transfer-native-resume-digest.patch",
                "file_transfer_native_resume_digest_patch_file",
                '--check --reverse "$file_transfer_native_resume_digest_patch_file"',
                "confirm_file_digest",
            )
        ),
        "canonicalHostSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_owner"]
        ),
        "architectureRecordsResumeOnlyBoundary": all(
            marker in architecture
            for marker in (
                "single-file resume",
                "UInt32",
                "existing-target decision",
                "App/Agent",
            )
        ),
        "productCallersRemainDisabled": (
            "fileTransferPolicy:" not in product
            and "fileTransferPolicy:" not in product
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e4b Native Host single-file resume/digest lifecycle"
        ),
        "resumeOpen": line_number(owner, "try_open_existing_file_for_resume"),
        "resumeMetadata": line_number(bridge, "struct NativeHostResumeMetadata"),
        "resumeFile": line_number(bridge, "fn resume("),
        "digestConfirmation": line_number(bridge, "pub(crate) fn confirm_file_digest"),
        "abort": line_number(bridge, "pub(crate) fn abort"),
        "connectionDigest": line_number(connection, "confirm_native_host_file_digest"),
        "focusedResumeTest": line_number(
            bridge, "native_host_single_file_resume_reuses_verified_checkpoint"
        ),
        "canonicalPatch": line_number(patch, "confirm_file_digest"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "native-single-file-resume-digest-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-resume-digest-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeSingleFileResumeDigestLifecycleImplemented": status
            == "native-single-file-resume-digest-implemented-product-off",
            "nativeMultiFileResumeImplemented": False,
            "nativeExistingTargetDecisionImplemented": False,
            "nativeReadListDownloadImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-native-existing-target-decision-lifecycle"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "native-single-file-resume-digest-implemented-product-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
