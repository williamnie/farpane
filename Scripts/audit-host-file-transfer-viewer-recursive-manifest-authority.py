#!/usr/bin/env python3
"""Audit H6.3f2b2d Viewer recursive manifest authority lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-recursive-manifest-authority-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-recursive-manifest-abi-lifecycle"


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
        "authority": repository / "Sources/CoreBridge/ViewerFileTransferRecursiveManifestAuthority.swift",
        "manifest": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferRecursiveManifestAuthorityTests.swift",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "core": repository / "Sources/CoreBridge/CoreBridge.swift",
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

    authority = sources["authority"]
    tests = sources["tests"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2d": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2d Viewer recursive manifest authority lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "oneExactRequestOwnsTwoSemanticParts": all(
            marker in authority
            for marker in (
                "private var activeRequest: ActiveRequest?",
                "package mutating func begin(sessionEpoch: UInt64, requestID: Int32)",
                "case files([ViewerFileTransferFile])",
                "case emptyDirectories([String])",
                "activeRequest.sessionEpoch == sessionEpoch",
                "activeRequest.requestID == requestID",
            )
        ),
        "partsAreIndependentlyBoundedBeforeRetention": all(
            marker in authority
            for marker in (
                "files.count <= ViewerFileTransferManifest.maximumEntries",
                "emptyDirectories.count <= ViewerFileTransferManifest.maximumEntries",
                "emptyDirectories.allSatisfy(ViewerFileTransferManifest.accepts(relativePath:))",
                "next.partialValue <= ViewerFileTransferManifest.maximumMetadataUTF8Bytes",
            )
        ),
        "completionReusesCanonicalCombinedManifest": all(
            marker in authority
            for marker in (
                "guard let files = active.files,",
                "let emptyDirectories = active.emptyDirectories",
                "ViewerFileTransferManifest(",
                "return .completed(manifest)",
                "return failProtocolViolation()",
            )
        ),
        "failureAndTeardownAreExactAndTerminal": all(
            marker in authority
            for marker in (
                "case .rejected, .unavailable, .connectionClosed:",
                "case .protocolViolation, .localIO:",
                "package mutating func teardown(sessionEpoch: UInt64) -> Int32?",
                "activeRequest?.sessionEpoch == sessionEpoch",
                "activeRequest = nil",
            )
        ),
        "regressionsCoverOrderBoundsCollisionAndTeardown": all(
            marker in tests
            for marker in (
                "testCompletesOnlyAfterBothExactSessionPartsInEitherOrder",
                "testStaleDuplicateAndCrossPartCollisionsFailClosed",
                "testEachPartIsBoundedBeforeRetention",
                "testStableFailureAndExactTeardownAreTerminal",
                ".failed(.protocolViolation)",
            )
        ),
        "authorityOwnsNoDestinationOrIO": all(
            marker not in authority
            for marker in (
                "URL",
                "descriptor",
                "open(",
                "openat(",
                "write(",
                "FileHandle",
            )
        ),
        "abiV12RetainsRemoteLifecycleWithoutChangingAuthority": (
            "#define RDN_ABI_VERSION 15u" in sources["header"]
            and "rdn_client_file_transfer_manifest_root" in sources["header"]
            and "rdn_client_file_transfer_manifest_root" in sources["bridge"]
            and "requestFileTransferRecursiveManifest" in sources["core"]
        ),
        "productRemainsOffAndGapIsExplicit": (
            "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "download start" in sources["architecture"]
            and "No download command" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2d Viewer recursive manifest authority lifecycle",
        ),
        "authorityType": line_number(
            authority,
            "package struct ViewerFileTransferRecursiveManifestAuthority",
        ),
        "begin": line_number(authority, "package mutating func begin("),
        "observe": line_number(authority, "package mutating func observe("),
        "finalManifest": line_number(authority, "ViewerFileTransferManifest("),
        "teardown": line_number(authority, "package mutating func teardown("),
        "focusedRegression": line_number(
            tests,
            "testCompletesOnlyAfterBothExactSessionPartsInEitherOrder",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-recursive-manifest-authority-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-recursive-manifest-authority",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRecursiveManifestAuthorityImplemented": status == expected_status,
            "viewerRecursiveManifestABILifecycleImplemented": status == expected_status,
            "viewerDownloadIOImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
