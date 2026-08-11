#!/usr/bin/env python3
"""Audit H6.3f2b2i Viewer bounded descriptor-owned receive writes."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-safe-receive-write-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-safe-receive-commit-lifecycle"


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
        "owner": repository / "Sources/CoreBridge/ViewerFileTransferDestinationOwner.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferDestinationOwnerTests.swift",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
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

    owner = sources["owner"]
    tests = sources["tests"]
    product = sources["app"] + sources["agent"]
    reserve = function_body(
        owner,
        "package func reserveNewFile(",
        "/// Writes one bounded block",
    )
    write = function_body(
        owner,
        "package func writePayload(",
        "/// Removes only the exact staging inode",
    )
    metadata = function_body(
        owner,
        "private static func reservationMetadataMatches(",
        "private static func pwriteAll(",
    )
    pwrite = function_body(
        owner,
        "private static func pwriteAll(",
        "private static func matchesPinnedDirectory(",
    )
    evidence = {
        "designRecordsBoundedH63f2b2i": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2i Viewer safe receive write lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "reservationBindsExactRequestManifestAndLocalOffsetRange": all(
            marker in reserve
            for marker in (
                "request.sessionEpoch == sessionEpoch",
                "request.destination.token == leaseToken",
                "request.manifest.files.indices.contains(fileNumber)",
                "let file = request.manifest.files[fileNumber]",
                "file.size <= UInt64(Int64.max)",
                "bytesWritten: 0",
            )
        ),
        "payloadIsNonemptyCanonicalBoundAndCheckedAgainstManifest": (
            "maximumWriteChunkBytes = 128 * 1_024" in owner
            and all(marker in write for marker in (
                "!payload.isEmpty",
                "payload.count <= Self.maximumWriteChunkBytes",
                "addingReportingOverflow(payloadCount)",
                "!nextSizeResult.overflow",
                "nextSizeResult.partialValue <= reservation.file.size",
            ))
        ),
        "writesUseExactTrackedOffsetAndHandlePartialEINTR": all(
            marker in write + pwrite
            for marker in (
                "reservation.handle == handle",
                "offset: reservation.bytesWritten",
                "Darwin.pwrite(",
                "off_t(offset) + off_t(totalWritten)",
                "written < 0, errno == EINTR",
                "totalWritten += written",
                "succeeded && totalWritten == payload.count",
                "reservation.bytesWritten += persistedBytes",
                "reservation.bytesWritten == nextSize",
            )
        ),
        "preAndPostWriteMetadataAreExactAndNoFollow": (
            write.count("Self.reservationMetadataMatches(reservation)") >= 2
            and all(marker in metadata for marker in (
                "AT_SYMLINK_NOFOLLOW",
                "Darwin.fstat(reservation.fileDescriptor, &descriptorStatus)",
                "FileIdentity(device: namedStatus.st_dev, inode: namedStatus.st_ino)",
                "FileIdentity(device: descriptorStatus.st_dev, inode: descriptorStatus.st_ino)",
                "isPrivateOwnedFile(namedStatus)",
                "isPrivateOwnedFile(descriptorStatus)",
                "UInt64(namedStatus.st_size) == reservation.bytesWritten",
                "UInt64(descriptorStatus.st_size) == reservation.bytesWritten",
            ))
        ),
        "invalidOrFailedWriteTerminatesAndIdentitySafeCleanup": (
            write.count("activeReservations.removeValue(forKey: handle.transferID)") >= 3
            and write.count("Self.discardReservation(reservation)") >= 3
            and "Darwin.unlinkat(reservation.parentDescriptor, $0, 0)" in owner
            and "let matches = reservationMetadataMatches(reservation)" in owner
        ),
        "regressionsCoverExactBoundsDriftAndPartialTeardown": all(
            marker in tests
            for marker in (
                "testWritesBoundedPayloadAtExactOffsetWithoutCommitting",
                "testInvalidPayloadAndReplacementDriftAbortFailClosed",
                "Data(\"hello\".utf8)",
                "maximumWriteChunkBytes + 1",
                "XCTAssertNil(owner.writePayload(Data(\"!\".utf8), to: reservation))",
                "to: reservations[1]",
                "size: UInt64.max",
            )
        ),
        "successorCommitImplementedWhileWireABIAndProductRemainOff": (
            "Darwin.fsync(" in owner
            and "renameatx_np" in owner
            and "Darwin.futimens(" in owner
            and "RDNFileTransferReceiveReservation" not in sources["header"]
            and "Data::SendFiles" not in write + metadata + pwrite
            and "fileTransferPolicy:" not in product
            and "does not dispatch a download wire request" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2i Viewer safe receive write lifecycle",
        ),
        "chunkLimit": line_number(owner, "maximumWriteChunkBytes = 128 * 1_024"),
        "reservation": line_number(owner, "func reserveNewFile("),
        "write": line_number(owner, "func writePayload("),
        "metadata": line_number(owner, "func reservationMetadataMatches("),
        "pwrite": line_number(owner, "func pwriteAll("),
        "exactWriteRegression": line_number(
            tests,
            "testWritesBoundedPayloadAtExactOffsetWithoutCommitting",
        ),
        "driftRegression": line_number(
            tests,
            "testInvalidPayloadAndReplacementDriftAbortFailClosed",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-safe-receive-write-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-safe-receive-write-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerStagingReservationImplemented": status == expected_status,
            "viewerPayloadWriteImplemented": status == expected_status,
            "viewerFinalCommitImplemented": status == expected_status,
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
