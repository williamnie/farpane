#!/usr/bin/env python3
"""Audit H6.3f2b2c Viewer destination descriptor ownership."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-destination-descriptor-owner-audit"
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
        "owner": repository / "Sources/CoreBridge/ViewerFileTransferDestinationOwner.swift",
        "contract": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferDestinationOwnerTests.swift",
        "recursive_authority": repository / "Sources/CoreBridge/ViewerFileTransferRecursiveManifestAuthority.swift",
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
    stored_state = owner.split("package init?", maxsplit=1)[0]
    state_declarations = "\n".join(
        line.strip()
        for line in stored_state.splitlines()
        if line.strip().startswith(("private let ", "private var "))
    )
    evidence = {
        "designRecordsBoundedH63f2b2c": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2c Viewer destination descriptor owner",
                NEXT_BOUNDARY,
            )
        ),
        "openPinsNoFollowReadOnlyDirectory": all(
            marker in owner
            for marker in (
                "O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.fstat(descriptor, &status)",
                "status.st_mode & S_IFMT == S_IFDIR",
                "status.st_uid == geteuid()",
                "status.st_mode & mode_t(0o777) == mode_t(0o700)",
                "status.st_nlink > 0",
            )
        ),
        "stateRetainsDescriptorIdentityLeaseNotPath": (
            "private let sessionEpoch: UInt64" in stored_state
            and "private let leaseToken: UInt64" in stored_state
            and "private let identity: DirectoryIdentity" in stored_state
            and "private var directoryDescriptor: Int32?" in stored_state
            and "URL" not in state_declarations
            and "path" not in state_declarations.lower()
        ),
        "borrowRequiresExactLeaseAndFreshIdentity": all(
            marker in owner
            for marker in (
                "lease.sessionEpoch == sessionEpoch",
                "lease.token == leaseToken",
                "Self.matchesPinnedDirectory(",
                "status.st_dev, inode: status.st_ino) == identity",
                "return try body(directoryDescriptor)",
            )
        ),
        "exactTeardownAndDeinitClose": all(
            marker in owner
            for marker in (
                "package func teardown(sessionEpoch: UInt64) -> Bool",
                "sessionEpoch == self.sessionEpoch",
                "directoryDescriptor = nil",
                "deinit {",
                "Darwin.close(descriptor)",
            )
        ),
        "regressionsCoverFailClosedAndPinnedIdentity": all(
            marker in tests
            for marker in (
                "testPinsPrivateOwnedDirectoryForMatchingLease",
                "testRejectsUnsafeDirectoriesAndInvalidAuthority",
                "testBorrowFailsClosedForStaleLeasePermissionDriftAndTeardown",
                "testPinnedDescriptorDoesNotFollowReplacementAtSelectedPath",
                "XCTAssertEqual(borrowedInode, originalInode)",
            )
        ),
        "stagingWriteAndCommitEvolutionPreservePinnedOwner": (
            "package func reserveNewFile(" in owner
            and "package func writePayload(" in owner
            and "Darwin.openat(" in owner
            and "Darwin.pwrite(" in owner
            and "O_EXCL | O_NOFOLLOW" in owner
            and "Darwin.fsync(" in owner
            and "renameatx_np" in owner
        ),
        "abiAndProductRemainOff": (
            "#define RDN_ABI_VERSION 12u" in sources["header"]
            and "fileTransferEnabled:" not in product
            and "No download command" in sources["readme"]
            and "handle 不含路径/descriptor" in sources["architecture"]
        ),
        "recursiveAuthorityNowPrecedesRemoteManifestABI": (
            "package struct ViewerFileTransferRecursiveManifestAuthority"
            in sources["recursive_authority"]
            and "rdn_client_file_transfer_manifest_root" in sources["header"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2c Viewer destination descriptor owner",
        ),
        "ownerType": line_number(owner, "package final class ViewerFileTransferDestinationOwner"),
        "openFlags": line_number(owner, "O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"),
        "borrow": line_number(owner, "package func withPinnedDirectoryDescriptor"),
        "teardown": line_number(owner, "package func teardown(sessionEpoch: UInt64) -> Bool"),
        "replacementRegression": line_number(
            tests,
            "testPinnedDescriptorDoesNotFollowReplacementAtSelectedPath",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-destination-descriptor-owner-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-destination-descriptor-owner",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDestinationDescriptorOwnerImplemented": status == expected_status,
            "viewerRecursiveManifestAuthorityImplemented": status == expected_status,
            "viewerRecursiveManifestABILifecycleImplemented": False,
            "viewerDownloadIOImplemented": status == expected_status,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
