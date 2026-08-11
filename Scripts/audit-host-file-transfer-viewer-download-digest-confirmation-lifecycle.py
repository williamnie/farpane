#!/usr/bin/env python3
"""Audit H6.3f2b2o Viewer download digest-confirmation lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-download-digest-confirmation-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-receive-write-adapter-lifecycle"


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
        "patch": repository / "CoreBridge/RustDeskPatch/h6-viewer-file-digest-confirmation.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "receiveAdapter": repository
            / "Sources/CoreBridge/ViewerFileTransferReceiveAdapter.swift",
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
    tracked_patch = sources["patch"]
    product = sources["app"] + sources["agent"]
    digest = function_body(
        bridge,
        "    fn confirm_digest(\n",
        "    fn receive_block(",
    )
    hook = function_body(
        bridge,
        "    fn native_file_transfer_download_digest_confirmation(\n",
        "    fn native_file_transfer_receive_block(",
    )
    start = function_body(
        bridge,
        'pub unsafe extern "C" fn rdn_client_file_transfer_download_start(',
        "struct PacketInspection",
    )
    regression = function_body(
        bridge,
        "fn viewer_digest_hook_confirms_only_exact_manifest_file_sequence()",
        "fn viewer_download_start_registers_exact_manifest_and_dispatches_bounded_wire_request()",
    )
    evidence = {
        "designRecordsBoundedH63f2b2o": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2o Viewer download digest-confirmation lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "manifestRetainsPerFileDigestAuthorityInsideRust": all(
            marker in bridge
            for marker in (
                "struct NativeViewerManifestFileAuthority",
                "files: Arc<[NativeViewerManifestFileAuthority]>",
                "manifest_files: Arc<[NativeViewerManifestFileAuthority]>",
                "next_digest_file_number: u32",
            )
        ) and all(
            marker in start
            for marker in (
                "completed_manifest.files.len()",
                "let manifest_files =",
                "manifest_files,",
                "next_digest_file_number: 0",
            )
        ),
        "digestAdmissionIsExactSequentialAndNewFileOnly": all(
            marker in digest
            for marker in (
                "digest.is_upload",
                "digest.is_resume",
                "digest.is_identical",
                "digest.transferred_size != 0",
                "file_number != self.next_digest_file_number",
                "digest.file_size != authority.size",
                "digest.last_modified != authority.modified_time",
                "self.next_digest_file_number = file_number.checked_add(1)?",
                "OffsetBlk(0)",
            )
        ),
        "matchingMalformedFailsClosedAndForeignKeepsUpstreamFallback": all(
            marker in hook
            for marker in (
                "jobs.get_mut(&digest.id)",
                "return (false, None)",
                "(true, job.confirm_digest(digest))",
            )
        ) and all(
            marker in tracked_patch
            for marker in (
                "let (consumed, confirmation)",
                "peer.send(&new_send_confirm(confirmation)).await",
                "if consumed",
                "Matching malformed or duplicate digests fail closed.",
                "} else if digest.is_upload {",
                "(false, None)",
            )
        ),
        "payloadBlocksRequirePriorDigestConfirmation": all(
            marker in bridge
            for marker in (
                "file_number >= self.next_digest_file_number",
                "fn viewer_receive_block_rejects_wrong_job_file_and_payload_bounds()",
                "next_digest_file_number: 2",
            )
        ),
        "bootstrapOwnsAndReplaysTrackedPatch": all(
            marker in sources["bootstrap"]
            for marker in (
                "h6-viewer-file-digest-confirmation.patch",
                'git -C "$vendor_dir" apply --check --reverse "$viewer_file_digest_patch_file"',
                'git -C "$vendor_dir" apply "$viewer_file_digest_patch_file"',
            )
        ),
        "regressionCoversExactSequenceDriftFlagsAndTeardown": all(
            marker in regression
            for marker in (
                "out-of-order digest must be consumed without confirmation",
                "manifest size drift must fail closed",
                "manifest mtime drift must fail closed",
                "duplicate digest must fail closed",
                "resume.is_resume = true",
                "resume.transferred_size = 1",
                "resume.is_upload = true",
                "resume.is_identical = true",
                "OffsetBlk(0)",
                "(false, None)",
            )
        ),
        "abiDestinationAdapterAndProductRemainOff": (
            "RDNFileTransferDigest" not in bridge
            and "reserveNewFile" not in hook + digest
            and "writePayload" not in hook + digest
            and "commitReservation" not in hook + digest
            and "startFileTransferDownload(" not in product
            and "onFileTransferReceiveBlock:" not in product
            and "Digest confirmation now" in sources["readme"]
            and "digest confirmation" in sources["architecture"]
        ),
        "downstreamReceiveWriteAdapterImplemented": all(
            marker in sources["receiveAdapter"]
            for marker in (
                "package final class ViewerFileTransferReceiveAdapter",
                "destinationOwner.reserveNewFile",
                "destinationOwner.writePayload",
                "destinationOwner.commitReservation",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2o Viewer download digest-confirmation lifecycle",
        ),
        "manifestAuthority": line_number(bridge, "struct NativeViewerManifestFileAuthority"),
        "digestAdmission": line_number(bridge, "    fn confirm_digest(\n"),
        "bridgeHook": line_number(
            bridge,
            "    fn native_file_transfer_download_digest_confirmation(\n",
        ),
        "trackedPatch": line_number(
            tracked_patch,
            "native_file_transfer_download_digest_confirmation",
        ),
        "digestRegression": line_number(
            bridge,
            "fn viewer_digest_hook_confirms_only_exact_manifest_file_sequence()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-download-digest-confirmation-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-download-digest-confirmation-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDownloadWireRequestImplemented": status == expected_status,
            "viewerDigestConfirmationImplemented": status == expected_status,
            "viewerDestinationWriteAdapterImplemented": status == expected_status,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
