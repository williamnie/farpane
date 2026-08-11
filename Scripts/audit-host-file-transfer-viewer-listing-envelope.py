#!/usr/bin/env python3
"""Audit H6.3f2b2a Viewer remote-list structural envelope."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-listing-envelope-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-destination-descriptor-owner"


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

    bridge = sources["bridge"]
    header = sources["header"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2a": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2a Viewer remote-list structural envelope",
                NEXT_BOUNDARY,
            )
        ),
        "ownedListingHasExplicitBounds": all(
            marker in bridge
            for marker in (
                "const MAX_FILE_TRANSFER_LIST_ENTRIES: usize = 1_024;",
                "const MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES: usize = 1_024 * 1_024;",
                "relative_path: String,",
                "fn native_viewer_remote_listing(entries: &[FileEntry])",
                "metadata_utf8_bytes.checked_add(name.len())?",
                "relative_path: name.to_owned(),",
            )
        ),
        "unsafeNamesTypesAndAliasesFailClosed": all(
            marker in bridge
            for marker in (
                'name == "."',
                'name == ".."',
                "name.contains('/')",
                "name.contains('\\\\')",
                "name.chars().any(char::is_control)",
                ".ends_with(FILE_TRANSFER_PRIVATE_STAGING_SUFFIX)",
                "if !collision_keys.insert(name.to_ascii_lowercase())",
                "if entry.is_hidden",
                "Ok(FileType::Dir) if entry.size == 0",
                "Ok(FileType::File)",
                "_ => return None",
            )
        ),
        "rustRegressionsCoverOwnershipAndRejection": all(
            marker in bridge
            for marker in (
                "viewer_remote_listing_owns_bounded_regular_entries",
                'entries[0].name = "changed".to_owned();',
                'assert_eq!(listing[0].relative_path, "资料");',
                "viewer_remote_listing_rejects_unsafe_types_names_aliases_and_bounds",
                "0..=MAX_FILE_TRANSFER_LIST_ENTRIES",
                "MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES + 1",
            )
        ),
        "unicodeRevalidationIsNowLayeredInSwift": (
            "NFC, full case-fold collision" in sources["readme"]
            and "byte-exact NFC、完整 case-fold" in sources["architecture"]
            and "byte-exact NFC、完整 case-fold collision" in sources["design"]
        ),
        "abiV12RetainsEnvelopeAndListLifecycle": (
            "#define RDN_ABI_VERSION 18u" in header
            and "rdn_client_file_transfer_list_root" in header
            and "RDNFileTransferListEvent" in header
        ),
        "productRemainsOff": "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product,
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2a Viewer remote-list structural envelope",
        ),
        "entryLimit": line_number(bridge, "MAX_FILE_TRANSFER_LIST_ENTRIES"),
        "ownedEntry": line_number(bridge, "struct NativeViewerRemoteListEntry"),
        "listingEnvelope": line_number(bridge, "fn native_viewer_remote_listing("),
        "ownershipRegression": line_number(
            bridge, "fn viewer_remote_listing_owns_bounded_regular_entries()"
        ),
        "rejectionRegression": line_number(
            bridge,
            "fn viewer_remote_listing_rejects_unsafe_types_names_aliases_and_bounds()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-remote-listing-envelope-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-listing-envelope",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRemoteListingEnvelopeImplemented": status == expected_status,
            "viewerListCommandCallbackImplemented": True,
            "viewerDestinationIOImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
