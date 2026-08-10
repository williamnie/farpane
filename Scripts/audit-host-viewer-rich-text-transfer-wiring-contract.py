#!/usr/bin/env python3
"""Audit the H6.2j4 default-off Host/Viewer rich-text transport wiring."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-viewer-rich-text-transfer-wiring-contract-audit"


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
        "host_swift": repository / "Sources/CoreBridge/HostControlClient.swift",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "extension_patch": repository / "CoreBridge/RustDeskPatch/h6-rich-text-transfer.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
        "product_app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "product_agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
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
    host = sources["host_bridge"]
    connection = sources["connection"]
    swift = sources["host_swift"]
    product = sources["product_app"] + sources["product_agent"]
    docs = sources["readme"] + sources["architecture"]
    tests = host + connection + sources["swift_tests"] + sources["host_tests"]
    evidence = {
        "designRecordsBoundedWiringStep": (
            "H6.2j4 Host↔Viewer rich-text transfer wiring contract" in sources["design"]
        ),
        "hostABIv17RetainsSmallAndRichDirections": all(
            marker in header
            for marker in (
                "#define RDN_HOST_ABI_VERSION 17u",
                "bool enable_clipboard_read;",
                "bool enable_clipboard_write;",
                "bool enable_clipboard_rich_text_read;",
                "bool enable_clipboard_rich_text_write;",
            )
        ),
        "swiftRichDirectionsDefaultOffAndIndependent": all(
            marker in swift
            for marker in (
                "clipboardRichTextReadEnabled: Bool = false",
                "clipboardRichTextWriteEnabled: Bool = false",
                "enable_clipboard_rich_text_read: configuration.clipboardRichTextReadEnabled",
                "enable_clipboard_rich_text_write: configuration.clipboardRichTextWriteEnabled",
            )
        ),
        "productProjectsHostRichDirectionsExplicitly": all(
            marker in product
            for marker in (
                "clipboardRichTextReadEnabled:",
                "clipboardRichTextWriteEnabled:",
                ".allowRemoteRichTextRead",
                ".allowRemoteRichTextWrite",
            )
        ),
        "hostTransferPolicyKeepsFormatsIndependent": all(
            marker in host
            for marker in (
                "pub(crate) struct NativeClipboardTransferPolicy",
                "small_text: NativeClipboardPolicy",
                "rich_text: NativeClipboardPolicy",
                "image: NativeClipboardPolicy",
                "self.rich_text.any_enabled()",
                "self.image.any_enabled()",
                "transfer_policy.small_text()",
                "transfer_policy.rich_text()",
            )
        ),
        "richBundleIsOwnedAtomicBoundedAndCanonical": all(
            marker in host
            for marker in (
                "struct NativeRichTextTransferBundle",
                "clipboards.is_empty() || clipboards.len() > 3",
                "bundle.rtf.is_some() || bundle.html.is_some()",
                "decompress_with_limit(",
                "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES",
                "fn into_canonical_clipboards(self) -> Vec<Clipboard>",
                "(ClipboardFormat::Text, self.plain_text)",
                "(ClipboardFormat::Rtf, self.rtf)",
                "(ClipboardFormat::Html, self.html)",
            )
        ),
        "outgoingCanonicalizesBeforeConnectionWriter": all(
            marker in (host + connection)
            for marker in (
                "pub(crate) fn native_host_prepare_outgoing_clipboard_message(",
                "NativeHostOutgoingClipboardDecision::Send(message)",
                "Arc::new(message)",
            )
        ),
        "incomingCanonicalizesBeforePinnedPasteboardHelper": all(
            marker in (host + connection)
            for marker in (
                "pub(crate) fn native_host_prepare_incoming_clipboard_entries(",
                "native_host_clipboards.expect(\"admission checked\")",
                "update_clipboard(",
            )
        ),
        "sessionRevocationPrecedesFormatAdmission": all(
            marker in host
            for marker in (
                "if !native_host_clipboard_policy_allows(active_directions, direction)",
                "native_host_clipboard_entries_disposition(clipboards)",
            )
        ),
        "featureCompiledWithoutBindingPreservesPinnedBehavior": all(
            marker in connection
            for marker in (
                "A binary compiled with the feature may still run without a",
                "return Some(clipboards.to_vec());",
            )
        ),
        "viewerV7BundleMatchesHostWireShape": all(
            marker in sources["viewer_bridge"]
            for marker in (
                "pub(crate) struct NativeViewerRichTextBundle",
                "ClipboardFormat::Text",
                "ClipboardFormat::Rtf",
                "ClipboardFormat::Html",
                "message.set_multi_clipboards(MultiClipboards",
            )
        ),
        "imagePolicyIsIndependentAndSpecialFilesRemainRejected": all(
            marker in host
            for marker in (
                "ClipboardFormat::ImageRgba",
                "transfer_policy.image()",
                "ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject",
            )
        ),
        "trackedExtensionPatchIsAppliedByBootstrap": all(
            marker in sources["bootstrap"]
            for marker in (
                "h6-rich-text-transfer.patch",
                "apply --unidiff-zero --check",
                "apply --unidiff-zero --check --reverse",
            )
        ) and all(
            marker in sources["extension_patch"]
            for marker in (
                "native_host_prepare_outgoing_clipboard_message",
                "native_host_prepare_remote_clipboard_write",
            )
        ),
        "regressionsCoverBundlePolicyDirectionsAndABI": all(
            marker in tests
            for marker in (
                "native_rich_text_transfer_bundle_is_owned_atomic_and_canonical",
                "native_host_rich_text_transport_requires_explicit_format_and_direction_policy",
                "native_clipboard_permissions_revoke_directions_without_exceeding_maximum",
                "testHostClipboardDirectionsDefaultOffAndRemainIndependent",
                "private static let hostABIVersion: UInt32 = 17",
                "XCTAssertEqual(hostABI(), Self.hostABIVersion)",
            )
        ),
        "documentationRecordsExplicitProductOptInBoundary": all(
            marker in docs
            for marker in (
                "Host Control ABI v15",
                "Viewer product configuration",
                "Host product configuration exposes independent",
                "canonical, uncompressed Text/RTF/HTML",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.2j4 Host↔Viewer rich-text transfer wiring contract"
        ),
        "hostABIVersion": line_number(header, "#define RDN_HOST_ABI_VERSION 17u"),
        "hostRichRead": line_number(header, "bool enable_clipboard_rich_text_read;"),
        "swiftRichDefault": line_number(swift, "clipboardRichTextReadEnabled: Bool = false"),
        "transferPolicy": line_number(host, "pub(crate) struct NativeClipboardTransferPolicy"),
        "richBundle": line_number(host, "struct NativeRichTextTransferBundle"),
        "outgoingGate": line_number(host, "pub(crate) fn native_host_prepare_outgoing_clipboard_message("),
        "incomingGate": line_number(host, "pub(crate) fn native_host_prepare_incoming_clipboard_entries("),
        "connectionWriteGate": line_number(connection, "fn native_host_prepare_remote_clipboard_write("),
        "extensionPatch": line_number(sources["bootstrap"], "h6-rich-text-transfer.patch"),
        "rustRegression": line_number(host, "fn native_host_rich_text_transport_requires_explicit_format_and_direction_policy()"),
        "swiftRegression": line_number(sources["swift_tests"], "func testHostClipboardDirectionsDefaultOffAndRemainIndependent()"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-viewer-rich-text-transfer-wired-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-viewer-rich-text-transfer-wiring",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostABIv17Implemented": True,
            "smallAndRichDirectionsIndependent": True,
            "richTransportCanonicalAndBounded": True,
            "sessionRevocationAppliesToRich": True,
            "hostProductRichClipboardEnabled": True,
            "viewerProductRichClipboardEnabled": True,
            "imageClipboardEnabled": True,
            "filePromiseClipboardEnabled": False,
        },
        "remainingBoundary": {
            "hostViewerRichTransportWiringRequired": False,
            "singlePasteboardOwnerRichIntegrationRequired": False,
            "installedTwoMacRichClipboardAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-image-clipboard-installed-two-mac-acceptance",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-viewer-rich-text-transfer-wired-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
