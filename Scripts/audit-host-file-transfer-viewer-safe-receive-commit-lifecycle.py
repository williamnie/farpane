#!/usr/bin/env python3
"""Audit H6.3f2b2j Viewer durable no-replace receive commit."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-safe-receive-commit-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-download-dispatch-receive-adapter-lifecycle"


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
    commit = function_body(
        owner,
        "package func commitReservation(",
        "/// Removes only the exact staging inode",
    )
    mtime = function_body(
        owner,
        "private static func reservationModifiedTimeMatches(",
        "private static func pwriteAll(",
    )
    evidence = {
        "designRecordsDurableCommitMilestone": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2j Viewer safe receive commit lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "commitRequiresExactCompleteOwnedReservation": all(
            marker in commit
            for marker in (
                "reservation.handle == handle",
                "reservation.bytesWritten == reservation.file.size",
                "Self.reservationMetadataMatches(reservation)",
                "Self.reservationModifiedTimeMatches(reservation)",
                "Self.destinationNameIsAbsent(",
            )
        ),
        "mtimeAndFileAreSyncedBeforePublication": (
            "Self.applyModifiedTime(reservation.file.modifiedTime" in commit
            and "Darwin.fsync(reservation.fileDescriptor) == 0" in commit
            and all(marker in mtime for marker in (
                "modifiedTime >= 0",
                "UTIME_OMIT",
                "time_t(modifiedTime)",
                "Darwin.futimens(descriptor, &times) == 0",
                "status.st_mtimespec.tv_sec == time_t(reservation.file.modifiedTime)",
                "status.st_mtimespec.tv_nsec == 0",
            ))
        ),
        "publicationIsDescriptorRelativeAtomicAndNoReplace": all(
            marker in commit
            for marker in (
                "Darwin.renameatx_np(",
                "reservation.parentDescriptor",
                "reservation.stagingName",
                "reservation.finalName",
                "RENAME_EXCL",
            )
        ),
        "directoryDurabilityAndAmbiguousTerminalAreExplicit": all(
            marker in owner + commit
            for marker in (
                "case durabilityUnconfirmed",
                "Darwin.fsync(reservation.parentDescriptor) == 0",
                "directorySynced ? .committed : .durabilityUnconfirmed",
            )
        ),
        "preRenameFailureSafelyTerminatesWithoutReplacement": (
            commit.count("activeReservations.removeValue(forKey: handle.transferID)") >= 3
            and commit.count("Self.discardReservation(reservation)") >= 2
            and "Darwin.unlinkat(reservation.parentDescriptor, $0, 0)" in owner
        ),
        "realFilesystemRegressionsCoverCommitMtimeIncompleteAndRace": all(
            marker in tests
            for marker in (
                "testCommitsExactFileWithDeclaredModifiedTimeAndNoStagingRemainder",
                "testCommitRejectsIncompleteFileAndNeverReplacesRacingDestination",
                "status.st_mtimespec.tv_sec",
                "XCTAssertEqual(owner.commitReservation(reservation), .committed)",
                "XCTAssertEqual(owner.commitReservation(incomplete), .rejected)",
                "XCTAssertEqual(try Data(contentsOf: final), existing)",
            )
        ),
        "wireABIAndProductRemainOff": (
            "RDNFileTransferReceiveReservation" not in sources["header"]
            and "Data::SendFiles" not in commit
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "does not dispatch a download wire request" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2j Viewer safe receive commit lifecycle",
        ),
        "commitResult": line_number(owner, "enum ViewerFileTransferReceiveCommitResult"),
        "commit": line_number(owner, "func commitReservation("),
        "mtime": line_number(owner, "func applyModifiedTime("),
        "commitRegression": line_number(
            tests,
            "testCommitsExactFileWithDeclaredModifiedTimeAndNoStagingRemainder",
        ),
        "raceRegression": line_number(
            tests,
            "testCommitRejectsIncompleteFileAndNeverReplacesRacingDestination",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-safe-receive-commit-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-safe-receive-commit-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
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
