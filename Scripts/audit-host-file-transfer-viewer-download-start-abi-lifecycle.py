#!/usr/bin/env python3
"""Audit H6.3f2b2f Viewer path-free download-start ABI lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-download-start-abi-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-download-progress-terminal-lifecycle"


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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
        "build_core": repository / "Scripts/build-rust-core.sh",
        "build_universal": repository / "Scripts/build-universal.sh",
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

    header = sources["header"]
    bridge = sources["bridge"]
    swift = sources["swift"]
    product = sources["app"] + sources["agent"]
    rust_start = function_body(
        bridge,
        "pub unsafe extern \"C\" fn rdn_client_file_transfer_download_start(",
        "struct PacketInspection",
    )
    evidence = {
        "designRecordsBoundedH63f2b2f": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2f Viewer download-start ABI lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "abiV12StartIsPathFreeAndScalarOnly": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 13u",
                "typedef struct RDNFileTransferDownloadStart",
                "uint64_t session_epoch;",
                "int32_t manifest_request_id;",
                "int32_t transfer_id;",
                "uint32_t total_files;",
                "uint64_t total_bytes;",
                "rdn_client_file_transfer_download_start",
            )
        ) and all(
            marker not in function_body(
                header,
                "typedef struct RDNFileTransferDownloadStart",
                "typedef enum RDNFileTransferListStatus",
            )
            for marker in ("path", "descriptor", "token", "char *", "void *")
        ),
        "rustAdmissionBindsExactCompletedManifestAndBoundsJobs": all(
            marker in rust_start
            for marker in (
                "request.manifest_request_id <= 0",
                "MAX_FILE_TRANSFER_LIST_ENTRIES",
                "file_transfer_session_epoch",
                "return -10;",
                "authenticated.load(Ordering::Acquire)",
                "completed_manifest.files.len()",
                "completed_file_manifest_request",
                "request_id: request.manifest_request_id",
                "total_files: request.total_files",
                "total_bytes: request.total_bytes",
                "server_file_transfer_enabled",
                "session.sender.read().unwrap().as_ref().cloned()",
                "MAX_VIEWER_DOWNLOAD_JOBS",
                "jobs.contains_key(&request.transfer_id)",
                "jobs.insert(request.transfer_id, job)",
            )
        ),
        "pathFreeRegistrationDispatchesCanonicalRootWithoutDestinationIO": all(
            marker in rust_start
            for marker in (
                "native_viewer_file_download_root_message",
                "sender",
                ".send(Data::Message",
                "jobs.remove(&request.transfer_id)",
            )
        ) and all(
            marker not in rust_start
            for marker in (
                "Data::SendFiles",
                "openat",
                "File::create",
                "write_all",
                "rdn_host_file_transfer",
            )
        ),
        "lifecycleClearsOnCancelTerminalAndTeardown": all(
            marker in bridge
            for marker in (
                "sender.send(Data::CancelJob(transfer_id))",
                ".active_file_download_jobs",
                ".remove(&id)",
                ".remove(&transfer_id)",
                ".clear();",
                "job.session_epoch == session_epoch",
                "completed_file_manifest_request",
            )
        ),
        "swiftProjectionRetainsDestinationOwnership": all(
            marker in swift
            for marker in (
                "package struct CoreFileTransferDownloadStart",
                "request: ViewerFileTransferDownloadRequest",
                "manifestRequestID: Int32",
                "totalFiles = UInt32(exactly: request.manifest.files.count)",
                "totalBytes = request.manifest.totalBytes",
                "package func startFileTransferDownload(",
                "RDNFileTransferDownloadStart(",
                "rdn_shim_client_file_transfer_download_start",
            )
        ) and all(
            marker not in function_body(
                swift,
                "package struct CoreFileTransferDownloadStart",
                "private func optionalClipboardUTF8Data",
            )
            for marker in ("destination", ".token", ".descriptor", ".path")
        ),
        "shimBuildAndBuiltCoreRequireStartSymbol": (
            'handle, "rdn_client_file_transfer_download_start")' in sources["shim"]
            and "library->client_file_transfer_download_start == NULL" in sources["shim"]
            and all(
                "_rdn_client_file_transfer_download_start" in sources[name]
                for name in ("build_core", "build_universal")
            )
            and 'dlsym(handle, "rdn_client_file_transfer_download_start")'
            in sources["host_tests"]
        ),
        "regressionsCoverExactScalarWireShapeRollbackAndCancel": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request",
                "file_action::Union::Send(send)",
                "viewer_download_start_rolls_back_registration_when_wire_queue_is_closed",
                "request.total_files = 3",
                "Ok(Data::CancelJob(61))",
                "testDownloadStartProjectsOnlyExactManifestAndScalarTotals",
                "XCTAssertEqual(start.manifestRequestID, 51)",
            )
        ),
        "productAndDownloadIORemainOff": (
            "fileTransferEnabled:" not in product
            and "Download start now queues exactly one" in sources["readme"]
            and "不会创建上游 path-based local write job" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2f Viewer download-start ABI lifecycle",
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 13u"),
        "startRequest": line_number(header, "typedef struct RDNFileTransferDownloadStart"),
        "startCommand": line_number(header, "rdn_client_file_transfer_download_start"),
        "rustCommand": line_number(bridge, "fn rdn_client_file_transfer_download_start("),
        "rustJob": line_number(bridge, "struct NativeViewerDownloadJob"),
        "swiftProjection": line_number(swift, "struct CoreFileTransferDownloadStart"),
        "swiftCommand": line_number(swift, "func startFileTransferDownload("),
        "rustRegression": line_number(
            bridge,
            "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
        ),
        "swiftRegression": line_number(
            sources["swift_tests"],
            "testDownloadStartProjectsOnlyExactManifestAndScalarTotals",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-download-start-abi-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-download-start-abi-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRecursiveManifestABILifecycleImplemented": status == expected_status,
            "viewerDownloadStartImplemented": status == expected_status,
            "viewerDownloadWireDispatchImplemented": status == expected_status,
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
