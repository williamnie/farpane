#!/usr/bin/env python3
"""Audit the H6.2k1 bounded Host image clipboard envelope contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-bounded-image-envelope-audit"


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
        "designFreezesBoundedImageBoundary": all(
            marker in design
            for marker in (
                "H6.2k1 Host bounded image clipboard envelope contract",
                "RGBA、PNG 与 SVG",
                "本步不新增 Viewer/Host ABI",
            )
        ),
        "wireAndDecodedCapsAreExplicit": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_IMAGE_WIRE_BYTES: usize = 128 * 1024 * 1024",
                "MAX_CLIPBOARD_IMAGE_DECODED_BYTES: usize = 128 * 1024 * 1024",
                "MAX_CLIPBOARD_SVG_WIRE_BYTES: usize = 4 * 1024 * 1024",
                "MAX_CLIPBOARD_SVG_UTF8_BYTES: usize = 4 * 1024 * 1024",
                "decompress_with_limit(&clipboard.content, decoded_limit)",
            )
        ),
        "dimensionsAndPixelsAreBounded": all(
            marker in bridge
            for marker in (
                "MAX_CLIPBOARD_IMAGE_DIMENSION: i32 = 8192",
                "MAX_CLIPBOARD_IMAGE_PIXELS: usize = 7680 * 4320",
                "fn native_image_pixel_count(width: i32, height: i32)",
                "checked_mul(usize::try_from(height).ok()?)",
                "pixels <= MAX_CLIPBOARD_IMAGE_PIXELS",
            )
        ),
        "ownedEnvelopeCoversThreeExactFormats": all(
            marker in bridge
            for marker in (
                "enum NativeImageFormat",
                "Rgba { width: i32, height: i32 }",
                "Png { width: i32, height: i32 }",
                "Svg,",
                "struct NativeImageTransferEnvelope",
                "payload: Vec<u8>",
            )
        ),
        "rgbaRequiresExactDecodedByteCount": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::ImageRgba =>",
                "let expected_bytes = pixel_count.checked_mul(4)?",
                "if payload.len() != expected_bytes",
                "MAX_CLIPBOARD_IMAGE_DECODED_BYTES",
            )
        ),
        "pngRequiresCanonicalBoundedStructure": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::ImagePng =>",
                "a second zstd layer is non-canonical",
                "fn native_png_dimensions(payload: &[u8])",
                "const SIGNATURE: &[u8; 8] = b\"\\x89PNG\\r\\n\\x1a\\n\"",
                'b"IHDR" if offset == 8 && length == 13',
                'b"IDAT" if dimensions.is_some()',
                'b"IEND" if length == 0',
            )
        ),
        "svgRequiresBoundedUtf8CanonicalRoot": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::ImageSvg =>",
                "std::str::from_utf8(&payload).ok()?",
                "svg.contains('\\0')",
                "fn native_svg_has_canonical_root(svg: &str)",
                'window.eq_ignore_ascii_case(b"<!doctype")',
                'remainder.strip_prefix("<svg")',
            )
        ),
        "classifierRequiresValidatedImageEnvelope": all(
            marker in bridge
            for marker in (
                "ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg",
                "NativeImageTransferEnvelope::from_clipboard(clipboard)",
                ".map_or(NativeClipboardPayloadDisposition::Reject, |_|",
                "NativeClipboardPayloadDisposition::IndependentTransferRequired",
            )
        ),
        "adversarialOwnershipRegressionExists": all(
            marker in bridge
            for marker in (
                "native_image_transfer_envelope_is_owned_bounded_and_format_strict",
                "rgba.content.clear()",
                "wrong_rgba_length",
                "excessive_rgba",
                "compressed_png",
                "MAX_CLIPBOARD_SVG_UTF8_BYTES + 1",
                'b"before\\0after"',
                'b"<!DOCTYPE svg><svg></svg>"',
                "EnumOrUnknown::from_i32(999)",
            )
        ),
        "documentationKeepsTransportAndRenderingClosed": (
            "128 MiB" in architecture
            and "SVG is not sanitized" in readme
            and "Viewer ABI v8 now exposes" in readme
            and "Host/Viewer image admission" in readme
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.2k1 Host bounded image clipboard envelope contract"
        ),
        "wireCap": line_number(bridge, "MAX_CLIPBOARD_IMAGE_WIRE_BYTES"),
        "decodedCap": line_number(bridge, "MAX_CLIPBOARD_IMAGE_DECODED_BYTES"),
        "svgCap": line_number(bridge, "MAX_CLIPBOARD_SVG_UTF8_BYTES"),
        "formatEnum": line_number(bridge, "enum NativeImageFormat"),
        "ownedEnvelope": line_number(bridge, "struct NativeImageTransferEnvelope"),
        "rgbaValidation": line_number(bridge, "let expected_bytes = pixel_count.checked_mul(4)?"),
        "pngValidation": line_number(bridge, "fn native_png_dimensions(payload: &[u8])"),
        "svgValidation": line_number(bridge, "fn native_svg_has_canonical_root(svg: &str)"),
        "imageClassifier": line_number(
            bridge, "NativeImageTransferEnvelope::from_clipboard(clipboard)"
        ),
        "regression": line_number(
            bridge, "native_image_transfer_envelope_is_owned_bounded_and_format_strict"
        ),
        "architectureBoundary": line_number(
            architecture, "RGBA/PNG/SVG 进入 Rust-owned image envelope"
        ),
        "readmeBoundary": line_number(
            readme, "RGBA, PNG, and SVG now require a Rust-owned image envelope"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "bounded-image-envelope-contract"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-bounded-image-transfer-envelope",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "imageEnvelopeBounded": True,
            "imageEnvelopeOwned": True,
            "imageNetworkTransportEnabled": False,
            "imagePasteboardEnabled": False,
            "imageProductEnabled": False,
            "svgSanitizedForRendering": False,
        },
        "remainingBoundary": {
            "viewerImageABIRequired": False,
            "hostViewerImageTransportRequired": True,
            "pasteboardOwnerRequired": True,
            "explicitProductOptInRequired": True,
            "installedTwoMacAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-viewer-image-transfer-wiring-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "bounded-image-envelope-contract" else 1


if __name__ == "__main__":
    raise SystemExit(main())
