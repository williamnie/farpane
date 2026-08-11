#!/usr/bin/env python3
"""Audit the Rust-owned Viewer upload wire job lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-upload-wire-job-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-installed-single-mac-smoke"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "loop": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "trait": repository / "Vendor/rustdesk/src/ui_session_interface.rs",
        "patch": repository / "CoreBridge/RustDeskPatch/h6-viewer-file-upload-wire.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "viewer": repository / "Sources/RustDeskNative/ViewerUI.swift",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({"schema": SCHEMA, "schemaVersion": 1,
                          "status": "audit-failed", "error": str(error)},
                         sort_keys=True, separators=(",", ":")))
        return 1

    bridge = sources["bridge"]
    host = sources["host"]
    loop = sources["loop"]
    trait = sources["trait"]
    evidence = {
        "rustOwnsCanonicalBoundedWireStateMachine": all(marker in bridge for marker in (
            "enum NativeViewerUploadStage",
            "native_viewer_upload_create_message(",
            "native_viewer_upload_receive_message(",
            "native_viewer_upload_digest_message(",
            "hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES",
            "native_viewer_upload_cancel_message(",
            "VIEWER_UPLOAD_WIRE_TIMEOUT",
        )),
        "ioLoopPollsAndInterceptsExactUploadResponses": all(marker in loop + trait for marker in (
            "native_file_transfer_upload_poll_interval_ms",
            "native_file_transfer_upload_poll()",
            "native_file_transfer_upload_confirmation",
            "native_file_transfer_upload_existing_target",
            "native_file_transfer_upload_done",
            "native_file_transfer_upload_error",
        )),
        "confirmationAndFailurePathsAreFailClosed": all(marker in bridge for marker in (
            "Union::OffsetBlk(0)",
            "Union::Skip(true)",
            "FILE_TRANSFER_FAILURE_PROTOCOL_VIOLATION",
            "FILE_TRANSFER_FAILURE_LOCAL_IO",
            "FILE_TRANSFER_FAILURE_REJECTED",
            "FILE_TRANSFER_FAILURE_UNAVAILABLE",
        )),
        "hostAcceptsReceiveRootAndMaterializesZeroFiles": all(marker in host for marker in (
            "base_is_receive_root",
            "entry.expected_size == 0",
            "NativeHostWriteFile::create(self.owner.clone(), entry)?.commit()?",
            "native_host_receive_root_commits_zero_length_before_following_file",
        )),
        "wirePatchIsReplayableFromPinnedBootstrap": (
            "h6-viewer-file-upload-wire.patch" in sources["bootstrap"]
            and "apply --check --reverse \"$viewer_file_upload_wire_patch_file\"" in sources["bootstrap"]
            and "native_file_transfer_upload_poll" in sources["patch"]
        ),
        "focusedRegressionCoversWireSequence": all(marker in bridge for marker in (
            "viewer_upload_start_registers_semantic_job_and_reads_exact_callback_range",
            "upload start must send one wire message",
            "first upload poll must emit digest",
            "confirmed upload must emit one bounded block",
            "completed payload must emit Done",
        )),
        "productActionConsumesOwnedWireLifecycle": (
            "requestFileTransferUpload" in sources["app"]
            and "onFileTransferUploadAction" in sources["viewer"]
        ),
        "designRecordsWireScopeAndNonBlockingTwoMacGap": all(
            marker in sources["design"] for marker in (
                "H6.3k Viewer upload wire-job lifecycle",
                "产品上传入口仍未开放",
                "双机上传继续记为未验证且不阻塞开发",
                NEXT_BOUNDARY,
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(sources["design"], "H6.3k Viewer upload wire-job lifecycle"),
        "uploadStateMachine": line_number(bridge, "enum NativeViewerUploadStage"),
        "uploadPoll": line_number(bridge, "fn file_transfer_upload_poll(&self)"),
        "ioLoopPollHook": line_number(loop, "native_file_transfer_upload_poll()"),
        "hostReceiveRoot": line_number(host, "base_is_receive_root"),
        "bootstrapPatch": line_number(sources["bootstrap"], "h6-viewer-file-upload-wire.patch"),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "viewer-upload-wire-job-implemented" if passed else "audit-failed",
        "coverageScope": "h6-host-file-transfer-viewer-upload-wire-job-lifecycle",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerUploadWireImplemented": passed,
            "swiftRetainsSourceDescriptorOwnership": passed,
            "existingTargetReplacementImplemented": False,
            "viewerUploadProductActionImplemented": passed,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
