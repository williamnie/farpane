#!/usr/bin/env python3
"""Audit H6.3f2b2n Viewer download wire-request lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-download-wire-request-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-download-digest-confirmation-lifecycle"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def function_body(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset < 0:
        return ""
    return source[start_offset:end_offset]


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "architecture": repository / "docs/architecture.md",
        "readme": repository / "CoreBridge/README.md",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
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

    bridge = sources["bridge"]
    product = sources["app"] + sources["agent"]
    message = function_body(
        bridge,
        "fn native_viewer_file_download_root_message(",
        "fn client_clear_completed_manifest(",
    )
    start = function_body(
        bridge,
        'pub unsafe extern "C" fn rdn_client_file_transfer_download_start(',
        "struct PacketInspection",
    )
    regression = function_body(
        bridge,
        "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
        "fn viewer_download_progress_and_terminal_callbacks_are_monotonic_and_stable()",
    )
    insert_offset = start.find("jobs.insert(request.transfer_id, job)")
    send_offset = start.find("sender\n        .send(Data::Message")
    rollback_offset = start.find("jobs.remove(&request.transfer_id)")
    evidence = {
        "designRecordsBoundedH63f2b2n": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2n Viewer download wire-request lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "wireMessageIsCanonicalRootSendWithoutLocalWriteJob": all(
            marker in message
            for marker in (
                "hbb_common::fs::new_send(",
                "transfer_id",
                "hbb_common::fs::JobType::Generic",
                '"/".to_owned()',
                "0",
                "false",
            )
        ) and "Data::SendFiles" not in message + start,
        "startRetainsExactLifecycleAndManifestAdmission": all(
            marker in start
            for marker in (
                "request.session_epoch == 0",
                "request.manifest_request_id <= 0",
                "request.transfer_id <= 0",
                "MAX_FILE_TRANSFER_LIST_ENTRIES",
                "file_transfer_session_epoch",
                "authenticated.load(Ordering::Acquire)",
                "completed_file_manifest_request",
                "NativeViewerCompletedManifest",
                "server_file_transfer_enabled",
                "MAX_VIEWER_DOWNLOAD_JOBS",
                "jobs.contains_key(&request.transfer_id)",
            )
        ),
        "registrationPrecedesSingleDispatchAndClosedQueueRollsBack": (
            insert_offset >= 0
            and send_offset > insert_offset
            and rollback_offset > send_offset
            and "native_viewer_file_download_root_message" in start
            and "return -3;" in start[rollback_offset:]
        ),
        "regressionCoversWireShapeSingleDispatchAndRollback": all(
            marker in regression
            for marker in (
                "file_action::Union::Send(send)",
                "send.id",
                "send.path.as_str()",
                "send.file_num",
                "send.include_hidden",
                "file_transfer_send_request::FileType::Generic",
                "rejected or duplicate starts must not dispatch another request",
                "viewer_download_start_rolls_back_registration_when_wire_queue_is_closed",
                "drop(receiver)",
                ".active_file_download_jobs",
                ".is_empty()",
            )
        ),
        "destinationAdapterAndProductRemainOff": (
            "pwrite" not in start + message
            and "reserveNewFile" not in start + message
            and "writePayload" not in start + message
            and "commitReservation" not in start + message
            and "startFileTransferDownload(" not in product
            and "onFileTransferReceiveBlock:" not in product
            and "Overwrite-digest confirmation" in sources["readme"]
            and "overwrite digest confirmation" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2n Viewer download wire-request lifecycle",
        ),
        "wireMessage": line_number(bridge, "fn native_viewer_file_download_root_message("),
        "downloadStart": line_number(
            bridge,
            "fn rdn_client_file_transfer_download_start(",
        ),
        "wireRegression": line_number(
            bridge,
            "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
        ),
        "rollbackRegression": line_number(
            bridge,
            "fn viewer_download_start_rolls_back_registration_when_wire_queue_is_closed()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-download-wire-request-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-download-wire-request-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerIOLoopReceiveInterceptionImplemented": status == expected_status,
            "viewerDownloadWireRequestImplemented": status == expected_status,
            "viewerDestinationWriteAdapterImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
