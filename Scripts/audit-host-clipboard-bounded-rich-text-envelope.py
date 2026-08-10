#!/usr/bin/env python3
"""Audit the H6.2j2 bounded Host rich-text transfer-envelope contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-bounded-rich-text-envelope-audit"


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
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
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

    design = sources["design"]
    architecture = sources["architecture"]
    readme = sources["readme"]
    bridge = sources["bridge"]
    evidence = {
        "designFreezesBoundedRichTextBoundary": all(
            marker in design
            for marker in (
                "H6.2j2 Host bounded rich-text transfer envelope contract",
                "wire 与解码后 UTF-8 payload 都以 1 MiB 为独立硬上限",
                "本步不新增 Viewer/Host ABI",
            )
        ),
        "wireAndDecodedCapsAreIndependent": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES: usize = 1024 * 1024",
                "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024",
                "clipboard.content.len() > MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES",
                "decoded.len() > MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES",
            )
        ),
        "envelopeOwnsSemanticPayload": all(
            marker in bridge
            for marker in (
                "struct NativeRichTextTransferEnvelope",
                "payload: String",
                "let payload = String::from_utf8(decoded).ok()?",
                "Some(Self { format, payload })",
            )
        ),
        "onlyRtfAndHtmlCanFormEnvelope": all(
            marker in bridge
            for marker in (
                "enum NativeRichTextFormat",
                "ClipboardFormat::Rtf => NativeRichTextFormat::Rtf",
                "ClipboardFormat::Html => NativeRichTextFormat::Html",
                "_ => return None",
            )
        ),
        "metadataShapeIsStrict": all(
            marker in bridge
            for marker in (
                "!clipboard.special_name.is_empty()",
                "clipboard.width != 0",
                "clipboard.height != 0",
                "clipboard.content.is_empty()",
            )
        ),
        "compressedInputUsesBoundedDecode": all(
            marker in bridge
            for marker in (
                "if clipboard.compress",
                "hbb_common::compress::decompress_with_limit(",
                "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES",
            )
        ),
        "decodedTextRejectsEmptyInvalidUtf8AndNul": all(
            marker in bridge
            for marker in (
                "if decoded.is_empty()",
                "String::from_utf8(decoded).ok()?",
                "if payload.contains('\\0')",
            )
        ),
        "classifierRequiresValidatedEnvelope": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::Rtf | ClipboardFormat::Html =>",
                "NativeRichTextTransferEnvelope::from_clipboard(clipboard)",
                ".map_or(NativeClipboardPayloadDisposition::Reject, |_|",
                "NativeClipboardPayloadDisposition::IndependentTransferRequired",
            )
        ),
        "boundedEnvelopeFeedsCanonicalRichDataPlane": all(
            marker in bridge
            for marker in (
                "struct NativeRichTextTransferBundle",
                "NativeRichTextTransferBundle::from_clipboards(clipboards)?",
                "into_canonical_clipboards()",
                "native_host_prepare_outgoing_clipboard_message(",
                "native_host_prepare_incoming_clipboard_entries(",
            )
        ),
        "ownershipAndAdversarialCasesAreCovered": all(
            marker in bridge
            for marker in (
                "native_rich_text_transfer_envelope_is_owned_bounded_and_strict",
                "source.content.clear()",
                "compressed_over_limit",
                "MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES + 1",
                "vec![0xff]",
                'b"before\\0after"',
                'wrong_metadata.special_name = "public.html".to_owned()',
                "for (width, height) in [(1, 0), (0, 1)]",
                "unknown_format.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999)",
                "ClipboardFormat::Text",
            )
        ),
        "documentationRecordsViewerOwnerAndHostProductBoundary": (
            "1 MiB" in architecture
            and "Host ABI v14" in architecture
            and "1 MiB" in readme
            and "Viewer product configuration" in readme
            and "Host product configuration still does not enable" in readme
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.2j2 Host bounded rich-text transfer envelope contract"
        ),
        "wireCap": line_number(bridge, "MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES"),
        "decodedCap": line_number(bridge, "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES"),
        "formatEnum": line_number(bridge, "enum NativeRichTextFormat"),
        "ownedEnvelope": line_number(bridge, "struct NativeRichTextTransferEnvelope"),
        "envelopeDecoder": line_number(
            bridge, "fn from_clipboard(clipboard: &Clipboard) -> Option<Self>"
        ),
        "boundedDecompression": line_number(
            bridge, "hbb_common::compress::decompress_with_limit("
        ),
        "nulRejection": line_number(bridge, "if payload.contains('\\0')"),
        "richClassifier": line_number(
            bridge, "NativeRichTextTransferEnvelope::from_clipboard(clipboard)"
        ),
        "inlineAdmission": line_number(
            bridge, "NativeClipboardPayloadDisposition::InlineSmallText"
        ),
        "regression": line_number(
            bridge, "native_rich_text_transfer_envelope_is_owned_bounded_and_strict"
        ),
        "architectureBoundary": line_number(
            architecture, "RTF/HTML 先进入 Rust-owned semantic envelope"
        ),
        "readmeBoundary": line_number(
            readme, "RTF/HTML now have a Rust-owned semantic envelope"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "bounded-rich-text-envelope-contract"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-bounded-rich-text-transfer-envelope",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "richTextEnvelopeBounded": True,
            "richTextEnvelopeOwned": True,
            "richTextInlineAdmitted": False,
            "richTextNetworkTransportEnabled": True,
            "richTextPasteboardEnabled": True,
            "imagesIncluded": False,
        },
        "remainingBoundary": {
            "viewerRichTextABIRequired": False,
            "hostViewerTransportWiringRequired": False,
            "pasteboardOwnerRequired": False,
            "imagesRequired": True,
            "installedTwoMacAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-rich-text-bootstrap-home-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "bounded-rich-text-envelope-contract" else 1


if __name__ == "__main__":
    raise SystemExit(main())
