#!/usr/bin/env python3
"""Audit H6.3f1 Viewer destination/progress API contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-destination-progress-contract-audit"


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
        "contract": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferContractTests.swift",
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

    design = sources["design"]
    architecture = sources["architecture"]
    contract = sources["contract"]
    tests = sources["tests"]
    header = sources["header"]
    product = sources["app"] + sources["agent"]

    evidence = {
        "designRecordsH63f1Boundary": all(
            marker in design
            for marker in (
                "H6.3f1 Viewer file-transfer destination/progress API contract",
                "host-file-transfer-viewer-destination-descriptor-owner",
            )
        ),
        "destinationIsOpaqueAndSessionBound": all(
            marker in contract
            for marker in (
                "ViewerFileTransferDestinationLease",
                "package let token: UInt64",
                "package let sessionEpoch: UInt64",
                "destination.sessionEpoch == sessionEpoch",
            )
        ),
        "remoteManifestIsCanonicalAndBounded": all(
            marker in contract
            for marker in (
                "maximumEntries = 1_024",
                "maximumMetadataUTF8Bytes = 1_024 * 1_024",
                "precomposedStringWithCanonicalMapping",
                "canonicalCollisionKey",
                "privateStagingSuffix",
                "addingReportingOverflow(file.size)",
            )
        ),
        "progressIsConnectionBoundAndMonotonic": all(
            marker in contract
            for marker in (
                "ViewerFileTransferProgressAuthority",
                "maximumConcurrentTransfers = 8",
                "update.sessionEpoch == previous.sessionEpoch",
                "update.sequence > previous.sequence",
                "update.bytesCompleted >= previous.bytesCompleted",
                "update.filesCompleted >= previous.filesCompleted",
            )
        ),
        "progressRejectsInvalidConflictAndCompletion": all(
            marker in contract
            for marker in (
                "update.phase == .waitingForConflict",
                "update.phase == .completed",
                "update.filesCompleted != previous.totalFiles",
                "update.bytesCompleted != previous.totalBytes",
            )
        ),
        "cancelAndTeardownAreFailClosed": all(
            marker in contract
            for marker in (
                "requestCancellation",
                "previous.phase != .cancelling",
                "case .cancelling:",
                "teardown(sessionEpoch:",
            )
        ),
        "failuresAreTypedAndPathFree": all(
            marker in contract
            for marker in (
                "ViewerFileTransferFailure",
                "case rejected",
                "case unavailable",
                "case protocolViolation",
                "case localIO",
                "case connectionClosed",
            )
        ),
        "focusedTestsCoverContractBoundaries": all(
            marker in tests
            for marker in (
                "testManifestAcceptsOnlyBoundedCanonicalNonCollidingPaths",
                "testManifestRejectsEntryMetadataAndByteOverflow",
                "testRequestRequiresSessionBoundOpaqueDestinationAndPositiveID",
                "testProgressIsMonotonicBoundedAndTerminal",
                "testConflictCancellationStaleSessionAndTeardownFailClosed",
                "testConcurrencyLimitAndDuplicateIdentifiersAreBounded",
            )
        ),
        "architectureRecordsContractAndRemainingABI": all(
            marker in architecture
            for marker in (
                "session-bound opaque lease",
                "严格递增 sequence",
                "Viewer ABI v14",
                "destination\n  owner",
                "产品能力必须继续保持关闭",
            )
        ),
        "viewerCoreABISeamExistsAndProductRemainsOff": (
            "#define RDN_ABI_VERSION 15u" in header
            and "RDNFileTransferEventCallback on_file_transfer_event;" in header
            and "rdn_client_file_transfer_cancel" in header
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3f1 Viewer file-transfer destination/progress API contract"
        ),
        "destinationLease": line_number(
            contract, "struct ViewerFileTransferDestinationLease"
        ),
        "manifest": line_number(contract, "struct ViewerFileTransferManifest"),
        "pathAdmission": line_number(contract, "static func accepts(relativePath:"),
        "request": line_number(contract, "struct ViewerFileTransferDownloadRequest"),
        "progressAuthority": line_number(
            contract, "struct ViewerFileTransferProgressAuthority"
        ),
        "progressAdmission": line_number(contract, "mutating func observe("),
        "cancel": line_number(contract, "mutating func requestCancellation("),
        "teardown": line_number(contract, "mutating func teardown(sessionEpoch:"),
        "focusedTests": line_number(tests, "final class ViewerFileTransferContractTests"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-destination-progress-contract-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-destination-progress-contract",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDestinationProgressContractImplemented": status == expected_status,
            "viewerCoreFileTransferABISeamImplemented": True,
            "viewerCoreFileTransferRuntimeImplemented": False,
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
