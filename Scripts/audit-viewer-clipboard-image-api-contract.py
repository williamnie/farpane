#!/usr/bin/env python3
"""Audit the H6.2k2 default-off Viewer image clipboard API contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-image-clipboard-api-contract-audit"


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
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "pasteboard": repository / "Sources/RustDeskNative/ViewerPasteboardOwner.swift",
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "io_loop": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "ui_session": repository / "Vendor/rustdesk/src/ui_session_interface.rs",
        "patch": repository / "CoreBridge/RustDeskPatch/h6-viewer-image-api.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "build_core": repository / "Scripts/build-rust-core.sh",
        "build_universal": repository / "Scripts/build-universal.sh",
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
    io_loop = sources["io_loop"]
    product_sources = sources["app"] + sources["pasteboard"]
    evidence = {
        "designRecordsBoundedH6Step": (
            "H6.2k2 Viewer image clipboard API contract" in sources["design"]
        ),
        "viewerABIv8CarriesBoundedSemanticImage": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 8u",
                "#define RDN_MAX_CLIPBOARD_IMAGE_BYTES 134217728u",
                "#define RDN_MAX_CLIPBOARD_SVG_UTF8_BYTES 4194304u",
                "#define RDN_MAX_CLIPBOARD_IMAGE_DIMENSION 8192u",
                "#define RDN_MAX_CLIPBOARD_IMAGE_PIXELS 33177600u",
                "typedef struct RDNClipboardImagePayload",
                "RDNClipboardImageCallback on_clipboard_image;",
                "bool receive_clipboard_image;",
                "bool send_clipboard_image;",
                "rdn_client_send_clipboard_image",
            )
        ),
        "shimRequiresImageSendSymbol": all(
            marker in sources["shim"]
            for marker in (
                '"rdn_client_send_clipboard_image"',
                "library->client_send_clipboard_image == NULL",
                "library->client_send_clipboard_image(client, payload)",
            )
        ),
        "imageDirectionsDefaultOffAndIndependent": all(
            marker in swift
            for marker in (
                "receiveClipboardImage: Bool = false",
                "sendClipboardImage: Bool = false",
                "receive_clipboard_image: config.receiveClipboardImage",
                "send_clipboard_image: config.sendClipboardImage",
            )
        ),
        "incomingImagesAreOwnedStrictAndBounded": all(
            marker in bridge
            for marker in (
                "pub struct NativeViewerClipboardImage",
                "pub(crate) fn native_viewer_clipboard_image(",
                "ClipboardFormat::ImageRgba",
                "ClipboardFormat::ImagePng",
                "ClipboardFormat::ImageSvg",
                "decompress_with_limit(&clipboard.content, decoded_limit)",
                "native_viewer_image_pixel_count",
                "native_viewer_png_dimensions",
                "native_viewer_svg_has_canonical_root",
            )
        ),
        "disabledReceiveRejectsBeforeParseAndRechecksDelivery": all(
            marker in (bridge + io_loop + sources["ui_session"])
            for marker in (
                "fn native_clipboard_image_enabled(&self) -> bool",
                "if self.handler.native_clipboard_image_enabled()",
                "native_viewer_clipboard_image(&clipboards)",
                "fn emit_clipboard_image(&self, image: NativeViewerClipboardImage)",
                "self.receive_clipboard_image.load(Ordering::Acquire)",
                "self.remote_clipboard_enabled.load(Ordering::Acquire)",
            )
        ),
        "outgoingImagesAreCanonicalBoundedAndPermissionGated": all(
            marker in bridge
            for marker in (
                "unsafe fn native_viewer_clipboard_image_message(",
                "message.set_clipboard(Clipboard {",
                "pub unsafe extern \"C\" fn rdn_client_send_clipboard_image(",
                "if !client.shared.send_clipboard_image.load(Ordering::Acquire)",
                "return -7;",
                "return -8;",
            )
        ),
        "swiftCopiesRevalidatesAndLifecycleGatesImage": all(
            marker in swift
            for marker in (
                "public enum CoreClipboardImagePayload",
                "let data = Data(bytes: bytes, count: raw.length)",
                "guard let normalized = normalizedClipboardImage(candidate) else { return }",
                "box.deliverClipboardImage(payload)",
                "public func sendClipboardImage(_ payload: CoreClipboardImagePayload)",
                "callbackBox.stopClipboardDelivery()",
            )
        ),
        "productDoesNotEnableOrOwnImages": (
            "receiveClipboardImage: true" not in product_sources
            and "sendClipboardImage: true" not in product_sources
            and "CoreClipboardImagePayload" not in product_sources
        ),
        "hostImageTransportIsBoundedAndIndependent": all(
            marker in sources["host_bridge"]
            for marker in (
                "ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg",
                "NativeClipboardTransferPolicy::with_image_policy(",
                "transfer_policy.image()",
                "image.into_canonical_clipboard()",
                "native_host_prepare_outgoing_clipboard_message(",
                "native_host_prepare_incoming_clipboard_entries(",
            )
        ),
        "regressionsCoverFormatsBoundsDefaultsAndGates": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "native_viewer_image_receive_preparse_gate_requires_every_authority",
                "native_viewer_image_clipboard_accepts_owned_bounded_canonical_payloads",
                "native_viewer_image_clipboard_rejects_ambiguous_or_unbounded_input",
                "native_viewer_image_clipboard_builds_canonical_outbound_messages",
                "native_viewer_image_clipboard_rejects_invalid_outbound_payloads",
                "native_viewer_image_send_requires_every_lifecycle_and_permission_gate",
                "testViewerClipboardDirectionsAreExplicitAndIndependent",
                "testViewerClipboardDeliveryStopsBeforeCoreDisconnect",
            )
        ),
        "buildsRequireImageABISymbol": all(
            "_rdn_client_send_clipboard_image" in sources[name]
            for name in ("build_core", "build_universal")
        ),
        "trackedPatchAndBootstrapCarryRuntimeChanges": all(
            marker in (sources["patch"] + sources["bootstrap"])
            for marker in (
                "h6-viewer-image-api.patch",
                "native_clipboard_image_enabled",
                "native_viewer_clipboard_image",
                "--check --reverse \"$viewer_image_patch_file\"",
            )
        ),
        "documentationRecordsDefaultOffBoundary": all(
            marker in (sources["readme"] + sources["architecture"])
            for marker in (
                "ABI v8 retains the ABI v7 bounded small- and rich-text contracts",
                "do not enable or consume the image directions in this step",
                "新增的 image read/write 仍默认关闭",
                "Host Control ABI v15 now carries independent image read/write policy",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.2k2 Viewer image clipboard API contract"
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 8u"),
        "imagePayload": line_number(header, "typedef struct RDNClipboardImagePayload"),
        "imageCallback": line_number(header, "RDNClipboardImageCallback on_clipboard_image;"),
        "imageSendAPI": line_number(header, "rdn_client_send_clipboard_image"),
        "preParseGate": line_number(io_loop, "if self.handler.native_clipboard_image_enabled()"),
        "incomingParser": line_number(bridge, "pub(crate) fn native_viewer_clipboard_image("),
        "outgoingBuilder": line_number(bridge, "unsafe fn native_viewer_clipboard_image_message("),
        "sendGate": line_number(bridge, "pub unsafe extern \"C\" fn rdn_client_send_clipboard_image("),
        "swiftDefaults": line_number(swift, "receiveClipboardImage: Bool = false"),
        "swiftCallback": line_number(swift, "private let clipboardImageCallback"),
        "swiftSend": line_number(swift, "public func sendClipboardImage("),
        "coreBuildSymbol": line_number(sources["build_core"], "_rdn_client_send_clipboard_image"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-image-clipboard-api-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-image-clipboard-api",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerABIv8Implemented": True,
            "imageDirectionsDefaultOff": True,
            "rgbaAndPNGBoundedTo128MiB": True,
            "svgBoundedTo4MiB": True,
            "disabledReceiveParsesImagePayload": False,
            "swiftCopiesCallbackScopedBytes": True,
            "viewerProductImageClipboardEnabled": False,
            "hostImageClipboardTransportCapable": True,
            "svgRenderingSanitized": False,
        },
        "remainingBoundary": {
            "hostViewerImageTransportWiringRequired": False,
            "singlePasteboardOwnerImageIntegrationRequired": True,
            "hostImageExplicitOptInRequired": True,
            "installedTwoMacImageClipboardAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "viewer-image-pasteboard-owner-explicit-enablement-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "viewer-image-clipboard-api-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
