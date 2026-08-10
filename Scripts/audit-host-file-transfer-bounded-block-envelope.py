#!/usr/bin/env python3
"""Audit H6.3c bounded wire and decoded file-transfer blocks."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-bounded-block-envelope-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "fs": repository / "Vendor/rustdesk/libs/hbb_common/src/fs.rs",
        "compress": repository / "Vendor/rustdesk/libs/hbb_common/src/compress.rs",
        "safe_root": repository
        / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-file-transfer-bounded-block.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
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

    design = sources["design"]
    fs = sources["fs"]
    compress = sources["compress"]
    safe_root = sources["safe_root"]
    patch = sources["patch"]
    bootstrap = sources["bootstrap"]
    product = sources["app"] + sources["agent"]

    wire_check = fs.find("if block.data.len() > MAX_FILE_TRANSFER_BLOCK_BYTES")
    decode = fs.find(
        "decompress_with_limit(&block.data, MAX_FILE_TRANSFER_BLOCK_BYTES)"
    )
    write_entry = fs.find("pub async fn write(&mut self, block: FileTransferBlock)")
    validation = fs.find("let payload = validated_file_transfer_block_payload(&block)?")
    data_source = fs.find("match &self.data_source", write_entry)
    file_create = fs.find("File::create(&path).await?", write_entry)

    evidence = {
        "designRecordsH63cBoundary": all(
            marker in design
            for marker in (
                "H6.3c Host bounded file-transfer block envelope",
                "host-file-transfer-safe-root-mutations",
            )
        ),
        "senderAndReceiverShare128KiBLimit": all(
            marker in fs
            for marker in (
                "MAX_FILE_TRANSFER_BLOCK_BYTES: usize = 128 * 1024",
                "vec![0; MAX_FILE_TRANSFER_BLOCK_BYTES]",
                "offset == MAX_FILE_TRANSFER_BLOCK_BYTES",
            )
        ),
        "wireLimitRunsBeforeDecompression": wire_check >= 0 and decode > wire_check,
        "compressedDecodeUsesBoundedHelper": (
            "pub fn decompress_with_limit" in compress
            and decode >= 0
            and "let tmp = decompress(&block.data);" not in fs
        ),
        "validationRunsBeforeWritePathFileCreate": (
            write_entry >= 0
            and validation > write_entry
            and data_source > validation
            and file_create > validation
        ),
        "rawAtLimitAndOversizeAreTested": all(
            marker in fs
            for marker in (
                "bounded_file_block_accepts_raw_and_compressed_payloads_at_decoded_limit",
                "bounded_file_block_rejects_raw_and_wire_payloads_over_limit",
            )
        ),
        "decodedOversizeAndMalformedCompressionAreTested": (
            "bounded_file_block_rejects_decoded_oversize_and_malformed_compression"
            in fs
        ),
        "canonicalPatchCarriesImplementationAndTests": all(
            marker in patch
            for marker in (
                "MAX_FILE_TRANSFER_BLOCK_BYTES",
                "validated_file_transfer_block_payload",
                "decompress_with_limit",
                "bounded_file_block_rejects_decoded_oversize_and_malformed_compression",
            )
        ),
        "bootstrapAppliesAndReverseChecksPatch": all(
            marker in bootstrap
            for marker in (
                "h6-file-transfer-bounded-block.patch",
                'apply --check "$file_transfer_block_patch_file"',
                'apply --check --reverse "$file_transfer_block_patch_file"',
            )
        ),
        "productStillDoesNotOptIn": "fileTransferEnabled:" not in product,
        "laterSafeReceiveRootPrimitiveExists": all(
            marker in safe_root
            for marker in (
                "struct NativeFileTransferRoot",
                "pub(crate) fn create_new_file",
                "pub(crate) fn open_existing_file_for_resume",
                "open_root_descriptor_survives_path_replacement",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3c Host bounded file-transfer block envelope"
        ),
        "hardLimit": line_number(fs, "MAX_FILE_TRANSFER_BLOCK_BYTES: usize"),
        "wireCheck": line_number(
            fs, "if block.data.len() > MAX_FILE_TRANSFER_BLOCK_BYTES"
        ),
        "boundedDecode": line_number(
            fs, "decompress_with_limit(&block.data, MAX_FILE_TRANSFER_BLOCK_BYTES)"
        ),
        "writeAdmission": line_number(
            fs, "let payload = validated_file_transfer_block_payload(&block)?"
        ),
        "writePathFileCreate": line_number(fs, "File::create(&path).await?"),
        "focusedTests": line_number(
            fs, "bounded_file_block_accepts_raw_and_compressed_payloads_at_decoded_limit"
        ),
        "canonicalPatch": line_number(patch, "MAX_FILE_TRANSFER_BLOCK_BYTES"),
        "bootstrapPatch": line_number(
            bootstrap, "h6-file-transfer-bounded-block.patch"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "bounded-file-block-envelope-implemented-product-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-bounded-block-envelope",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "wireBlockLimitBytes": 128 * 1024,
            "decodedBlockLimitBytes": 128 * 1024,
            "compressedPayloadBounded": True,
            "productFileTransferEnabled": False,
            "symlinkRaceClosed": False,
            "nativeHostFileServiceOwnerImplemented": False,
            "safeReceiveRootPrimitiveImplemented": True,
            "safeRootMutationsImplemented": False,
        },
        "nextImplementationBoundary": "host-file-transfer-safe-root-mutations",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "bounded-file-block-envelope-implemented-product-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
