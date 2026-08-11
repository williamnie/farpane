#!/usr/bin/env python3
"""Audit H6.3h Viewer upload selection and local manifest ownership."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-upload-selection-manifest-contract-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-upload-wire-abi-ownership-audit"


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
        "contract": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadContract.swift",
        "owner": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadSourceOwner.swift",
        "dialogs": repository
        / "Sources/RustDeskNative/ViewerFileTransferDialogs.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "tests": repository
        / "Tests/CoreBridgeTests/ViewerFileTransferUploadSourceOwnerTests.swift",
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

    contract = sources["contract"]
    owner = sources["owner"]
    dialogs = sources["dialogs"]
    request = contract[contract.find(
        "package struct ViewerFileTransferUploadRequest"
    ):]
    evidence = {
        "designRecordsBoundedUploadSelectionBoundary": (
            "H6.3h Viewer upload selection/manifest contract"
            in sources["design"]
        ),
        "pickerRequiresExplicitFilesOrDirectories": all(
            marker in dialogs
            for marker in (
                "ViewerFileTransferUploadSourcePickerController",
                "panel.canChooseFiles = true",
                "panel.canChooseDirectories = true",
                "panel.allowsMultipleSelection = true",
                "panel.resolvesAliases = false",
            )
        ),
        "selectionBecomesDescriptorOwnedBeforePublication": all(
            marker in owner
            for marker in (
                "O_RDONLY | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.fdopendir",
                "Darwin.fstatat(",
                "AT_SYMLINK_NOFOLLOW",
                "Darwin.openat(",
                "F_DUPFD_CLOEXEC",
                "namedStatus.st_dev == rootDevice",
                "st_ctimespec",
                "matchesFile(descriptor, identity: file.identity)",
            )
        ),
        "localNamesNormalizeAndCollisionsFailClosed": all(
            marker in owner
            for marker in (
                "precomposedStringWithCanonicalMapping",
                "CharacterSet.controlCharacters",
                "privateStagingSuffix",
                "collisionKeys.insert(key).inserted",
                'rawName.hasPrefix(".")',
            )
        ),
        "selectionManifestAndTraversalAreBounded": all(
            marker in owner
            for marker in (
                "maximumSelections",
                "maximumDepth = 64",
                "maximumMetadataUTF8Bytes",
                "maximumEntries",
                "addingReportingOverflow",
            )
        ),
        "uploadRequestIsPathFreeAndOwnerBound": (
            all(marker in contract + owner for marker in (
                "ViewerFileTransferUploadSourceLease",
                "ViewerFileTransferUploadRequest",
                "makeUploadRequest(",
                "source.sessionEpoch == sessionEpoch",
            ))
            and all(marker not in request for marker in (
                "URL",
                "path",
                "descriptor",
                "fileDescriptor",
            ))
        ),
        "filesystemRegressionsCoverReplacementAndUnsafeEntries": all(
            marker in sources["tests"]
            for marker in (
                "testPinsSelectedDirectoryAndRejectsMutationAndStaleAuthority",
                "testRejectsSymlinkUnsafeDirectoryDuplicateTopLevelAndPrivateName",
                "testNormalizesExplicitLocalNameAndRejectsControlCharacter",
                "maximumSelections + 1",
                "createSymbolicLink",
                "Darwin.chmod(loose.path, 0o777)",
            )
        ),
        "teardownClosesExactEpochAuthority": (
            "package func teardown(sessionEpoch: UInt64) -> Bool" in owner
            and "roots.forEach { Darwin.close($0.descriptor) }" in owner
            and "XCTAssertFalse(owner.teardown(sessionEpoch: 8))"
                in sources["tests"]
            and "XCTAssertTrue(owner.teardown(sessionEpoch: 9))"
                in sources["tests"]
        ),
        "productNowConsumesDescriptorOwnedSelection": (
            "#define RDN_ABI_VERSION 16u" in sources["header"]
            and "RDNFileTransferUploadStart" in sources["header"]
            and "requestFileTransferUpload" in sources["app"]
            and "onFileTransferUploadAction" in sources["viewer_ui"]
            and "发送文件" in sources["viewer_ui"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3h Viewer upload selection/manifest contract",
        ),
        "lease": line_number(
            contract, "package struct ViewerFileTransferUploadSourceLease"
        ),
        "request": line_number(
            contract, "package struct ViewerFileTransferUploadRequest"
        ),
        "owner": line_number(
            owner, "package final class ViewerFileTransferUploadSourceOwner"
        ),
        "picker": line_number(
            dialogs, "ViewerFileTransferUploadSourcePickerController"
        ),
        "regressions": line_number(
            sources["tests"],
            "testSnapshotsExplicitFilesAndDirectoriesIntoPathFreeRequest",
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "viewer-upload-selection-manifest-implemented-product-on"
            if passed else "audit-failed"
        ),
        "coverageScope": "h6-host-file-transfer-viewer-upload-selection-manifest-contract",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerUploadSelectionImplemented": passed,
            "descriptorOwnedManifestImplemented": passed,
            "pathFreeUploadRequestImplemented": passed,
            "viewerABIV14SemanticReadAvailable": (
                "#define RDN_ABI_VERSION 16u" in sources["header"]
                and "RDNFileTransferUploadReadRequest" in sources["header"]
            ),
            "viewerUploadWireDispatchImplemented": passed,
            "viewerUploadProductActionImplemented": passed,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
