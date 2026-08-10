#!/usr/bin/env python3
"""Audit the H6.2h Viewer pasteboard owner and product enablement boundary."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-viewer-pasteboard-owner-explicit-enablement-audit"


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
        "polling_tests": repository / "Tests/CoreBridgeTests/ViewerClipboardPollingStateTests.swift",
        "composition_tests": repository / "Tests/CoreBridgeTests/ViewerPasteboardProductCompositionContractTests.swift",
        "host": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
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

    polling = sources["polling"]
    owner = sources["owner"]
    app = sources["app"]
    tests = sources["polling_tests"] + sources["composition_tests"]
    evidence = {
        "designRecordsBoundedViewerStep": all(
            marker in sources["design"]
            for marker in (
                "H6.2h Viewer pasteboard owner and explicit enablement contract",
                "Host small-text clipboard explicit opt-in contract",
            )
        ),
        "coreDirectionsRemainDefaultOff": all(
            marker in sources["core"]
            for marker in (
                "receiveClipboardText: Bool = false",
                "sendClipboardText: Bool = false",
            )
        ),
        "allViewerProductEntriesExplicitlyEnableBothDirections": (
            app.count("receiveClipboardText: true") == 3
            and app.count("sendClipboardText: true") == 3
            and "receiveEnabled: configuration.receiveClipboardText" in app
            and "sendEnabled: configuration.sendClipboardText" in app
        ),
        "appKitIsTheSingleSwiftPasteboardOwner": all(
            marker in owner
            for marker in (
                "private let pasteboard: NSPasteboard",
                "pasteboard: NSPasteboard = .general",
                "Thread.isMainThread",
                "ViewerClipboardTextPolicy.accepts(text)",
            )
        ),
        "initialClipboardIsSnapshottedNotSent": (
            "currentChangeCount: pasteboard.changeCount" in owner
            and "observedChangeCount = currentChangeCount" in polling
            and "testInitialClipboardIsNotSent" in tests
        ),
        "fallbackPollingBacksOffAndResets": all(
            marker in polling
            for marker in (
                "125, 250, 500, 1_000, 2_000, 4_000",
                "delayIndex + 1",
                "delayIndex = 0",
                "text: @autoclosure () -> String?",
            )
        ),
        "ownedRemoteWritesCannotImmediatelyLoop": (
            "observeOwnedWrite(" in polling
            and "resultingChangeCount: pasteboard.changeCount" in owner
            and "testInitialClipboardIsNotSentAndOwnedRemoteWriteIsSuppressed" in tests
        ),
        "payloadRemainsBoundedTextOnly": all(
            marker in polling
            for marker in (
                "maximumUTF8Bytes = 64 * 1024",
                "!text.isEmpty",
                "!text.contains(\"\\0\")",
                "text.utf8.count <= maximumUTF8Bytes",
            )
        ),
        "callbacksAreGenerationAndSessionBound": all(
            marker in app
            for marker in (
                "onClipboardText: { [weak self] text in",
                "coreGeneration == viewerCoreGeneration",
                "clipboardSessionEpoch == viewerClipboardSessionEpoch",
            )
        ),
        "authenticationRecoveryAndTeardownOwnLifecycle": all(
            marker in app
            for marker in (
                "event.state == .authenticated || event.state == .streaming",
                "viewerPasteboardOwner.activate(",
                "viewerPasteboardOwner.suspend(",
                "stopViewerClipboard()",
            )
        ),
        "clipboardContentIsNotLogged": (
            "print(" not in owner
            and "fputs(" not in owner
            and "NSLog(" not in owner
        ),
        "hostRemainsDefaultOff": all(
            marker in sources["host"]
            for marker in (
                "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS",
                "(config::keys::OPTION_ENABLE_CLIPBOARD, \"N\")",
            )
        ),
        "documentationKeepsEndToEndBoundaryHonest": all(
            marker in (sources["architecture"] + sources["readme"])
            for marker in (
                "AppKit-owned pasteboard adapter",
                "Host clipboard policy remains",
                "Host 侧仍默认关闭",
                "富文本、图片和文件 promise 不跨 Viewer ABI",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2h Viewer pasteboard owner and explicit enablement contract",
        ),
        "defaultOffConfig": line_number(
            sources["core"], "receiveClipboardText: Bool = false"
        ),
        "boundedText": line_number(polling, "maximumUTF8Bytes = 64 * 1024"),
        "dynamicBackoff": line_number(
            polling, "125, 250, 500, 1_000, 2_000, 4_000"
        ),
        "ownedWriteSuppression": line_number(polling, "observeOwnedWrite("),
        "pasteboardOwner": line_number(owner, "final class ViewerPasteboardOwner"),
        "pasteboardWrite": line_number(owner, "pasteboard.setString(text, forType: .string)"),
        "productEnablement": line_number(app, "receiveClipboardText: true"),
        "clipboardCallback": line_number(app, "onClipboardText: { [weak self] text in"),
        "sessionGate": line_number(app, "clipboardSessionEpoch == viewerClipboardSessionEpoch"),
        "teardown": line_number(app, "private func stopViewerClipboard()"),
        "hostDefaultOff": line_number(
            sources["host"], "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS"
        ),
        "focusedTests": line_number(
            sources["polling_tests"], "final class ViewerClipboardPollingStateTests"
        ),
        "compositionTests": line_number(
            sources["composition_tests"],
            "final class ViewerPasteboardProductCompositionContractTests",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "viewer-pasteboard-owner-explicitly-enabled"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-viewer-pasteboard-owner-explicit-enablement",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDirectionsExplicitlyEnabled": True,
            "appKitOwnsViewerPasteboard": True,
            "preSessionClipboardUploaded": False,
            "pollingBackoffBounded": True,
            "clipboardContentLogged": False,
            "hostClipboardEnabled": False,
            "endToEndClipboardEnabled": False,
            "richClipboardEnabled": False,
        },
        "remainingBoundary": {
            "hostSmallTextExplicitOptInRequired": True,
            "richPayloadTransferRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "host-small-text-clipboard-explicit-opt-in-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "viewer-pasteboard-owner-explicitly-enabled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
