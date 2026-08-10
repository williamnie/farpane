#!/usr/bin/env python3
"""Audit H6.3f2b2b Viewer root-list command/callback ABI lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-root-list-lifecycle-audit"
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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "manifest": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "destination_owner": repository / "Sources/CoreBridge/ViewerFileTransferDestinationOwner.swift",
        "recursive_authority": repository / "Sources/CoreBridge/ViewerFileTransferRecursiveManifestAuthority.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferContractTests.swift",
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
        "designRecordsBoundedH63f2b2b": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2b Viewer root-list command/callback ABI lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "abiV10HasBoundedCallbackScopedListShape": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 10u",
                "#define RDN_MAX_FILE_TRANSFER_LIST_ENTRIES 1024u",
                "typedef struct RDNFileTransferListEntry {",
                "const uint8_t *relative_path_utf8;",
                "typedef struct RDNFileTransferListEvent {",
                "RDNFileTransferListCallback on_file_transfer_list;",
                "rdn_client_file_transfer_list_root",
            )
        ),
        "rustCommandIsExactPermissionGatedAndSingleFlight": all(
            marker in bridge
            for marker in (
                "pub unsafe extern \"C\" fn rdn_client_file_transfer_list_root(",
                "if session_epoch == 0 || request_id <= 0",
                "return -10;",
                "if !client.shared.authenticated.load(Ordering::Acquire)",
                "if !*session.server_file_transfer_enabled.read().unwrap()",
                "if pending.is_some()",
                "*pending = Some(request);",
                "native_viewer_file_list_root_message()",
                'path: "/".to_owned()',
                "include_hidden: false",
            )
        ),
        "rustResponseAndTeardownAreFailClosed": all(
            marker in bridge
            for marker in (
                "pending_file_list_request: Mutex<Option<NativeViewerListRequest>>",
                'if is_local || only_count || path != "/"',
                "FILE_TRANSFER_LIST_REJECTED",
                "FILE_TRANSFER_LIST_UNAVAILABLE",
                "native_viewer_remote_listing(entries)",
                ".pending_file_list_request",
                "worker_shared",
                "fn clear_all_jobs(&self)",
            )
        ),
        "swiftCopiesAndRevalidatesBeforeQueuedDelivery": all(
            marker in swift
            for marker in (
                "private let fileTransferListCallback",
                "Data(bytes: pathBytes, count: rawEntry.relative_path_length)",
                "CoreFileTransferListEvent(",
                "ViewerFileTransferManifest.accepts(relativePath: entry.relativePath)",
                'entry.relativePath.contains("\\\\")',
                ".controlCharacters",
                "collisionKeys.insert(collisionKey).inserted",
                "box.deliverFileTransferList(event)",
                "public func requestFileTransferRootList(sessionEpoch:",
                "callbackBox.stopFileTransferDelivery()",
            )
        ),
        "nfcCheckIsByteExact": (
            "relativePath.utf8.elementsEqual(" in sources["manifest"]
            and 'relativePath: "e\\u{301}"' in sources["swift_tests"]
        ),
        "shimBuildAndBuiltCoreTestsRequireListSymbol": (
            'dlsym(\n            handle, "rdn_client_file_transfer_list_root")'
            in sources["shim"]
            and "library->client_file_transfer_list_root == NULL" in sources["shim"]
            and all(
                "_rdn_client_file_transfer_list_root" in sources[name]
                for name in ("build_core", "build_universal")
            )
            and 'dlsym(handle, "rdn_client_file_transfer_list_root")'
            in sources["host_tests"]
        ),
        "regressionsCoverCommandCallbackAndSwiftValidation": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "viewer_file_transfer_list_root_is_exact_single_flight_and_callback_scoped",
                "FILE_TRANSFER_LIST_SUCCESS",
                "FILE_TRANSFER_LIST_REJECTED",
                "FILE_TRANSFER_LIST_UNAVAILABLE",
                "testRemoteRootListRevalidatesOwnedMetadataAndStableFailures",
            )
        ),
        "destinationOwnerNowPrecedesRemainingIOGap": (
            "package final class ViewerFileTransferDestinationOwner" in sources["destination_owner"]
            and "O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"
            in sources["destination_owner"]
            and "openat(" not in sources["destination_owner"]
        ),
        "productRemainsOffAndIOGapIsExplicit": (
            "fileTransferEnabled:" not in product
            and "远端 recursive-manifest command/callback" in sources["architecture"]
            and "No remote recursive-manifest command/callback" in sources["readme"]
        ),
        "recursiveAuthorityNowPrecedesRemoteManifestABI": (
            "package struct ViewerFileTransferRecursiveManifestAuthority"
            in sources["recursive_authority"]
            and "rdn_client_file_transfer_manifest" not in header
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2b Viewer root-list command/callback ABI lifecycle",
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 10u"),
        "listEvent": line_number(header, "typedef struct RDNFileTransferListEvent {"),
        "listCommand": line_number(header, "rdn_client_file_transfer_list_root"),
        "rustCommand": line_number(bridge, "fn rdn_client_file_transfer_list_root("),
        "rustResponse": line_number(bridge, "fn update_folder_files("),
        "swiftCallback": line_number(swift, "private let fileTransferListCallback"),
        "swiftCommand": line_number(swift, "public func requestFileTransferRootList("),
        "nfcCheck": line_number(sources["manifest"], "relativePath.utf8.elementsEqual("),
        "rustRegression": line_number(
            bridge,
            "fn viewer_file_transfer_list_root_is_exact_single_flight_and_callback_scoped()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-root-list-abi-lifecycle-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-root-list-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRootListCommandCallbackImplemented": status == expected_status,
            "viewerRecursiveManifestAuthorityImplemented": status == expected_status,
            "viewerRecursiveManifestABILifecycleImplemented": False,
            "viewerDestinationDescriptorOwnerImplemented": status == expected_status,
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
