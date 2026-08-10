#!/usr/bin/env python3
"""Audit H6.2j5 Viewer rich-text AppKit owner and product enablement."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-rich-text-pasteboard-owner-explicit-enablement-audit"


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
        "polling_tests": repository / "Tests/CoreBridgeTests/ViewerClipboardPollingStateTests.swift",
        "composition_tests": repository / "Tests/CoreBridgeTests/ViewerPasteboardProductCompositionContractTests.swift",
        "host_swift": repository / "Sources/CoreBridge/HostControlClient.swift",
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
    tests = sources["polling_tests"] + sources["composition_tests"]
    docs = sources["readme"] + sources["architecture"]
    host_product = app + sources["agent"]
    evidence = {
        "designRecordsBoundedProductStep": (
            "H6.2j5 Viewer rich-text pasteboard owner and explicit enablement contract"
            in sources["design"]
        ),
        "viewerCoreRichDirectionsRemainDefaultOff": all(
            marker in sources["core"]
            for marker in (
                "receiveClipboardRichText: Bool = false",
                "sendClipboardRichText: Bool = false",
            )
        ),
        "allViewerProductEntriesExplicitlyEnableRichDirections": (
            app.count("receiveClipboardRichText: true") == 3
            and app.count("sendClipboardRichText: true") == 3
            and "receiveRichTextEnabled: configuration.receiveClipboardRichText" in app
            and "sendRichTextEnabled: configuration.sendClipboardRichText" in app
        ),
        "oneAppKitOwnerOwnsSmallAndRichFormats": all(
            marker in owner
            for marker in (
                "private let pasteboard: NSPasteboard",
                "pasteboard: NSPasteboard = .general",
                "typealias SendText = (String) -> Int32",
                "typealias SendRichText = (CoreClipboardRichTextPayload) -> Int32",
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
        "localRichReadIsSingleItemStrictAndBounded": all(
            marker in owner + polling
            for marker in (
                "pasteboard.pasteboardItems?.count == 1",
                "types.contains(.rtf)",
                "types.contains(.html)",
                "ViewerClipboardTextPolicy.maximumUTF8Bytes",
                "ViewerClipboardRichTextPolicy.maximumRichTextUTF8Bytes",
                "data.count <= maximumBytes",
                "String(data: data, encoding: .utf8)",
                "ViewerClipboardRichTextPolicy.accepts(payload)",
            )
        ),
        "richPayloadIsPreferredWithoutDuplicatePlainSend": all(
            marker in owner
            for marker in (
                "switch readLocalRichText()",
                "case let .payload(payload):",
                "_ = sendRichText?(payload)",
                "case .invalid:",
                "case .absent:",
                "_ = sendText?(text)",
            )
        ),
        "remoteRichWriteIsValidatedAndAtomic": all(
            marker in owner
            for marker in (
                "func receiveRemoteRichText(",
                "receiveRichTextEnabled",
                "let item = NSPasteboardItem()",
                "item.setData(Data(rtf.utf8), forType: .rtf)",
                "item.setData(Data(html.utf8), forType: .html)",
                "pasteboard.writeObjects([item])",
            )
        ),
        "richCallbackUsesExistingGenerationAttemptAndSessionGates": all(
            marker in app
            for marker in (
                "onClipboardRichText: { [weak self] payload in",
                "handleViewerClipboardRichText(",
                "guard coreGeneration == viewerCoreGeneration",
                "activeAttemptID != attemptID",
                "clipboardSessionEpoch == viewerClipboardSessionEpoch",
                "viewerPasteboardOwner.receiveRemoteRichText(",
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
        "hostProductRichDirectionsRemainOff": (
            "clipboardRichTextReadEnabled:" not in host_product
            and "clipboardRichTextWriteEnabled:" not in host_product
            and "clipboardRichTextReadEnabled: Bool = false" in sources["host_swift"]
            and "clipboardRichTextWriteEnabled: Bool = false" in sources["host_swift"]
        ),
        "regressionsCoverPolicyBackoffCompositionAndLifecycle": all(
            marker in tests
            for marker in (
                "testRichTextPolicyRequiresBoundedAtomicRichRepresentation",
                "testChangeDecisionDoesNotRequirePasteboardReadAndRetainsBackoff",
                "testAppKitOwnerIsTheOnlySwiftPasteboardBoundary",
                "testProductExplicitlyEnablesBothDirectionsAcrossRecovery",
                "testStreamingAndTeardownBoundPasteboardLifecycle",
                "receiveRemoteRichText(",
            )
        ),
        "documentationRecordsViewerEnabledHostDefaultOffBoundary": all(
            marker in docs
            for marker in (
                "Viewer product configuration",
                "single AppKit owner",
                "Host product configuration still does not enable",
                "NSPasteboardItem",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2j5 Viewer rich-text pasteboard owner and explicit enablement contract",
        ),
        "coreDefault": line_number(sources["core"], "receiveClipboardRichText: Bool = false"),
        "richPolicy": line_number(polling, "package enum ViewerClipboardRichTextPolicy"),
        "changeDecision": line_number(polling, "package mutating func observeChange("),
        "pasteboardOwner": line_number(owner, "final class ViewerPasteboardOwner"),
        "richRead": line_number(owner, "private func readLocalRichText()"),
        "richWrite": line_number(owner, "func receiveRemoteRichText("),
        "atomicCommit": line_number(owner, "pasteboard.writeObjects([item])"),
        "productEnablement": line_number(app, "receiveClipboardRichText: true"),
        "richCallback": line_number(app, "onClipboardRichText: { [weak self] payload in"),
        "richHandler": line_number(app, "private func handleViewerClipboardRichText("),
        "policyRegression": line_number(
            sources["polling_tests"],
            "func testRichTextPolicyRequiresBoundedAtomicRichRepresentation()",
        ),
        "compositionRegression": line_number(
            sources["composition_tests"],
            "func testProductExplicitlyEnablesBothDirectionsAcrossRecovery()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-rich-text-pasteboard-owner-explicitly-enabled"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-rich-text-pasteboard-owner-explicit-enablement",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerRichDirectionsExplicitlyEnabled": True,
            "oneAppKitOwnerHandlesSmallAndRichClipboard": True,
            "preSessionClipboardUploaded": False,
            "richBundlePreferredWithoutDuplicatePlainSend": True,
            "pollingBackoffBounded": True,
            "clipboardContentLogged": False,
            "hostProductRichClipboardEnabled": False,
            "imageOrFileClipboardEnabled": False,
        },
        "remainingBoundary": {
            "viewerRichPasteboardOwnerRequired": False,
            "hostRichProductOptInRequired": True,
            "installedTwoMacRichClipboardAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-rich-text-bootstrap-home-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "viewer-rich-text-pasteboard-owner-explicitly-enabled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
