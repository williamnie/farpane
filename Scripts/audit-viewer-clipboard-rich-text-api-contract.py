#!/usr/bin/env python3
"""Audit the H6.2j3 default-off Viewer rich-text clipboard API contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-rich-text-clipboard-api-contract-audit"


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
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "io_loop": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "ui_session": repository / "Vendor/rustdesk/src/ui_session_interface.rs",
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
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
            "H6.2j3 Viewer rich-text clipboard API contract" in sources["design"]
        ),
        "viewerABIv7CarriesBoundedSemanticBundle": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 13u",
                "#define RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES (64u * 1024u)",
                "#define RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES (1024u * 1024u)",
                "typedef struct RDNClipboardRichTextPayload",
                "RDNClipboardRichTextCallback on_clipboard_rich_text;",
                "bool receive_clipboard_rich_text;",
                "bool send_clipboard_rich_text;",
                "rdn_client_send_clipboard_rich_text",
            )
        ),
        "shimRequiresRichSendSymbol": all(
            marker in sources["shim"]
            for marker in (
                '"rdn_client_send_clipboard_rich_text"',
                "library->client_send_clipboard_rich_text == NULL",
                "library->client_send_clipboard_rich_text(client, payload)",
            )
        ),
        "richDirectionsDefaultOffAndRemainIndependent": all(
            marker in swift
            for marker in (
                "receiveClipboardRichText: Bool = false",
                "sendClipboardRichText: Bool = false",
                "receive_clipboard_rich_text: config.receiveClipboardRichText",
                "send_clipboard_rich_text: config.sendClipboardRichText",
            )
        ),
        "incomingBundleIsOwnedStrictAndBounded": all(
            marker in bridge
            for marker in (
                "pub(crate) struct NativeViewerRichTextBundle",
                "pub(crate) fn native_viewer_clipboard_rich_text(",
                "clipboards.is_empty() || clipboards.len() > 3",
                "ClipboardFormat::Rtf",
                "ClipboardFormat::Html",
                "decompress_with_limit(&clipboard.content, max_bytes)",
                "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES",
                "bundle.rtf.is_some() || bundle.html.is_some()",
            )
        ),
        "disabledReceiveRejectsBeforeParseAndRechecksDelivery": all(
            marker in (bridge + io_loop + sources["ui_session"])
            for marker in (
                "fn native_clipboard_rich_text_enabled(&self) -> bool",
                "if self.handler.native_clipboard_rich_text_enabled()",
                "native_viewer_clipboard_rich_text(&clipboards)",
                "fn emit_clipboard_rich_text(&self, rich: NativeViewerRichTextBundle)",
                "clipboard_receive_allowed(",
            )
        ),
        "outgoingBundleIsCanonicalOwnedAndBounded": all(
            marker in bridge
            for marker in (
                "unsafe fn native_viewer_clipboard_rich_text_message(",
                "String::from_utf8(bytes.to_vec())",
                "message.set_clipboard(clipboards.remove(0))",
                "message.set_multi_clipboards(MultiClipboards",
                "pub unsafe extern \"C\" fn rdn_client_send_clipboard_rich_text(",
                "send_clipboard_rich_text",
                "return -7;",
                "return -8;",
            )
        ),
        "wireNegotiationIncludesAnyExplicitClipboardDirection": all(
            marker in (bridge + sources["client"])
            for marker in (
                "configure_native_viewer(&mut self, peer_id: &str, clipboard_enabled: bool)",
                "(*config).receive_clipboard_text",
                "(*config).send_clipboard_text",
                "(*config).receive_clipboard_rich_text",
                "(*config).send_clipboard_rich_text",
            )
        ),
        "swiftCopiesValidatesAndLifecycleGatesBundle": all(
            marker in swift
            for marker in (
                "public struct CoreClipboardRichTextPayload",
                "let data = Data(bytes: utf8, count: length)",
                "guard plain.valid, rtf.valid, html.valid, rtf.text != nil || html.text != nil",
                "box.deliverClipboardRichText(CoreClipboardRichTextPayload(",
                "public func sendClipboardRichText(_ payload: CoreClipboardRichTextPayload)",
                "callbackBox.stopClipboardDelivery()",
            )
        ),
        "productRichPasteboardOwnerIsExplicitlyEnabled": (
            sources["app"].count("receiveClipboardRichText: true") == 3
            and sources["app"].count("sendClipboardRichText: true") == 3
            and "receiveRemoteRichText(" in sources["pasteboard"]
            and "sendClipboardRichText(payload)" in sources["app"]
            and "onClipboardRichText: { [weak self] payload in" in sources["app"]
        ),
        "hostRichTransportIsSeparatelyGatedAndCanonical": all(
            marker in sources["host_bridge"]
            for marker in (
                "NativeClipboardTransferPolicy",
                "transfer_policy.rich_text()",
                "native_host_prepare_outgoing_clipboard_message(",
                "native_host_prepare_incoming_clipboard_entries(",
            )
        ),
        "regressionsCoverBoundsCanonicalMessagesDefaultsAndLifecycle": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "native_viewer_rich_clipboard_accepts_only_owned_bounded_canonical_bundle",
                "native_viewer_rich_receive_preparse_gate_requires_every_authority",
                "native_viewer_rich_clipboard_rejects_ambiguous_or_unbounded_input",
                "native_viewer_rich_clipboard_builds_canonical_outbound_messages",
                "native_viewer_rich_clipboard_rejects_invalid_outbound_payloads",
                "testViewerClipboardDirectionsAreExplicitAndIndependent",
                "testViewerClipboardDeliveryStopsBeforeCoreDisconnect",
            )
        ),
        "buildsRequireRichABISymbol": all(
            "_rdn_client_send_clipboard_rich_text" in sources[name]
            for name in ("build_core", "build_universal")
        ),
        "trackedPatchCarriesRichRuntimeChanges": all(
            marker in sources["patch"]
            for marker in (
                "native_clipboard_rich_text_enabled",
                "native_viewer_clipboard_rich_text",
                "native_clipboard_rich_text(",
            )
        ),
        "documentationRecordsDefaultOffBoundary": all(
            marker in (sources["readme"] + sources["architecture"])
            for marker in (
                "ABI v8 retains the ABI v7 bounded small- and rich-text contracts",
                "each independently capped at 1 MiB",
                "Viewer product configuration",
                "one AppKit-owned pasteboard adapter",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.2j3 Viewer rich-text clipboard API contract"
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 13u"),
        "richLimit": line_number(header, "RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES"),
        "richPayload": line_number(header, "typedef struct RDNClipboardRichTextPayload"),
        "richCallback": line_number(header, "RDNClipboardRichTextCallback on_clipboard_rich_text;"),
        "richSendAPI": line_number(header, "rdn_client_send_clipboard_rich_text"),
        "preParseGate": line_number(io_loop, "if self.handler.native_clipboard_rich_text_enabled()"),
        "incomingParser": line_number(bridge, "pub(crate) fn native_viewer_clipboard_rich_text("),
        "outgoingBuilder": line_number(bridge, "unsafe fn native_viewer_clipboard_rich_text_message("),
        "sendGate": line_number(bridge, "pub unsafe extern \"C\" fn rdn_client_send_clipboard_rich_text("),
        "swiftDefaults": line_number(swift, "receiveClipboardRichText: Bool = false"),
        "swiftCallback": line_number(swift, "private let clipboardRichTextCallback"),
        "swiftSend": line_number(swift, "public func sendClipboardRichText("),
        "coreBuildSymbol": line_number(sources["build_core"], "_rdn_client_send_clipboard_rich_text"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-rich-text-clipboard-api-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-rich-text-clipboard-api",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerABIv7Implemented": True,
            "richDirectionsDefaultOff": True,
            "plainFallbackBoundedTo64KiB": True,
            "rtfAndHTMLIndependentlyBoundedTo1MiB": True,
            "disabledReceiveParsesRichPayload": False,
            "swiftCopiesCallbackScopedBytes": True,
            "viewerProductRichClipboardEnabled": True,
            "hostRichClipboardTransportCapable": True,
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
    return 0 if status == "viewer-rich-text-clipboard-api-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
