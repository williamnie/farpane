#!/usr/bin/env python3
"""Audit H6.3f2b2g Viewer download progress/terminal callback lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-download-progress-terminal-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-safe-staging-reservation-lifecycle"


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
        "contract": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferContractTests.swift",
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
    swift = sources["swift"]
    contract = sources["contract"]
    product = sources["app"] + sources["agent"]
    progress = function_body(bridge, "fn job_progress(&self,", "fn adapt_size(&self)")
    done = function_body(bridge, "fn job_done(&self,", "fn clear_all_jobs(&self)")
    error = function_body(bridge, "fn job_error(&self,", "fn job_done(&self,")
    cancel = function_body(
        bridge,
        "pub unsafe extern \"C\" fn rdn_client_file_transfer_cancel(",
        "pub unsafe extern \"C\" fn rdn_client_file_transfer_list_root(",
    )
    download_job = function_body(
        bridge,
        "struct NativeViewerDownloadJob",
        "#[repr(C)]\n#[derive(Clone, Copy)]\npub struct RDNCallbacks",
    )
    callback = function_body(
        swift,
        "private let fileTransferEventCallback:",
        "private let fileTransferListCallback:",
    )
    evidence = {
        "designRecordsBoundedH63f2b2g": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2g Viewer download progress/terminal lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "rustProgressIsExactSessionMonotonicAndBounded": all(
            marker in download_job
            for marker in (
                "sequence.checked_add(1)?",
                "files_completed < self.files_completed",
                "bytes_completed < self.bytes_completed",
                "bytes_completed > self.total_bytes",
                "files_completed > self.total_files",
                "finished_size > self.total_bytes as f64",
                "FILE_TRANSFER_EVENT_PROGRESS",
            )
        ) and all(
            marker in bridge
            for marker in (
                "fn emit_file_transfer_event(&self, event: NativeViewerDownloadEvent)",
                "file_transfer_session_epoch.load(Ordering::Acquire) != event.session_epoch",
                "self.callbacks.on_file_transfer_event",
            )
        ),
        "rustTerminalCallbacksAreStableAndReleaseJobs": all(
            marker in done + error + cancel
            for marker in (
                ".remove(&id)",
                "FILE_TRANSFER_EVENT_COMPLETED",
                "FILE_TRANSFER_EVENT_FAILED",
                "FILE_TRANSFER_FAILURE_UNAVAILABLE",
                ".remove(&transfer_id)",
                "FILE_TRANSFER_EVENT_CANCELLED",
            )
        ) and "_error: String" in error and "raw remote detail" not in error,
        "callbacksRunAfterJobLockIsReleased": (
            ".and_then(|job| job.progress(file_num, speed, finished_size));\n        if let Some(event)"
            in progress
            and ".and_then(|job| {\n                job.terminal" in done
            and "if let Some(event)" in done
            and "if let Some(event)" in error
            and "if let Some(event)" in cancel
        ),
        "swiftCallbackUsesOneStrictSemanticInitializer": all(
            marker in callback
            for marker in (
                "let event = CoreFileTransferEvent(",
                "raw.current_file_number >= -1",
                "box.deliverFileTransferEvent(event)",
            )
        ) and all(
            marker in swift
            for marker in (
                "public struct CoreFileTransferEvent: Equatable, Sendable",
                "filesCompleted <= totalFiles",
                "bytesCompleted <= totalBytes",
                "bytesPerSecond.isFinite",
                "filesCompleted == totalFiles",
                "bytesCompleted == totalBytes",
                "guard failure != .none, currentFileNumber == nil",
            )
        ),
        "swiftProjectionMapsOnlyTypedViewerUpdates": all(
            marker in contract
            for marker in (
                "package var viewerProgressUpdate: ViewerFileTransferProgressUpdate?",
                "phase = .transferring",
                "phase = .waitingForConflict",
                "phase = .completed",
                "phase = .cancelled",
                "phase = .failed(stableFailure)",
                "private extension CoreFileTransferFailure",
            )
        ),
        "regressionsCoverProgressTerminalCancelAndMalformedEvents": all(
            marker in bridge + sources["swift_tests"]
            for marker in (
                "viewer_download_progress_and_terminal_callbacks_are_monotonic_and_stable",
                "ui.job_progress(61, -1, 7.5, 9.0)",
                "FILE_TRANSFER_FAILURE_UNAVAILABLE",
                "FILE_TRANSFER_EVENT_CANCELLED",
                "testCoreProgressEventValidatesAndProjectsStableViewerUpdate",
                "testCoreProgressEventRejectsMalformedTerminalAndBounds",
            )
        ),
        "wireReceiveIOAndProductRemainOff": (
            "Data::SendFiles" not in progress + done + error + cancel
            and all(marker not in progress + done + error + cancel for marker in (
                "openat", "File::create", "write_all", "destination"
            ))
            and "fileTransferPolicy:" not in product
            and "No download command" in sources["readme"]
            and "dispatches a wire request" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2g Viewer download progress/terminal lifecycle",
        ),
        "rustDownloadJob": line_number(bridge, "struct NativeViewerDownloadJob"),
        "rustEmitter": line_number(bridge, "fn emit_file_transfer_event"),
        "rustProgress": line_number(bridge, "fn job_progress(&self,"),
        "rustCompleted": line_number(bridge, "fn job_done(&self,"),
        "rustFailed": line_number(bridge, "fn job_error(&self,"),
        "rustCancelled": line_number(bridge, "fn rdn_client_file_transfer_cancel("),
        "swiftEvent": line_number(swift, "struct CoreFileTransferEvent"),
        "swiftProjection": line_number(contract, "var viewerProgressUpdate"),
        "rustRegression": line_number(
            bridge,
            "fn viewer_download_progress_and_terminal_callbacks_are_monotonic_and_stable()",
        ),
        "swiftRegression": line_number(
            sources["swift_tests"],
            "testCoreProgressEventValidatesAndProjectsStableViewerUpdate",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-download-progress-terminal-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-download-progress-terminal-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDownloadStartImplemented": status == expected_status,
            "viewerProgressTerminalCallbacksImplemented": status == expected_status,
            "viewerDownloadWireDispatchImplemented": False,
            "viewerDownloadIOImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
