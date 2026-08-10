#!/usr/bin/env python3
"""Audit H6.3f2b2e Viewer recursive-manifest ABI lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-recursive-manifest-abi-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-download-start-abi-lifecycle"


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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "authority": repository / "Sources/CoreBridge/ViewerFileTransferRecursiveManifestAuthority.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferRecursiveManifestAuthorityTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
        "build_core": repository / "Scripts/build-rust-core.sh",
        "build_universal": repository / "Scripts/build-universal.sh",
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

    header = sources["header"]
    bridge = sources["bridge"]
    swift = sources["swift"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2e": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2e Viewer recursive manifest ABI lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "abiV12RetainsTwoCallbackScopedSemanticParts": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 13u",
                "typedef enum RDNFileTransferManifestPartKind",
                "RDN_FILE_TRANSFER_MANIFEST_PART_FILES = 1",
                "RDN_FILE_TRANSFER_MANIFEST_PART_EMPTY_DIRECTORIES = 2",
                "typedef struct RDNFileTransferManifestEvent",
                "RDNFileTransferManifestCallback on_file_transfer_manifest;",
                "rdn_client_file_transfer_manifest_root",
            )
        ),
        "rustCommandIsExactPermissionGatedAndSingleFlight": all(
            marker in bridge
            for marker in (
                "pub unsafe extern \"C\" fn rdn_client_file_transfer_manifest_root(",
                "if session_epoch == 0 || request_id <= 0",
                "return -10;",
                "if !client.shared.authenticated.load(Ordering::Acquire)",
                "if !*session.server_file_transfer_enabled.read().unwrap()",
                "pending_file_manifest_request",
                "file_manifest_request_epoch",
                ".compare_exchange(0, session_epoch",
                "native_viewer_file_manifest_root_messages(request_id)",
            )
        ),
        "wireRequestsAreRootBoundedAndHiddenOff": all(
            marker in bridge
            for marker in (
                "files_action.set_all_files(ReadAllFiles",
                "id: request_id",
                'path: "/".to_owned()',
                "directories_action.set_read_empty_dirs(ReadEmptyDirs",
                "include_hidden: false",
            )
        ),
        "responsesAreOwnedBoundedSemanticAndExact": all(
            marker in bridge
            for marker in (
                "fn native_viewer_remote_manifest_files(",
                "fn native_viewer_remote_manifest_empty_directories(",
                "fn native_viewer_manifest_relative_path(",
                "request.request_id == id",
                'if is_local || only_count || path != "/"',
                'response.path != "/"',
                "FILE_TRANSFER_LIST_REJECTED",
                "FILE_TRANSFER_LIST_UNAVAILABLE",
                "active.files_delivered",
                "active.empty_directories_delivered",
            )
        ),
        "swiftCopiesRevalidatesAndProjectsAuthorityParts": all(
            marker in swift
            for marker in (
                "public struct CoreFileTransferManifestEvent",
                "private let fileTransferManifestCallback",
                "Data(bytes: pathBytes, count: rawEntry.relative_path_length)",
                "ViewerFileTransferManifest.accepts(relativePath: entry.relativePath)",
                "package var recursiveManifestPart",
                "box.deliverFileTransferManifest(event)",
                "public func requestFileTransferRecursiveManifest(",
            )
        ) and "package struct ViewerFileTransferRecursiveManifestAuthority" in sources["authority"],
        "shimBuildAndBuiltCoreRequireManifestSymbol": (
            'dlsym(\n            handle, "rdn_client_file_transfer_manifest_root")'
            in sources["shim"]
            and "library->client_file_transfer_manifest_root == NULL" in sources["shim"]
            and all(
                "_rdn_client_file_transfer_manifest_root" in sources[name]
                for name in ("build_core", "build_universal")
            )
            and 'dlsym(handle, "rdn_client_file_transfer_manifest_root")'
            in sources["host_tests"]
        ),
        "regressionsCoverTwoPartsBoundsFailuresAndSwiftValidation": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "viewer_recursive_manifest_parts_are_owned_bounded_and_semantic",
                "viewer_recursive_manifest_command_delivers_two_exact_parts_and_clears",
                "an untagged empty-directory response makes manifest single-use per epoch",
                "testABIManifestPartsRevalidateAndProjectSemanticPayloads",
                "testCompletesOnlyAfterBothExactSessionPartsInEitherOrder",
            )
        ),
        "productAndDownloadIORemainOff": (
            "fileTransferEnabled:" not in product
            and "No download command" in sources["readme"]
            and "download start" in sources["architecture"]
            and "rdn_client_file_transfer_download_start" in header
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2e Viewer recursive manifest ABI lifecycle",
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 13u"),
        "manifestEvent": line_number(header, "typedef struct RDNFileTransferManifestEvent"),
        "manifestCommand": line_number(header, "rdn_client_file_transfer_manifest_root"),
        "rustCommand": line_number(bridge, "fn rdn_client_file_transfer_manifest_root("),
        "rustFilesResponse": line_number(bridge, "fn update_folder_files("),
        "rustDirectoriesResponse": line_number(bridge, "fn update_empty_dirs("),
        "swiftCallback": line_number(swift, "private let fileTransferManifestCallback"),
        "swiftCommand": line_number(swift, "public func requestFileTransferRecursiveManifest("),
        "rustRegression": line_number(
            bridge,
            "fn viewer_recursive_manifest_command_delivers_two_exact_parts_and_clears()",
        ),
        "swiftRegression": line_number(
            sources["swift_tests"],
            "testABIManifestPartsRevalidateAndProjectSemanticPayloads",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-recursive-manifest-abi-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-recursive-manifest-abi-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRecursiveManifestAuthorityImplemented": status == expected_status,
            "viewerRecursiveManifestABILifecycleImplemented": status == expected_status,
            "viewerDownloadStartImplemented": status == expected_status,
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
