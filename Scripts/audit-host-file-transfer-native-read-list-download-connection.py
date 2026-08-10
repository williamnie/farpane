#!/usr/bin/env python3
"""Audit H6.3e5b Native Host read/list/download connection lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-native-read-list-download-connection-audit"


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
        / "CoreBridge/RustDeskPatch/h6-file-transfer-native-read-list-download.patch",
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
        "designRecordsH63e5bBoundary": all(
            marker in design
            for marker in (
                "H6.3e5b Native Host read/list/download connection lifecycle",
                "host-file-transfer-viewer-destination-progress-api-contract",
            )
        ),
        "virtualRootListsStayOnPinnedOwner": all(
            marker in bridge + connection
            for marker in (
                "native_host_list_directory",
                "native_host_list_empty_directories",
                "native_host_list_files_recursive",
                "send_native_host_directory",
                "send_native_host_empty_directories",
                "send_native_host_all_files",
            )
        ),
        "readJobsAreConnectionOwnedAndBounded": all(
            marker in connection
            for marker in (
                "MAX_NATIVE_HOST_READ_JOBS_PER_CONNECTION: usize = 8",
                "native_host_read_jobs: Vec<crate::rdn_host_bridge::NativeHostReadJob>",
                "begin_native_host_read_job",
                "NativeHostReadJobError::DuplicateJob",
                "NativeHostReadJobError::TooManyJobs",
            )
        ),
        "senderUsesBoundedDigestBlockDoneLifecycle": all(
            marker in bridge + connection
            for marker in (
                "MAX_FILE_TRANSFER_BLOCK_BYTES",
                "NativeHostReadJobStep::Digest",
                "NativeHostReadJobStep::Block",
                "NativeHostReadJobStep::Done",
                "is_upload: false",
                "fs::new_block",
                "fs::new_done",
            )
        ),
        "confirmationIsExplicitAndFailClosed": all(
            marker in bridge + connection
            for marker in (
                "NativeHostReadConfirmation::Skip",
                "NativeHostReadConfirmation::ContinueAt",
                "NativeHostReadJobError::InvalidConfirmation",
                "NativeHostReadJobError::OffsetOutOfRange",
                "native_host_read_confirmation_maps_wire_decisions_fail_closed",
            )
        ),
        "snapshotIsRevalidatedBeforeAndAfterStreaming": all(
            marker in bridge + owner
            for marker in (
                "verify_read_file",
                "open_read_file",
                "self.current_offset != self.entries[self.next_file_num].size()",
                "NativeHostReadJobError::SnapshotChanged",
            )
        ),
        "timerWaitsWithoutBusyPollingAndConfirmationRearms": all(
            marker in connection
            for marker in (
                "!job.is_waiting_for_confirmation()",
                "native_host_read_ready",
                "time::interval_at(Instant::now() + SEC30, SEC30)",
                "self.file_timer = crate::rustdesk_interval(time::interval(MILLI1))",
            )
        ),
        "cancelErrorCloseAndUnbindReleaseOrReject": all(
            marker in bridge + connection
            for marker in (
                "cancel_native_host_read_job",
                "self.native_host_read_jobs.clear()",
                "NativeHostReadJobError::Unavailable",
                "self.native_host_read_jobs.remove(index)",
            )
        ),
        "stableErrorsDoNotExposePaths": all(
            marker in connection
            for marker in (
                'NATIVE_HOST_FILE_READ_REJECTED: &str = "native-file-read-rejected"',
                'NATIVE_HOST_FILE_READ_UNAVAILABLE: &str = "native-file-read-unavailable"',
                "send_native_host_read_failure",
            )
        ),
        "focusedTestsCoverReadLifecycleAndWireMapping": all(
            marker in bridge + connection
            for marker in (
                "native_host_read_lists_virtual_root_recursive_files_and_empty_directories",
                "native_host_read_job_requires_confirmation_and_streams_exact_bounded_suffix",
                "native_host_read_job_skip_snapshot_replacement_and_unbind_fail_closed",
                "native_host_read_confirmation_maps_wire_decisions_fail_closed",
            )
        ),
        "canonicalPatchIsLayeredAndReplayChecked": all(
            marker in patch + bootstrap
            for marker in (
                "h6-file-transfer-native-read-list-download.patch",
                "file_transfer_native_read_patch_file",
                'apply --check --reverse "$file_transfer_native_read_patch_file"',
                "poll_native_host_read_job",
            )
        ),
        "canonicalHostSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_owner"]
        ),
        "architectureRecordsConnectionLifecycleProductOff": all(
            marker in architecture
            for marker in (
                "connection-local",
                "read jobs",
                "snapshot-bound directory",
                "Viewer ABI v13",
                "destination\n  owner",
                "产品能力必须继续保持关闭",
            )
        ),
        "productCallersRemainDisabled": (
            "fileTransferEnabled:" not in product
            and "fileTransferReceiveRoot:" not in product
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e5b Native Host read/list/download connection lifecycle"
        ),
        "readJob": line_number(bridge, "struct NativeHostReadJob"),
        "readAdmission": line_number(bridge, "fn native_host_begin_read_job"),
        "connectionReadJobs": line_number(connection, "native_host_read_jobs:"),
        "connectionBegin": line_number(connection, "fn begin_native_host_read_job"),
        "connectionPoll": line_number(connection, "fn poll_native_host_read_job"),
        "connectionConfirmation": line_number(
            connection, "fn confirm_native_host_read_job"
        ),
        "focusedStreamTest": line_number(
            bridge,
            "native_host_read_job_requires_confirmation_and_streams_exact_bounded_suffix",
        ),
        "wireMappingTest": line_number(
            connection,
            "native_host_read_confirmation_maps_wire_decisions_fail_closed",
        ),
        "canonicalPatch": line_number(patch, "fn poll_native_host_read_job"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "native-read-list-download-connection-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-native-read-list-download-connection",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "nativeReadListSnapshotPrimitiveImplemented": True,
            "nativeReadListDownloadConnectionLifecycleImplemented": status
            == expected_status,
            "viewerDestinationProgressContractImplemented": True,
            "viewerCoreFileTransferABISeamImplemented": True,
            "viewerCoreFileTransferRuntimeImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-viewer-destination-descriptor-owner"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
