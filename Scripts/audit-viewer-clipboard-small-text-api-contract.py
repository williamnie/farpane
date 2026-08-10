#!/usr/bin/env python3
"""Audit the H6.2g default-off Viewer small-text clipboard API contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-small-text-clipboard-api-contract-audit"


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
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
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
    evidence = {
        "designRecordsBoundedH6Step": all(
            marker in sources["design"]
            for marker in (
                "H6.2g Viewer small-text clipboard API contract",
                "Viewer pasteboard owner and explicit enablement contract",
            )
        ),
        "viewerABIv7RetainsBoundedSmallText": all(
            marker in header
            for marker in (
                "#define RDN_ABI_VERSION 7u",
                "#define RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES (64u * 1024u)",
                "RDNClipboardTextCallback on_clipboard_text;",
                "bool receive_clipboard_text;",
                "bool send_clipboard_text;",
                "rdn_client_send_clipboard_text",
            )
        ),
        "shimRequiresDedicatedSendSymbol": (
            '"rdn_client_send_clipboard_text"' in sources["shim"]
            and "library->client_send_clipboard_text == NULL" in sources["shim"]
            and "library->client_send_clipboard_text(client, utf8" in sources["shim"]
        ),
        "directionsDefaultOffAndRemainIndependent": all(
            marker in swift
            for marker in (
                "receiveClipboardText: Bool = false",
                "sendClipboardText: Bool = false",
                "receive_clipboard_text: config.receiveClipboardText",
                "send_clipboard_text: config.sendClipboardText",
            )
        ),
        "incomingTextIsStrictAndDecompressionBounded": all(
            marker in bridge
            for marker in (
                "pub(crate) fn native_viewer_clipboard_text(clipboards: &[Clipboard])",
                "[clipboard] => clipboard",
                "ClipboardFormat::Text",
                "decompress_with_limit(",
                "MAX_CLIPBOARD_TEXT_UTF8_BYTES",
                "!text.contains('\\0')",
            )
        ),
        "outgoingTextIsCanonicalAndBounded": all(
            marker in bridge
            for marker in (
                "fn native_viewer_clipboard_message(bytes: &[u8])",
                "message.set_clipboard(Clipboard {",
                "format: ClipboardFormat::Text.into()",
                "rdn_client_send_clipboard_text",
            )
        ),
        "receiveAndSendAreLifecyclePermissionGated": all(
            marker in bridge
            for marker in (
                "fn clipboard_receive_allowed(",
                "active && authenticated && local_receive_enabled && remote_clipboard_enabled",
                "if !client.shared.send_clipboard_text.load(Ordering::Acquire)",
                "return -7;",
                "remote_clipboard_enabled",
                "return -8;",
            )
        ),
        "nativeViewerNeverOwnsSystemPasteboard": all(
            marker in io_loop
            for marker in (
                'not(feature = "rdn-native-core")',
                "let rx: Option<tokio::sync::mpsc::UnboundedReceiver<()>> = None;",
                "let clipboards = [cb]",
                "native_viewer_clipboard_text(&clipboards)",
                "self.handler.native_clipboard_text(text);",
            )
        ),
        "wireNegotiationIsExplicitlyAdapted": (
            "configure_native_viewer(&mut self, peer_id: &str, clipboard_enabled: bool)"
            in sources["client"]
            and "self.config.disable_clipboard.v = !clipboard_enabled;"
            in sources["client"]
        ),
        "callbackSurfaceIsNativeOnly": (
            '#[cfg(feature = "rdn-native-core")]\n    fn native_clipboard_text'
            in sources["ui_session"]
        ),
        "swiftCopiesAndValidatesCallbackBytes": all(
            marker in swift
            for marker in (
                "let data = Data(bytes: utf8, count: length)",
                "let text = String(data: data, encoding: .utf8)",
                '!text.contains("\\0")',
                "box.deliverClipboardText(text)",
            )
        ),
        "swiftDropsQueuedClipboardAfterDisconnect": all(
            marker in swift
            for marker in (
                "private var clipboardDeliveryEnabled = true",
                "guard clipboardLifecycleLock.withLock({ clipboardDeliveryEnabled })",
                "callbackBox.stopClipboardDelivery()",
            )
        ),
        "regressionsCoverDefaultsDirectionsPayloadAndLifecycle": all(
            marker in (bridge + sources["swift_tests"])
            for marker in (
                "gates_viewer_clipboard_receive_on_lifecycle_and_both_policies",
                "native_viewer_clipboard_accepts_only_one_bounded_utf8_text_entry",
                "native_viewer_clipboard_bounds_decompression_and_builds_canonical_message",
                "testViewerClipboardDirectionsAreExplicitAndIndependent",
                "testViewerClipboardDeliveryStopsBeforeCoreDisconnect",
            )
        ),
        "buildsRequireNewABISymbol": all(
            "_rdn_client_send_clipboard_text" in sources[name]
            for name in ("build_core", "build_universal")
        ),
        "trackedPatchCarriesViewerRuntimeChanges": all(
            marker in sources["patch"]
            for marker in (
                "diff --git a/src/client.rs b/src/client.rs",
                "diff --git a/src/client/io_loop.rs b/src/client/io_loop.rs",
                "diff --git a/src/ui_session_interface.rs b/src/ui_session_interface.rs",
            )
        ),
        "documentationRecordsViewerEnablementAndHostBoundary": all(
            marker in (sources["readme"] + sources["architecture"])
            for marker in (
                "ABI v7 retains the ABI v6",
                "AppKit-owned pasteboard adapter",
                "Host Control ABI v13",
                "bootstrap schema v2",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.2g Viewer small-text clipboard API contract"
        ),
        "abiVersion": line_number(header, "#define RDN_ABI_VERSION 7u"),
        "sizeLimit": line_number(header, "RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES"),
        "clipboardCallback": line_number(header, "RDNClipboardTextCallback on_clipboard_text;"),
        "sendAPI": line_number(header, "rdn_client_send_clipboard_text"),
        "shimSymbol": line_number(sources["shim"], 'dlsym(\n        handle, "rdn_client_send_clipboard_text")'),
        "receiveGate": line_number(bridge, "fn clipboard_receive_allowed("),
        "strictIncoming": line_number(bridge, "pub(crate) fn native_viewer_clipboard_text("),
        "canonicalOutgoing": line_number(bridge, "fn native_viewer_clipboard_message("),
        "sendGate": line_number(bridge, "pub unsafe extern \"C\" fn rdn_client_send_clipboard_text("),
        "noPolling": line_number(io_loop, "let rx: Option<tokio::sync::mpsc::UnboundedReceiver<()>> = None;"),
        "incomingCallback": line_number(io_loop, "self.handler.native_clipboard_text(text);"),
        "swiftDefaults": line_number(swift, "receiveClipboardText: Bool = false"),
        "swiftLifecycleGate": line_number(swift, "func stopClipboardDelivery()"),
        "swiftSend": line_number(swift, "public func sendClipboardText(_ text: String)"),
        "coreBuildSymbol": line_number(sources["build_core"], "_rdn_client_send_clipboard_text"),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-small-text-clipboard-api-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-small-text-clipboard-api",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerABIv7RetainsSmallText": True,
            "directionsIndependentlyEnforced": True,
            "smallTextBoundedTo64KiB": True,
            "viewerRustOwnsSystemPasteboard": False,
            "viewerProductClipboardEnabled": True,
            "hostProductClipboardEnabledByDefault": False,
            "hostProductExplicitOptInCapable": True,
            "endToEndSmallTextExplicitOptInCapable": True,
            "richClipboardEnabled": False,
        },
        "remainingBoundary": {
            "viewerPasteboardOwnerRequired": False,
            "viewerExplicitEnablementRequired": False,
            "hostSmallTextExplicitOptInRequired": False,
            "richPayloadTransferRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-small-text-clipboard-installed-two-mac-acceptance",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "viewer-small-text-clipboard-api-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
