#!/usr/bin/env python3
"""Audit H6.3f2b2l Viewer receive-block ABI lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-receive-block-abi-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-io-loop-receive-interception-lifecycle"


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
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
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
    production_bridge = bridge.split("#[cfg(test)]", 1)[0]
    raw_struct = function_body(
        bridge,
        "struct RDNFileTransferReceiveBlock",
        "struct RDNFileTransferUploadStart",
    )
    rust_emit = function_body(
        bridge,
        "fn emit_file_transfer_receive_block(",
        "fn emit_video(",
    )
    swift_block = function_body(
        swift,
        "public struct CoreFileTransferReceiveBlock",
        "public enum CoreFileTransferListStatus",
    )
    swift_callback = function_body(
        swift,
        "private let fileTransferReceiveBlockCallback",
        "public final class RustDeskCoreClient",
    )
    swift_delivery = function_body(
        swift,
        "func deliverFileTransferReceiveBlock(",
        "func stopFileTransferDelivery(",
    )
    rust_tests = bridge.split("#[cfg(test)]", 1)[1] if "#[cfg(test)]" in bridge else ""
    evidence = {
        "designRecordsBoundedH63f2b2l": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2l Viewer receive-block ABI lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "abiV14RetainsCallbackScopedSemanticBytes": (
            "#define RDN_ABI_VERSION 17u" in header
            and "const ABI_VERSION: u32 = 17;" in bridge
            and all(marker in raw_struct for marker in (
                "abi_version: u32",
                "session_epoch: u64",
                "transfer_id: i32",
                "file_number: u32",
                "data: *const u8",
                "length: usize",
            ))
            and all(marker not in raw_struct for marker in (
                "path", "descriptor", "destination", "lease", "token",
            ))
            and "RDNFileTransferReceiveBlockCallback on_file_transfer_receive_block;" in header
        ),
        "rustCallbackRequiresExactActiveFileSessionAndBounds": all(
            marker in rust_emit
            for marker in (
                "!self.active.load(Ordering::Acquire)",
                "!self.authenticated.load(Ordering::Acquire)",
                "!self.file_transfer_enabled.load(Ordering::Acquire)",
                "block.session_epoch == 0",
                "file_transfer_session_epoch.load(Ordering::Acquire) != block.session_epoch",
                "block.transfer_id <= 0",
                "block.payload.is_empty()",
                "hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES",
                "data: block.payload.as_ptr()",
                "unsafe { callback(self.context as *mut c_void, &raw) };",
            )
        ),
        "swiftCopiesRevalidatesAndUsesSharedLifecycleGate": (
            all(marker in swift_block for marker in (
                "sessionEpoch > 0",
                "transferID > 0",
                "Int(fileNumber) < Self.maximumFileCount",
                "!payload.isEmpty",
                "payload.count <= Self.maximumPayloadBytes",
            ))
            and all(marker in swift_callback for marker in (
                "raw.abi_version == RDN_ABI_VERSION",
                "let payload = Data(bytes: bytes, count: raw.length)",
                "CoreFileTransferReceiveBlock(",
                "box.deliverFileTransferReceiveBlock(block)",
            ))
            and all(marker in swift_delivery for marker in (
                "fileTransferLifecycleLock.withLock",
                "fileTransferDeliveryEnabled",
                "onFileTransferReceiveBlock(block)",
            ))
        ),
        "regressionsCoverOwnershipExactSessionAndSemanticBounds": (
            all(marker in rust_tests for marker in (
                "viewer_receive_block_callback_is_exact_session_and_callback_scoped",
                "block.payload.fill(b'x')",
                "payload: b\"owned\".to_vec()",
                "block.session_epoch = 8",
                "authenticated.store(false",
            ))
            and all(marker in sources["swift_tests"] for marker in (
                "testReceiveBlockOwnsOnlyBoundedExactSemanticPayload",
                "sessionEpoch: 0",
                "transferID: 0",
                "maximumFileCount",
                "maximumPayloadBytes + 1",
            ))
            and "XCTAssertEqual(viewerABI(), 17" in sources["host_tests"]
        ),
        "ioLoopInterceptionIsExactWhileWireWriteAndProductRemainOff": (
            "fn native_file_transfer_receive_block(" in production_bridge
            and "active_file_download_jobs.lock().unwrap()" in production_bridge
            and "self.shared.emit_file_transfer_receive_block(&block)" in production_bridge
            and "Data::SendFiles" not in rust_emit
            and "pwrite" not in rust_emit
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "No wire download request or destination write" in sources["readme"]
            and "wire download request、destination write 与 UI 仍未实现" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2l Viewer receive-block ABI lifecycle",
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 17u"),
        "rawCallbackStruct": line_number(header, "typedef struct RDNFileTransferReceiveBlock"),
        "rustEmitter": line_number(bridge, "fn emit_file_transfer_receive_block("),
        "swiftSemanticBlock": line_number(swift, "struct CoreFileTransferReceiveBlock"),
        "swiftCallback": line_number(swift, "let fileTransferReceiveBlockCallback"),
        "rustRegression": line_number(
            bridge,
            "fn viewer_receive_block_callback_is_exact_session_and_callback_scoped()",
        ),
        "swiftRegression": line_number(
            sources["swift_tests"],
            "testReceiveBlockOwnsOnlyBoundedExactSemanticPayload",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-receive-block-abi-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-receive-block-abi-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerReceiveBlockABILifecycleImplemented": status == expected_status,
            "viewerIOLoopReceiveInterceptionImplemented": status == expected_status,
            "viewerDownloadWireDispatchImplemented": False,
            "viewerDestinationWriteImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
