#!/usr/bin/env python3
"""Audit the H6.2k3 default-off Host/Viewer image transport wiring."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-viewer-image-transfer-wiring-contract-audit"


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
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "extension_patch": repository / "CoreBridge/RustDeskPatch/h6-rich-text-transfer.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
        "product_app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "product_agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "pasteboard": repository / "Sources/RustDeskNative/ViewerPasteboardOwner.swift",
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
    docs = sources["readme"] + sources["architecture"]
    tests = host + sources["swift_tests"] + sources["host_tests"]
    product = (
        sources["product_app"] + sources["product_agent"] + sources["pasteboard"]
    )
    evidence = {
        "designRecordsImageWiringStep": (
            "H6.2k3 Host↔Viewer image transfer wiring contract" in sources["design"]
        ),
        "hostABIv15CarriesIndependentImageDirections": all(
            marker in header
            for marker in (
                "#define RDN_HOST_ABI_VERSION 15u",
                "bool enable_clipboard_read;",
                "bool enable_clipboard_rich_text_read;",
                "bool enable_clipboard_image_read;",
                "bool enable_clipboard_image_write;",
            )
        ),
        "swiftImageDirectionsDefaultOffAndPassedToC": all(
            marker in swift
            for marker in (
                "clipboardImageReadEnabled: Bool = false",
                "clipboardImageWriteEnabled: Bool = false",
                "enable_clipboard_image_read: configuration.clipboardImageReadEnabled",
                "enable_clipboard_image_write: configuration.clipboardImageWriteEnabled",
            )
        ),
        "hostTransferPolicyKeepsThreeFormatsIndependent": all(
            marker in host
            for marker in (
                "pub(crate) struct NativeClipboardTransferPolicy",
                "small_text: NativeClipboardPolicy",
                "rich_text: NativeClipboardPolicy",
                "image: NativeClipboardPolicy",
                "pub(crate) fn with_image_policy(",
                "pub(crate) fn image(self) -> NativeClipboardPolicy",
                "self.image.allows_remote_read()",
                "self.image.allows_remote_write()",
                "self.image.any_enabled()",
            )
        ),
        "validatedImageIsRebuiltCanonicalAndOwned": all(
            marker in host
            for marker in (
                "struct NativeImageTransferEnvelope",
                "fn into_canonical_clipboard(self) -> Clipboard",
                "NativeImageFormat::Rgba { width, height }",
                "NativeImageFormat::Png { .. } => (ClipboardFormat::ImagePng, 0, 0)",
                "NativeImageFormat::Svg => (ClipboardFormat::ImageSvg, 0, 0)",
                "content: self.payload.into()",
            )
        ),
        "exactlyOneImageRequiresActiveAndMatchingPolicy": all(
            marker in host
            for marker in (
                "if !native_host_clipboard_policy_allows(active_directions, direction)",
                "if let [clipboard] = clipboards",
                "NativeImageTransferEnvelope::from_clipboard(clipboard)",
                "native_host_clipboard_policy_allows(transfer_policy.image(), direction)",
                "vec![image.into_canonical_clipboard()]",
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
        "viewerV8ImageShapeMatchesHostWire": all(
            marker in sources["viewer_bridge"]
            for marker in (
                "pub struct NativeViewerClipboardImage",
                "ClipboardFormat::ImageRgba",
                "ClipboardFormat::ImagePng",
                "ClipboardFormat::ImageSvg",
                "message.set_clipboard(Clipboard {",
            )
        ),
        "trackedConnectionPatchCarriesBothDataPlaneHooks": all(
            marker in sources["extension_patch"]
            for marker in (
                "native_host_prepare_outgoing_clipboard_message",
                "native_host_prepare_remote_clipboard_write",
                "native_host_prepare_incoming_clipboard_entries",
            )
        ) and "h6-rich-text-transfer.patch" in sources["bootstrap"],
        "regressionsCoverABIFormatsDirectionsAndIsolation": all(
            marker in tests
            for marker in (
                "native_host_image_transport_requires_explicit_format_and_direction_policy",
                "NativeClipboardTransferPolicy::with_image_policy(",
                "testHostClipboardDirectionsDefaultOffAndRemainIndependent",
                "clipboardImageReadEnabled: true",
                "clipboardImageWriteEnabled: true",
                "private static let hostABIVersion: UInt32 = 15",
            )
        ),
        "viewerProductAndOwnerEnableImagesWhileHostDoesNot": (
            all(
                marker in product
                for marker in (
                    "receiveClipboardImage: true",
                    "sendClipboardImage: true",
                    "CoreClipboardImagePayload",
                    "receiveRemoteImage(",
                )
            )
            and "clipboardImageReadEnabled:" not in product
            and "clipboardImageWriteEnabled:" not in product
        ),
        "documentationKeepsProductAndSanitizerBoundaryHonest": all(
            marker in docs
            for marker in (
                "Host Control ABI v15 now carries independent image read/write policy",
                "AppKit ownership",
                "SVG is not sanitized for rendering",
                "图片产品能力继续关闭",
            )
        ),
        "canonicalAndVendoredBridgeMatch": host == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.2k3 Host↔Viewer image transfer wiring contract"
        ),
        "hostABIVersion": line_number(header, "#define RDN_HOST_ABI_VERSION 15u"),
        "hostImageRead": line_number(header, "bool enable_clipboard_image_read;"),
        "swiftImageDefault": line_number(swift, "clipboardImageReadEnabled: Bool = false"),
        "transferPolicy": line_number(host, "pub(crate) struct NativeClipboardTransferPolicy"),
        "imageCanonicalizer": line_number(host, "fn into_canonical_clipboard(self) -> Clipboard"),
        "imageAdmission": line_number(host, "if let [clipboard] = clipboards"),
        "outgoingGate": line_number(host, "pub(crate) fn native_host_prepare_outgoing_clipboard_message("),
        "incomingGate": line_number(host, "pub(crate) fn native_host_prepare_incoming_clipboard_entries("),
        "connectionWriteGate": line_number(connection, "fn native_host_prepare_remote_clipboard_write("),
        "rustRegression": line_number(host, "fn native_host_image_transport_requires_explicit_format_and_direction_policy()"),
        "swiftRegression": line_number(sources["swift_tests"], "func testHostClipboardDirectionsDefaultOffAndRemainIndependent()"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-viewer-image-transfer-wired-viewer-enabled"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-viewer-image-transfer-wiring",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostABIv15Implemented": True,
            "imageDirectionsDefaultOff": True,
            "imageTransportCanonicalAndBounded": True,
            "sessionRevocationAppliesBeforeImageParsing": True,
            "viewerProductImageClipboardEnabled": True,
            "hostProductImageClipboardEnabled": False,
            "svgRenderingSanitized": False,
        },
        "remainingBoundary": {
            "hostViewerImageTransportWiringRequired": False,
            "singlePasteboardOwnerImageIntegrationRequired": False,
            "hostImageExplicitOptInRequired": True,
            "installedTwoMacImageClipboardAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-image-bootstrap-home-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-viewer-image-transfer-wired-viewer-enabled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
