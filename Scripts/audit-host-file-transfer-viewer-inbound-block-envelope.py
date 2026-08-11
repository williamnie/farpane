#!/usr/bin/env python3
"""Audit H6.3f2b2k Viewer inbound file-block semantic envelope."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-inbound-block-envelope-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-receive-block-abi-lifecycle"


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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
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
    receive = function_body(
        bridge,
        "fn receive_block(&self, block: &FileTransferBlock)",
        "fn progress(",
    )
    tests = function_body(
        bridge,
        "fn viewer_receive_block_owns_raw_and_bounded_decompressed_payloads()",
        "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
    )
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2k": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2k Viewer inbound block envelope",
                NEXT_BOUNDARY,
            )
        ),
        "acceptedPayloadIsRustOwnedAndPathFree": all(
            marker in bridge
            for marker in (
                "struct NativeViewerReceiveBlock",
                "transfer_id: i32",
                "file_number: u32",
                "payload: Vec<u8>",
            )
        ),
        "blockMustMatchRegisteredTransferAndManifestFileRange": all(
            marker in receive
            for marker in (
                "block.id != self.transfer_id",
                "u32::try_from(block.file_num)",
                "file_number >= self.total_files",
            )
        ),
        "wireAndDecodedPayloadShareCanonicalBound": (
            receive.count("hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES") >= 3
            and all(marker in receive for marker in (
                "block.data.is_empty()",
                "block.data.len() >",
                "hbb_common::compress::decompress_with_limit(",
                "block.data.to_vec()",
                "payload.is_empty()",
                "payload.len() >",
            ))
        ),
        "regressionsCoverOwnershipCompressionIdentityAndBounds": all(
            marker in tests
            for marker in (
                "payload: b\"raw\".to_vec()",
                "hbb_common::compress::compress(&plain)",
                "MAX_FILE_TRANSFER_BLOCK_BYTES + 1",
                "b\"not-zstd\"",
                "block(60, 0",
                "block(61, -1",
                "block(61, 2",
            )
        ),
        "receiveABIWireDispatchAndProductRemainOff": (
            "#define RDN_ABI_VERSION 13u" in sources["header"]
            and "RDNFileTransferReceiveBlockCallback" in sources["header"]
            and "Data::SendFiles" not in receive
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "does not dispatch a download wire request" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2k Viewer inbound block envelope",
        ),
        "ownedBlock": line_number(bridge, "struct NativeViewerReceiveBlock"),
        "receiveBlock": line_number(bridge, "fn receive_block("),
        "acceptedRegression": line_number(
            bridge,
            "fn viewer_receive_block_owns_raw_and_bounded_decompressed_payloads()",
        ),
        "rejectedRegression": line_number(
            bridge,
            "fn viewer_receive_block_rejects_wrong_job_file_and_payload_bounds()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-inbound-block-envelope-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-inbound-block-envelope",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerInboundBlockEnvelopeImplemented": status == expected_status,
            "viewerReceiveBlockABIImplemented": status == expected_status,
            "viewerDownloadWireDispatchImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
