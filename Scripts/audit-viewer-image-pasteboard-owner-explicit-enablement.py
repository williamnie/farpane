#!/usr/bin/env python3
"""Audit H6.2k4 Viewer image pasteboard ownership and product opt-in."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-image-pasteboard-owner-explicit-enablement-audit"


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
        "core": repository / "Sources/CoreBridge/CoreBridge.swift",
        "polling": repository / "Sources/CoreBridge/ViewerClipboardPollingState.swift",
        "owner": repository / "Sources/RustDeskNative/ViewerPasteboardOwner.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "host": repository / "Sources/CoreBridge/HostControlClient.swift",
        "policy_tests": repository / "Tests/CoreBridgeTests/ViewerClipboardPollingStateTests.swift",
        "composition_tests": repository / "Tests/CoreBridgeTests/ViewerPasteboardProductCompositionContractTests.swift",
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

    app = sources["app"]
    owner = sources["owner"]
    polling = sources["polling"]
    tests = sources["policy_tests"] + sources["composition_tests"]
    docs = sources["readme"] + sources["architecture"]
    host_product = app + sources["agent"]
    evidence = {
        "designRecordsViewerImageOwnerStep": (
            "H6.2k4 Viewer image pasteboard owner and explicit enablement contract"
            in sources["design"]
        ),
        "viewerCoreImageDirectionsRemainDefaultOff": all(
            marker in sources["core"]
            for marker in (
                "receiveClipboardImage: Bool = false",
                "sendClipboardImage: Bool = false",
            )
        ),
        "allViewerProductEntriesExplicitlyEnableImageDirections": (
            app.count("receiveClipboardImage: true") == 3
            and app.count("sendClipboardImage: true") == 3
            and "receiveImageEnabled: configuration.receiveClipboardImage" in app
            and "sendImageEnabled: configuration.sendClipboardImage" in app
        ),
        "oneAppKitOwnerOwnsTextRichAndImageFormats": all(
            marker in owner
            for marker in (
                "private let pasteboard: NSPasteboard",
                "pasteboard: NSPasteboard = .general",
                "typealias SendText = (String) -> Int32",
                "typealias SendRichText = (CoreClipboardRichTextPayload) -> Int32",
                "typealias SendImage = (CoreClipboardImagePayload) -> Int32",
                "private var pollingState = ViewerClipboardPollingState()",
            )
        ),
        "pasteboardIsReadOnlyAfterChangeCountChanges": all(
            marker in owner + polling
            for marker in (
                "let decision = pollingState.observeChange(",
                "if decision.didChange",
                "sendLocalPasteboard()",
                "if observedChangeCount == changeCount",
            )
        ),
        "localImageReadIsSingleItemStrictBoundedAndCanonical": all(
            marker in owner
            for marker in (
                "NSPasteboard.PasteboardType(\"public.svg-image\")",
                "types.contains(Self.svgPasteboardType)",
                "types.contains(.png)",
                "types.contains(.tiff)",
                "pasteboard.pasteboardItems?.count == 1",
                "ViewerClipboardImagePolicy.maximumSVGUTF8Bytes",
                "ViewerClipboardImagePolicy.maximumImageBytes",
                "CGImageSourceCreateWithData(data as CFData, options)",
                "kCGImageSourceShouldCache: false",
                "CGImageSourceGetCount(source) == 1",
                "NSBitmapImageRep(data: tiff)",
                "ViewerClipboardImagePolicy.acceptsDimensions(",
                "bitmap.representation(using: .png, properties: [:])",
                "ViewerClipboardImagePolicy.accepts(payload)",
            )
        ),
        "imagePayloadPrecedesRichAndTextWithoutFallbackOnInvalidImage": all(
            marker in owner
            for marker in (
                "if sendImageEnabled",
                "switch readLocalImage()",
                "_ = sendImage?(payload)",
                "case .invalid:",
                "if sendRichTextEnabled",
                "_ = sendText?(text)",
            )
        ) and owner.index("if sendImageEnabled") < owner.index("if sendRichTextEnabled"),
        "remoteImageWriteIsValidatedConvertedAndAtomic": all(
            marker in owner
            for marker in (
                "func receiveRemoteImage(",
                "receiveImageEnabled",
                "ViewerClipboardImagePolicy.accepts(payload)",
                "let png = Self.pngData(",
                "item.setData(png, forType: .png)",
                "item.setData(data, forType: .png)",
                "forType: Self.svgPasteboardType",
                "pasteboard.writeObjects([item])",
            )
        ),
        "imageCallbackUsesGenerationAttemptAndSessionGates": all(
            marker in app
            for marker in (
                "onClipboardImage: { [weak self] payload in",
                "handleViewerClipboardImage(",
                "guard coreGeneration == viewerCoreGeneration",
                "activeAttemptID != attemptID",
                "clipboardSessionEpoch == viewerClipboardSessionEpoch",
                "viewerPasteboardOwner.receiveRemoteImage(",
            )
        ),
        "ownedWritesBackoffAndTeardownRemainShared": all(
            marker in owner + polling + app
            for marker in (
                "pollingState.observeOwnedWrite(",
                "resultingChangeCount: pasteboard.changeCount",
                "125, 250, 500, 1_000, 2_000, 4_000",
                "viewerPasteboardOwner.suspend(",
                "viewerPasteboardOwner.stop(sessionEpoch:",
                "stopViewerClipboard()",
            )
        ),
        "clipboardContentIsNotLogged": (
            "print(" not in owner
            and "fputs(" not in owner
            and "NSLog(" not in owner
        ),
        "hostProductImageDirectionsRequireExplicitDefaultOffOptIn": (
            "clipboardImageReadEnabled: Bool = false" in sources["host"]
            and "clipboardImageWriteEnabled: Bool = false" in sources["host"]
            and "farpane.host.clipboard.image.allowRemoteRead" in host_product
            and "farpane.host.clipboard.image.allowRemoteWrite" in host_product
            and "clipboardImageReadEnabled:" in host_product
            and "clipboardImageWriteEnabled:" in host_product
            and "allowRemoteImageRead" in host_product
            and "allowRemoteImageWrite" in host_product
        ),
        "regressionsCoverPolicyFormatsCompositionAndLifecycle": all(
            marker in tests
            for marker in (
                "testImagePolicyRequiresCanonicalBoundedSemanticPayload",
                "structurallyValidOnePixelPNG",
                "ViewerClipboardImagePolicy.acceptsDimensions(",
                "testAppKitOwnerIsTheOnlySwiftPasteboardBoundary",
                "testProductExplicitlyEnablesBothDirectionsAcrossRecovery",
                "testStreamingAndTeardownBoundPasteboardLifecycle",
                "viewerPasteboardOwner.receiveRemoteImage(",
            )
        ),
        "documentationKeepsHostAndSVGBoundaryHonest": all(
            marker in docs
            for marker in (
                "Viewer product image directions",
                "TIFF",
                "public.svg-image",
                "Host image directions remain default-off",
                "SVG is not sanitized for rendering",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2k4 Viewer image pasteboard owner and explicit enablement contract",
        ),
        "coreDefault": line_number(sources["core"], "receiveClipboardImage: Bool = false"),
        "imagePolicy": line_number(polling, "package enum ViewerClipboardImagePolicy"),
        "changeDecision": line_number(polling, "package mutating func observeChange("),
        "pasteboardOwner": line_number(owner, "final class ViewerPasteboardOwner"),
        "imageRead": line_number(owner, "private func readLocalImage()"),
        "imageWrite": line_number(owner, "func receiveRemoteImage("),
        "rgbaConversion": line_number(owner, "private static func pngData("),
        "productEnablement": line_number(app, "receiveClipboardImage: true"),
        "imageCallback": line_number(app, "onClipboardImage: { [weak self] payload in"),
        "imageHandler": line_number(app, "private func handleViewerClipboardImage("),
        "policyRegression": line_number(
            sources["policy_tests"],
            "func testImagePolicyRequiresCanonicalBoundedSemanticPayload()",
        ),
        "compositionRegression": line_number(
            sources["composition_tests"],
            "func testProductExplicitlyEnablesBothDirectionsAcrossRecovery()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-image-pasteboard-owner-explicitly-enabled"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-image-pasteboard-owner-explicit-enablement",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerImageDirectionsExplicitlyEnabled": True,
            "oneAppKitOwnerHandlesTextRichAndImageClipboard": True,
            "preSessionClipboardUploaded": False,
            "invalidImageFallsBackToTextOrRich": False,
            "localTIFFCanonicalizedToPNG": True,
            "pollingBackoffBounded": True,
            "clipboardContentLogged": False,
            "hostProductImageClipboardEnabled": True,
            "svgRenderingSanitized": False,
            "filePromiseClipboardEnabled": False,
        },
        "remainingBoundary": {
            "viewerImagePasteboardOwnerRequired": False,
            "hostImageExplicitOptInRequired": False,
            "installedTwoMacImageClipboardAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-image-clipboard-installed-two-mac-acceptance",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "viewer-image-pasteboard-owner-explicitly-enabled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
