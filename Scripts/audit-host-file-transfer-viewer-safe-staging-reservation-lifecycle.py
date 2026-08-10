#!/usr/bin/env python3
"""Audit H6.3f2b2h Viewer descriptor-relative staging reservation lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-safe-staging-reservation-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-safe-receive-write-lifecycle"


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
    handle = function_body(
        owner,
        "package struct ViewerFileTransferReceiveReservation",
        "/// Owns a Viewer download destination directory",
    )
    reserve = function_body(
        owner,
        "package func reserveNewFile(",
        "/// Removes only the exact staging inode",
    )
    cancel = function_body(
        owner,
        "package func cancelReservation(",
        "/// Closes the pinned descriptor",
    )
    parent = function_body(
        owner,
        "private static func openOrCreatePrivateParent(",
        "private static func discardCreatedReservation(",
    )
    cleanup = function_body(
        owner,
        "private static func discardCreatedReservation(",
        "private static func matchesPinnedDirectory(",
    )
    evidence = {
        "designRecordsBoundedH63f2b2h": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2h Viewer safe staging reservation lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "handleIsPathAndDescriptorFree": all(
            marker in handle
            for marker in (
                "sessionEpoch: UInt64",
                "transferID: Int32",
                "fileNumber: Int",
                "token: UInt64",
            )
        ) and all(marker not in handle.lower() for marker in ("path", "descriptor", "string")),
        "admissionIsExactBoundedAndManifestScoped": all(
            marker in reserve
            for marker in (
                "request.sessionEpoch == sessionEpoch",
                "request.destination.sessionEpoch == sessionEpoch",
                "request.destination.token == leaseToken",
                "request.transferID > 0",
                "fileNumber >= 0",
                "fileNumber < ViewerFileTransferManifest.maximumEntries",
                "request.manifest.files.indices.contains(fileNumber)",
                "reservationToken > 0",
                "ViewerFileTransferManifest.accepts(relativePath: file.relativePath)",
                "activeReservations.count < Self.maximumActiveReservations",
                "activeReservations[request.transferID] == nil",
                "matchesPinnedDirectory(directoryDescriptor, identity: identity)",
            )
        ) and "maximumActiveReservations = 8" in owner,
        "parentTraversalIsDescriptorRelativePrivateAndNoFollow": all(
            marker in parent
            for marker in (
                "Darwin.openat(",
                "O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.mkdirat(current, $0, mode_t(0o700))",
                "isPrivateOwnedDirectory(status)",
            )
        ) and "directoryURL" not in parent,
        "stagingIsExclusiveEmptyPrivateAndFinalAbsent": all(
            marker in reserve
            for marker in (
                "Darwin.fstatat(parentDescriptor, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)",
                "finalLookup != 0, errno == ENOENT",
                "ViewerFileTransferManifest.privateStagingSuffix",
                "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.fchmod(fileDescriptor, mode_t(0o600))",
                "Self.isPrivateOwnedEmptyFile(status)",
            )
        ),
        "cancelTeardownAndDeinitAreIdentitySafe": all(
            marker in cancel + cleanup + owner
            for marker in (
                "activeReservations[handle.transferID]?.handle == handle",
                "FileIdentity(device: namedStatus.st_dev, inode: namedStatus.st_ino)",
                "isPrivateOwnedFile(namedStatus)",
                "Darwin.unlinkat(reservation.parentDescriptor, $0, 0)",
                "let reservations = Array(activeReservations.values)",
                "activeReservations.removeAll()",
            )
        ),
        "regressionsUseThrowawayFilesystemAndCoverSafety": all(
            marker in tests
            for marker in (
                "testReservesAndCancelsOnlyExactPrivateStagingFile",
                "testReservationCapTeardownAndReplacementCleanupFailClosed",
                "testPinnedDescriptorDoesNotFollowReplacementAtSelectedPath",
                "one.txt.farpane-part",
                "XCTAssertFalse(owner.cancelReservation(reservations[0]))",
                "ViewerFileTransferDestinationOwner.maximumActiveReservations",
            )
        ),
        "boundedWriteAndCommitEvolutionStillLeaveWireABIAndProductOff": (
            "maximumWriteChunkBytes = 128 * 1_024" in owner
            and "Darwin.pwrite(" in owner
            and "Darwin.fsync(" in owner
            and "renameatx_np" in owner
            and "RDNFileTransferReceiveReservation" not in sources["header"]
            and "Data::SendFiles" not in reserve + parent + cleanup
            and "fileTransferEnabled:" not in product
            and "does not dispatch a download wire request" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2h Viewer safe staging reservation lifecycle",
        ),
        "reservationHandle": line_number(owner, "struct ViewerFileTransferReceiveReservation"),
        "reservationLimit": line_number(owner, "maximumActiveReservations = 8"),
        "reserve": line_number(owner, "func reserveNewFile("),
        "cancel": line_number(owner, "func cancelReservation("),
        "parentTraversal": line_number(owner, "func openOrCreatePrivateParent("),
        "identityCleanup": line_number(owner, "func discardReservation("),
        "focusedRegression": line_number(
            tests,
            "testReservesAndCancelsOnlyExactPrivateStagingFile",
        ),
        "replacementRegression": line_number(
            tests,
            "testReservationCapTeardownAndReplacementCleanupFailClosed",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-safe-staging-reservation-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-safe-staging-reservation-lifecycle",
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
