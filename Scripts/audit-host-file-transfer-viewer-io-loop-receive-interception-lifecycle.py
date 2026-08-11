#!/usr/bin/env python3
"""Audit H6.3f2b2m Viewer io-loop receive interception lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-io-loop-receive-interception-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-download-wire-request-lifecycle"


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
        "patch": repository / "CoreBridge/RustDeskPatch/h6-viewer-file-receive-interception.patch",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
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
    patch = sources["patch"]
    product = sources["app"] + sources["agent"]
    hook = function_body(
        bridge,
        "fn native_file_transfer_receive_block(",
        "}\n\n",
    )
    regression = function_body(
        bridge,
        "fn viewer_io_loop_hook_consumes_only_registered_download_blocks()",
        "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
    )
    evidence = {
        "designRecordsBoundedH63f2b2m": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2m Viewer io-loop receive interception lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "upstreamHookIsFeatureGatedDefaultPassthrough": all(
            marker in patch
            for marker in (
                '#[cfg(feature = "rdn-native-core")]',
                "fn native_file_transfer_receive_block(&self, _block: &FileTransferBlock) -> bool",
                "false",
                "Some(file_response::Union::Block(block))",
                "let consumed = self.handler.native_file_transfer_receive_block(&block)",
                '#[cfg(not(feature = "rdn-native-core"))]',
                "if !consumed",
                "fs::get_job(block.id, &mut self.write_jobs)",
            )
        ),
        "bridgeConsumesOnlyRegisteredJobsAndUnlocksBeforeCallback": all(
            marker in hook
            for marker in (
                "active_file_download_jobs.lock().unwrap()",
                "jobs.get(&block.id)",
                "return false",
                "job.receive_block(block)",
                "if let Some(block) = semantic",
                "emit_file_transfer_receive_block(&block)",
                "true",
            )
        ) and hook.find("job.receive_block(block)") < hook.find("if let Some(block) = semantic"),
        "bootstrapOwnsAndReplaysLayeredPatch": all(
            marker in sources["bootstrap"]
            for marker in (
                "h6-viewer-file-receive-interception.patch",
                'apply --check "$viewer_file_receive_patch_file"',
                'apply --check --reverse "$viewer_file_receive_patch_file"',
            )
        ),
        "regressionCoversPassthroughConsumeRejectAndTeardown": all(
            marker in regression
            for marker in (
                "block(60, 0, b\"foreign\".to_vec())",
                "block(61, 0, b\"owned\".to_vec())",
                "block(61, 2, b\"invalid\".to_vec())",
                "captured.lock().unwrap().as_slice()",
                "active_file_download_jobs.lock().unwrap().clear()",
                "block(61, 0, b\"stale\".to_vec())",
            )
        ),
        "wireRequestDestinationWriteAndProductRemainOff": (
            "Data::SendFiles" not in hook
            and "pwrite" not in hook
            and "writeFileTransferPayload" not in sources["swift"]
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "No wire download request or destination write" in sources["readme"]
            and "wire download request、destination write 与 UI 仍未实现" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2m Viewer io-loop receive interception lifecycle",
        ),
        "patchBlockArm": line_number(patch, "Some(file_response::Union::Block(block))"),
        "patchTraitHook": line_number(patch, "fn native_file_transfer_receive_block("),
        "bridgeHook": line_number(bridge, "fn native_file_transfer_receive_block("),
        "rustRegression": line_number(
            bridge,
            "fn viewer_io_loop_hook_consumes_only_registered_download_blocks()",
        ),
        "bootstrapPatch": line_number(
            sources["bootstrap"],
            "h6-viewer-file-receive-interception.patch",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-io-loop-receive-interception-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-io-loop-receive-interception-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerReceiveBlockABILifecycleImplemented": status == expected_status,
            "viewerIOLoopReceiveInterceptionImplemented": status == expected_status,
            "viewerDownloadWireRequestImplemented": False,
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
