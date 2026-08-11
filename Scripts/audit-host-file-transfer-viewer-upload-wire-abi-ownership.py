#!/usr/bin/env python3
"""Audit and freeze the Viewer upload wire/ABI ownership boundary."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-upload-wire-abi-ownership-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"
NEXT_BOUNDARY = "host-file-transfer-viewer-upload-product-action-lifecycle"


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
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "upload_contract": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadContract.swift",
        "source_owner": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadSourceOwner.swift",
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "io_loop": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "fs": repository / "Vendor/rustdesk/libs/hbb_common/src/fs.rs",
        "host_connection": repository
        / "Vendor/rustdesk/src/server/connection.rs",
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
    bridge = sources["bridge"]
    upload_contract = sources["upload_contract"]
    source_owner = sources["source_owner"]
    client = sources["client"]
    io_loop = sources["io_loop"]
    fs = sources["fs"]
    host_connection = sources["host_connection"]

    ownership_markers = (
        "RDNFileTransferUploadStart",
        "RDNFileTransferUploadReadRequest",
        "caller-owned 128 KiB buffer",
        "synchronous read callback",
        "FileAction::Receive",
        "FileAction::Create",
        "OffsetBlk(0)",
        "Skip(true)",
    )
    evidence = {
        "pinnedUpstreamIdentityIsExplicit": (
            PINNED_RUSTDESK_COMMIT in bridge
        ),
        "upstreamSendFilesIsPathBasedAndCannotOwnSwiftSources": all(
            marker in client + io_loop + fs
            for marker in (
                "SendFiles((i32, JobType, String, String, i32, bool, bool))",
                "fs::TransferJob::new_read(",
                "fs::DataSource::FilePath(PathBuf::from(&path))",
                "pub enum DataSource",
                "FilePath(PathBuf)",
            )
        ),
        "canonicalUploadWirePrimitivesAlreadyExist": all(
            marker in io_loop + fs
            for marker in (
                "pub fn new_receive(",
                "pub fn new_block(",
                "pub fn new_done(",
                "Some(file_action::Union::SendConfirm(c))",
                "pub const MAX_FILE_TRANSFER_BLOCK_BYTES: usize = 128 * 1024",
            )
        ),
        "nativeHostAlreadyConsumesCanonicalReceivePlane": all(
            marker in host_connection
            for marker in (
                "Some(file_action::Union::Receive(r))",
                "begin_native_host_write_job(&r, od).await",
                "write_native_host_file_block",
                "confirm_native_host_file_digest",
                "finish_native_host_write_job",
                "confirm_native_host_existing_target_decision",
            )
        ),
        "swiftSourceAuthorityIsDescriptorOwnedAndPathFree": all(
            marker in upload_contract + source_owner
            for marker in (
                "paths and descriptors remain owned",
                "ViewerFileTransferUploadSourceLease",
                "withPinnedFileDescriptor",
                "matchesFile(descriptor, identity: file.identity)",
                "F_DUPFD_CLOEXEC",
            )
        ),
        "currentViewerABIImplementsOnlyFrozenSemanticSeam": (
            "#define RDN_ABI_VERSION 14u" in header
            and "RDNFileTransferUploadStart" in header
            and "RDNFileTransferUploadReadRequest" in header
            and "rdn_client_file_transfer_upload_start" in header
            and "on_file_transfer_upload_read" in header
            and "fn file_transfer_upload_poll(&self)" in bridge
        ),
        "minimalVersionedSemanticSeamIsFrozen": (
            "H6.3i Viewer upload wire/ABI ownership audit" in design
            and all(marker in design for marker in ownership_markers)
            and "Viewer ABI v14" in design
        ),
        "wireStateRemainsRustOwned": all(
            marker in design
            for marker in (
                "Rust owns transfer state",
                "digest/confirm",
                "non-zero offset",
                "duplicate callback",
                "must fail closed",
            )
        ),
        "swiftOwnsOnlyBoundedSynchronousReads": all(
            marker in design
            for marker in (
                "Swift owns source lifetime",
                "must not cross the ABI",
                "must not retain the callback buffer",
                "exact file number and offset",
            )
        ),
        "emptyDirectoryAndConflictPolicyAreExplicit": all(
            marker in design
            for marker in (
                "empty directories",
                "canonical create action",
                "no-replace",
                "multi-file resume",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3i Viewer upload wire/ABI ownership audit"
        ),
        "viewerABIVersion": line_number(header, "#define RDN_ABI_VERSION 14u"),
        "pathBasedSend": line_number(io_loop, "Data::SendFiles("),
        "canonicalReceive": line_number(fs, "pub fn new_receive("),
        "boundedWireBlock": line_number(
            fs, "pub const MAX_FILE_TRANSFER_BLOCK_BYTES: usize = 128 * 1024"
        ),
        "hostReceive": line_number(
            host_connection, "begin_native_host_write_job(&r, od).await"
        ),
        "pathFreeRequest": line_number(
            upload_contract, "package struct ViewerFileTransferUploadRequest"
        ),
        "descriptorBorrow": line_number(
            source_owner, "package func withPinnedFileDescriptor"
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "viewer-upload-wire-abi-ownership-frozen"
            if passed else "audit-failed"
        ),
        "coverageScope": "h6-host-file-transfer-viewer-upload-wire-abi-ownership",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "upstreamPathBasedSendFilesReusable": False,
            "canonicalRustDeskUploadWireReusable": passed,
            "nativeHostReceivePlaneReusable": passed,
            "swiftRetainsSourceDescriptorOwnership": passed,
            "rustOwnsUploadProtocolState": passed,
            "viewerABIV14Required": passed,
            "viewerABIChangedByThisAudit": False,
            "viewerABIV14SemanticReadImplemented": passed,
            "viewerUploadWireImplemented": passed,
            "viewerUploadProductActionImplemented": False,
            "twoMacAcceptanceComplete": False,
        },
        "frozenSeam": {
            "start": "RDNFileTransferUploadStart",
            "readRequest": "RDNFileTransferUploadReadRequest",
            "readMode": "synchronous-caller-owned-buffer",
            "maximumReadBytes": 128 * 1024,
            "pathOrDescriptorCrossesABI": False,
            "overwriteAllowed": False,
            "resumeAllowed": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
