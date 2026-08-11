#!/usr/bin/env python3
"""Audit H6.3f2a Viewer file-transfer ABI v9 default-off seam."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-abi-v9-seam-audit"


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
        "readme": repository / "CoreBridge/README.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
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
    event_start = header.find("typedef struct RDNFileTransferEvent {")
    event_end = header.find("} RDNFileTransferEvent;", event_start)
    event_shape = header[event_start:event_end] if event_start >= 0 and event_end >= 0 else ""

    evidence = {
        "designRecordsBoundedH63f2a": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2a Viewer file-transfer ABI v9 default-off seam",
                "host-file-transfer-viewer-destination-descriptor-owner",
            )
        ),
        "abiV9RetainsClipboardAndAddsFileSeam": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 16u",
                "RDNClipboardImageCallback on_clipboard_image;",
                "RDNFileTransferEventCallback on_file_transfer_event;",
                "bool enable_file_transfer;",
                "uint64_t file_transfer_session_epoch;",
                "rdn_client_file_transfer_cancel",
            )
        ),
        "eventIsScalarAndPathFree": (
            event_shape
            and "const " not in event_shape
            and "*" not in event_shape
            and "path" not in event_shape.lower()
            and "descriptor" not in event_shape.lower()
            and "error" not in event_shape.lower()
            and all(
                marker in event_shape
                for marker in (
                    "uint64_t session_epoch;",
                    "int32_t transfer_id;",
                    "uint64_t sequence;",
                    "uint64_t bytes_completed;",
                    "double bytes_per_second;",
                )
            )
        ),
        "stableClientErrorsCoverFileSeam": all(
            marker in header
            for marker in (
                "#define RDN_CLIENT_ERR_NOT_SUPPORTED (-9)",
                "#define RDN_CLIENT_ERR_STALE_EPOCH (-10)",
            )
        ),
        "rustAdmissionPrecedesNetworkAndFailsClosed": all(
            marker in bridge
            for marker in (
                "fn viewer_file_transfer_mode_admission(",
                "if enabled != (session_epoch > 0)",
                "else if enabled && desktop_clipboard_requested",
                "let file_transfer_admission = viewer_file_transfer_mode_admission(",
                "if file_transfer_admission != 0",
                "return file_transfer_admission;",
                "emit_state(RDNState::Connecting",
            )
        ) and bridge.find("let file_transfer_admission =") < bridge.find(
            "emit_state(RDNState::Connecting"
        ),
        "cancelIsExactEpochAndStable": all(
            marker in bridge
            for marker in (
                "pub unsafe extern \"C\" fn rdn_client_file_transfer_cancel(",
                "if session_epoch == 0 || transfer_id <= 0",
                ".file_transfer_enabled",
                ".file_transfer_session_epoch",
                "return -10;",
            )
        ),
        "swiftDefaultsPairOffAndRevalidatesEvents": all(
            marker in swift
            for marker in (
                "fileTransferEnabled: Bool = false",
                "fileTransferSessionEpoch: UInt64 = 0",
                "private let fileTransferEventCallback",
                "let event = CoreFileTransferEvent(",
                "sessionEpoch > 0",
                "sequence > 0",
                "bytesPerSecond.isFinite",
                "filesCompleted == totalFiles",
                "bytesCompleted == totalBytes",
                "callbackBox.stopFileTransferDelivery()",
                "public func cancelFileTransfer(sessionEpoch:",
            )
        ),
        "shimAndBuildRequireCancelSymbol": (
            'dlsym(\n            handle, "rdn_client_file_transfer_cancel")' in sources["shim"]
            and "library->client_file_transfer_cancel == NULL" in sources["shim"]
            and all(
                "_rdn_client_file_transfer_cancel" in sources[name]
                for name in ("build_core", "build_universal")
            )
        ),
        "regressionsCoverPairAndCancelLifecycle": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "viewer_file_transfer_v9_seam_is_exact_pair_and_fail_closed",
                "viewer_file_transfer_mode_admission(false, 0, false)",
                "rdn_client_file_transfer_cancel(client_pointer, 2, 1)",
                "testViewerFileTransferSeamIsDefaultOffAndEpochScoped",
            )
        ),
        "productRemainsOffAndRuntimeGapDocumented": (
            "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "destination\n  owner" in sources["architecture"]
            and "No download command" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.3f2a Viewer file-transfer ABI v9 default-off seam"
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 16u"),
        "event": line_number(header, "typedef struct RDNFileTransferEvent {"),
        "callback": line_number(header, "RDNFileTransferEventCallback on_file_transfer_event;"),
        "config": line_number(header, "bool enable_file_transfer;"),
        "cancel": line_number(header, "rdn_client_file_transfer_cancel"),
        "rustAdmission": line_number(bridge, "fn viewer_file_transfer_mode_admission("),
        "rustCancel": line_number(bridge, "fn rdn_client_file_transfer_cancel("),
        "swiftCallback": line_number(swift, "private let fileTransferEventCallback"),
        "swiftCancel": line_number(swift, "public func cancelFileTransfer(sessionEpoch:"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-file-transfer-abi-v9-seam-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-abi-v9-seam",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerFileTransferABISeamImplemented": status == expected_status,
            "viewerFileTransferSessionLifecycleImplemented": status == expected_status,
            "viewerFileTransferRuntimeImplemented": False,
            "viewerDestinationDescriptorOwnerImplemented": False,
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
