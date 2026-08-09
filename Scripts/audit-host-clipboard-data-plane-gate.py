#!/usr/bin/env python3
"""Audit the H6.2 bounded small-text directional clipboard data gates."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-data-plane-gate-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_host_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "compress": repository / "Vendor/rustdesk/libs/hbb_common/src/compress.rs",
        "upstream_patch": repository
        / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "hbb_patch": repository
        / "CoreBridge/RustDeskPatch/hbb-common-7e1c392.patch",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(
            json.dumps(
                {
                    "schema": SCHEMA,
                    "schemaVersion": 1,
                    "status": "audit-failed",
                    "error": str(error),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1

    design = sources["design"]
    bridge = sources["host_bridge"]
    connection = sources["connection"]
    compress = sources["compress"]
    patches = sources["upstream_patch"] + sources["hbb_patch"]
    evidence = {
        "designRequiresDirectionalBoundedText": all(
            marker in design
            for marker in (
                "read/write 分权",
                "默认支持小型文本",
                "大小上限与独立 transfer channel",
            )
        ),
        "runtimePolicyDefaultsClosed": all(
            marker in bridge
            for marker in (
                "OPTION_ENABLE_CLIPBOARD",
                '(config::keys::OPTION_ENABLE_CLIPBOARD, "N")',
                "broker.clipboard_policy = NativeClipboardPolicy::default()",
            )
        ),
        "readDirectionGatesSubscriptionAndSend": all(
            marker in connection + bridge
            for marker in (
                "active_policy().allows_remote_read()",
                "native_host_outgoing_clipboard_message_is_allowed(",
                "NativeClipboardDirection::RemoteRead",
            )
        ),
        "writeDirectionGatesBeforePasteboardUpdate": all(
            marker in connection + bridge
            for marker in (
                "native_host_allows_remote_clipboard_write(",
                "&& native_host_allows",
                "NativeClipboardDirection::RemoteWrite",
                "update_clipboard(vec![cb], ClipboardSide::Host)",
            )
        ),
        "singleSmallUtf8TextOnly": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024",
                "clipboard.format.enum_value() != Ok(ClipboardFormat::Text)",
                "!clipboard.special_name.is_empty()",
                "clipboards.len() == 1",
                "String::from_utf8(bytes).ok()",
            )
        ),
        "compressedPayloadHasDecodedHardLimit": all(
            marker in bridge + compress
            for marker in (
                "decompress_with_limit(",
                "zstd::bulk::decompress(data, max_output_bytes)",
                "compressed_over_limit",
            )
        ),
        "richAndOversizedFixturesAreRejected": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1",
                "ClipboardFormat::Html",
                "native_clipboard_data_plane_accepts_only_bounded_utf8_plain_text",
            )
        ),
        "directionalFixturesCoverAsymmetry": all(
            marker in bridge
            for marker in (
                "native_clipboard_data_plane_gates_read_and_write_independently",
                "let read_only = NativeClipboardPolicy::new(true, false)",
                "let write_only = NativeClipboardPolicy::new(false, true)",
            )
        ),
        "trackedPatchCarriesBothDataGates": all(
            marker in patches
            for marker in (
                "native_host_outgoing_clipboard_message_is_allowed",
                "native_host_allows_remote_clipboard_write",
                "decompress_with_limit",
            )
        ),
        "canonicalAndVendoredBridgeMatch": (
            bridge == sources["vendor_host_bridge"]
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    source_lines = {
        "designClipboard": line_number(design, "### 12.2 剪贴板"),
        "smallTextLimit": line_number(bridge, "MAX_CLIPBOARD_TEXT_UTF8_BYTES"),
        "payloadValidator": line_number(bridge, "fn native_host_small_text_clipboard("),
        "directionGate": line_number(
            bridge, "fn native_host_clipboard_direction_allows("
        ),
        "outgoingGate": line_number(
            connection, "native_host_outgoing_clipboard_message_is_allowed("
        ),
        "incomingGate": line_number(
            connection, "native_host_allows_remote_clipboard_write("
        ),
        "boundedDecompress": line_number(compress, "pub fn decompress_with_limit("),
        "directionTest": line_number(
            bridge, "native_clipboard_data_plane_gates_read_and_write_independently"
        ),
        "payloadTest": line_number(
            bridge,
            "native_clipboard_data_plane_accepts_only_bounded_utf8_plain_text",
        ),
    }
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "bounded-small-text-directional-gates"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-bounded-small-text-directional-data-gates",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "readWriteDataGatesIndependent": True,
            "smallUtf8TextBounded": True,
            "clipboardDataPathEnabled": False,
            "richClipboardImplemented": False,
        },
        "remainingBoundary": {
            "independentRevocationCommandsRequired": False,
            "directionalXPCUIRequired": False,
            "eventDrivenDynamicBackoffRequired": False,
            "temporaryObjectCleanupRequired": True,
            "explicitProductEnablementRequired": True,
        },
        "nextImplementationBoundary": "temporary-clipboard-object-cleanup-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "bounded-small-text-directional-gates" else 1


if __name__ == "__main__":
    raise SystemExit(main())
