#!/usr/bin/env python3
"""Audit the H6.2j1 Host rich clipboard transfer-boundary taxonomy."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-rich-transfer-boundary-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "clipboard": repository / "Vendor/rustdesk/src/clipboard.rs",
        "proto": repository / "Vendor/rustdesk/libs/hbb_common/protos/message.proto",
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
    bridge = sources["bridge"]
    clipboard = sources["clipboard"]
    proto = sources["proto"]
    evidence = {
        "designRequiresIndependentBoundedRichTransfer": all(
            marker in design
            for marker in (
                "大对象、图片和文件使用大小上限与独立 transfer channel",
                "任何来自远端的文件名、UTI 和 payload 均视为不可信输入",
                "H6.2j1 Host rich clipboard transfer-boundary taxonomy",
            )
        ),
        "wireFormatsAreEnumeratedNotInferred": all(
            marker in proto
            for marker in (
                "Rtf = 1;",
                "Html = 2;",
                "ImageRgba = 21;",
                "ImagePng = 22;",
                "ImageSvg = 23;",
                "Special = 31;",
            )
        ),
        "hostHasThreeWayPayloadDisposition": all(
            marker in bridge
            for marker in (
                "enum NativeClipboardPayloadDisposition",
                "InlineSmallText",
                "IndependentTransferRequired",
                "Reject",
            )
        ),
        "onlyBoundedTextCanEnterInlinePath": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024",
                "ClipboardFormat::Text =>",
                "decompress_with_limit(",
                "!text.contains('\\0')",
                "NativeClipboardPayloadDisposition::InlineSmallText",
            )
        ),
        "standardRichTypesRequireIndependentTransfer": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::Rtf | ClipboardFormat::Html",
                "ClipboardFormat::ImageRgba =>",
                "ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg",
                "NativeClipboardPayloadDisposition::IndependentTransferRequired",
            )
        ),
        "remoteSpecialAndUnknownFormatsReject": (
            "ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject"
            in bridge
            and "let Ok(format) = clipboard.format.enum_value() else" in bridge
            and "EnumOrUnknown::from_i32(999)" in bridge
        ),
        "richDispositionRequiresSeparatePolicyAndCanonicalTransfer": all(
            marker in bridge
            for marker in (
                "NativeClipboardTransferPolicy",
                "transfer_policy.rich_text()",
                "NativeRichTextTransferBundle::from_clipboards(clipboards)?",
                "into_canonical_clipboards()",
            )
        ),
        "taxonomyAndNULRegressionAreCovered": all(
            marker in bridge
            for marker in (
                "native_clipboard_payload_taxonomy_separates_inline_text_from_rich_transfer",
                'b"before\\0after"',
                "NativeClipboardPayloadDisposition::Reject",
            )
        ),
        "upstreamRichConversionRemainsOutsideAdmission": all(
            marker in clipboard
            for marker in (
                "ClipboardData::Rtf(s) =>",
                "ClipboardData::Html(s) =>",
                "ClipboardData::Image(a) => image_to_proto(a)",
                "ClipboardData::Special((s, d)) => special_to_proto(d, s)",
                "decompress(&clipboard.content)",
            )
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designRequirement": line_number(
            design,
            "大对象、图片和文件使用大小上限与独立 transfer channel",
        ),
        "designMilestone": line_number(
            design, "H6.2j1 Host rich clipboard transfer-boundary taxonomy"
        ),
        "wireFormats": line_number(proto, "enum ClipboardFormat"),
        "payloadDisposition": line_number(
            bridge, "enum NativeClipboardPayloadDisposition"
        ),
        "payloadClassifier": line_number(
            bridge, "fn native_host_clipboard_payload_disposition("
        ),
        "inlineAdmission": line_number(
            bridge, "NativeClipboardPayloadDisposition::InlineSmallText"
        ),
        "richTextRouting": line_number(
            bridge, "ClipboardFormat::Rtf | ClipboardFormat::Html"
        ),
        "imageRouting": line_number(bridge, "ClipboardFormat::ImageRgba =>"),
        "specialRejection": line_number(
            bridge,
            "ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject",
        ),
        "taxonomyTest": line_number(
            bridge,
            "native_clipboard_payload_taxonomy_separates_inline_text_from_rich_transfer",
        ),
        "nulRegression": line_number(bridge, 'b"before\\0after"'),
        "upstreamRichConversion": line_number(
            clipboard, "fn clipboard_data_to_proto(data: ClipboardData)"
        ),
        "upstreamUnboundedDecode": line_number(
            clipboard, "decompress(&clipboard.content)"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "rich-payload-independent-transfer-boundary"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-rich-clipboard-transfer-boundary-taxonomy",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "inlineSmallTextRemainsBounded": True,
            "embeddedNULAccepted": False,
            "richTypesClassified": True,
            "richTypesAdmittedToInlinePath": False,
            "specialUTIOrFormatAccepted": False,
            "independentRichTransferImplemented": True,
        },
        "remainingBoundary": {
            "boundedRichTransferEnvelopeRequired": False,
            "richViewerABIRequired": False,
            "richPasteboardOwnerRequired": True,
            "installedTwoMacAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-rich-text-bootstrap-home-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "rich-payload-independent-transfer-boundary" else 1


if __name__ == "__main__":
    raise SystemExit(main())
