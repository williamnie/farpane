#!/usr/bin/env python3
"""Audit the default-unwired Viewer upload semantic-read ABI v14 contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-upload-semantic-read-abi-contract-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-upload-wire-job-lifecycle"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "core": repository / "Sources/CoreBridge/CoreBridge.swift",
        "adapter": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadReadAdapter.swift",
        "owner": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadSourceOwner.swift",
        "tests": repository
        / "Tests/CoreBridgeTests/ViewerFileTransferUploadSourceOwnerTests.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
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
    header = sources["header"]
    shim = sources["shim"]
    bridge = sources["bridge"]
    core = sources["core"]
    adapter = sources["adapter"]
    owner = sources["owner"]
    tests = sources["tests"]

    evidence = {
        "viewerABIV14DeclaresPathFreeStartAndReadCallback": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 14u",
                "RDNFileTransferUploadStart",
                "RDNFileTransferUploadReadRequest",
                "RDNFileTransferUploadReadCallback",
                "on_file_transfer_upload_read",
                "rdn_client_file_transfer_upload_start",
                "must not retain the request or buffer",
            )
        ),
        "shimRequiresAndForwardsTheNewSymbol": all(
            marker in shim
            for marker in (
                'dlsym(\n            handle, "rdn_client_file_transfer_upload_start")',
                "library->client_file_transfer_upload_start == NULL",
                "rdn_shim_client_file_transfer_upload_start(",
            )
        ),
        "rustOwnsBoundedSemanticJobsAndExactReads": all(
            marker in bridge
            for marker in (
                "const ABI_VERSION: u32 = 14;",
                "active_file_upload_jobs: Mutex<HashMap<i32, NativeViewerUploadJob>>",
                "native_viewer_upload_manifest(",
                "read_file_transfer_upload_source(",
                "hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES",
                "bytes_written != length",
                "payload.fill(0)",
                "rdn_client_file_transfer_upload_start(",
            )
        ),
        "swiftBindsExactDescriptorOwnerBeforeCoreStart": all(
            marker in core + adapter + owner
            for marker in (
                "fileTransferUploadReadAdapter.begin(",
                "rollbackFileTransferUpload(",
                "readPinnedBytes(",
                "Darwin.pread(",
                "request.source.token == sourceToken",
                "request.manifest.files[Int(fileNumber)]",
                "fileTransferUploadReadAdapter.teardownAll()",
            )
        ),
        "focusedRegressionCoversExactReadAndFailClosedTeardown": all(
            marker in tests + bridge
            for marker in (
                "testReadsExactPinnedRangesAndRejectsShortOrStaleReads",
                "testSemanticReadAdapterBindsExactRouteAndClosesOnTerminal",
                "viewer_upload_manifest_revalidates_bounded_files_directories_and_totals",
                "viewer_upload_start_registers_semantic_job_and_reads_exact_callback_range",
            )
        ),
        "semanticSeamRemainsPathFreeAfterWireLayer": (
            "native_viewer_upload_receive_message(" in bridge
            and "read_file_transfer_upload_source(" in bridge
            and "must not retain the request or buffer" in header
        ),
        "productUploadActionRemainsDefaultUnwired": (
            "requestFileTransferUpload" not in sources["app"]
            and "onFileTransferUploadAction" not in sources["viewer_ui"]
        ),
        "designRecordsScopeAndNonBlockingAcceptanceGap": all(
            marker in design
            for marker in (
                "H6.3j Viewer upload semantic-read ABI contract",
                "产品上传仍未开放",
                "双机上传继续记为未验证且不阻塞开发",
                NEXT_BOUNDARY,
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3j Viewer upload semantic-read ABI contract"
        ),
        "viewerABIVersion": line_number(header, "#define RDN_ABI_VERSION 14u"),
        "uploadStartStruct": line_number(header, "RDNFileTransferUploadStart"),
        "uploadReadCallback": line_number(
            header, "RDNFileTransferUploadReadCallback"
        ),
        "rustUploadStart": line_number(
            bridge, "rdn_client_file_transfer_upload_start("
        ),
        "rustSemanticJob": line_number(bridge, "struct NativeViewerUploadJob"),
        "swiftReadAdapter": line_number(
            adapter, "ViewerFileTransferUploadReadAdapter"
        ),
        "swiftPinnedRead": line_number(owner, "readPinnedBytes("),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "viewer-upload-semantic-read-abi-implemented-product-off"
            if passed else "audit-failed"
        ),
        "coverageScope": "h6-host-file-transfer-viewer-upload-semantic-read-abi",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerABIV14Implemented": passed,
            "pathOrDescriptorCrossesABI": False,
            "swiftDescriptorReadAuthorityImplemented": passed,
            "rustSemanticUploadJobImplemented": passed,
            "viewerUploadWireImplemented": passed,
            "viewerUploadProductActionImplemented": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-viewer-upload-product-action-lifecycle"
            if passed
            else NEXT_BOUNDARY
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
