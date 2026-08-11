#!/usr/bin/env python3
"""Audit H6.3f2b2r Viewer file-transfer product composition lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-product-composition-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-host-home-receive-root-opt-in-lifecycle"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def ordered(source: str, *markers: str) -> bool:
    cursor = 0
    for marker in markers:
        offset = source.find(marker, cursor)
        if offset < 0:
            return False
        cursor = offset + len(marker)
    return True


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "architecture": repository / "docs/architecture.md",
        "readme": repository / "CoreBridge/README.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "composition": repository / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift",
        "session": repository / "Sources/CoreBridge/ViewerFileTransferSessionOwner.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferProductCompositionTests.swift",
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

    composition = sources["composition"]
    app = sources["app"]
    tests = sources["tests"]
    teardown = composition[
        composition.find("    package func teardown()"):
        composition.find("    private func observeState(")
    ]
    home = app[
        app.find("    private func showHomeUI("):
        app.find("    private func refreshHomeUI(")
    ]
    finish = app[
        app.find("    private func finish()"):
        app.find("    private func stopViewerAutomaticRecovery()")
    ]
    product_sources = app + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2r": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2r Viewer product composition lifecycle",
                "host-file-transfer-viewer-download-picker-action-lifecycle",
            )
        ),
        "dedicatedCoreProjectionIsExactAndClipboardFree": all(
            marker in composition
            for marker in (
                "package protocol ViewerFileTransferProductCore:",
                "package typealias CoreFactory",
                "Self.dedicatedConfiguration(",
                "receiveClipboardText: false",
                "sendClipboardText: false",
                "receiveClipboardRichText: false",
                "sendClipboardRichText: false",
                "receiveClipboardImage: false",
                "sendClipboardImage: false",
                "fileTransferEnabled: true",
                "fileTransferSessionEpoch: sessionEpoch",
            )
        ),
        "fileReadinessRoutesOnlyExactSessionCallbacks": all(
            marker in composition
            for marker in (
                "case .streaming where phase == .connecting:",
                "phase = .ready",
                "owner?.observeManifest(event)",
                "owner?.observeCore(event)",
                "phase == .ready && !teardownStarted",
                "connectionReady(sessionEpoch: UInt64)",
                "connectionFailed(",
            )
        ),
        "destinationAdmissionOwnsMonotonicOpaqueAuthority": all(
            marker in composition
            for marker in (
                "private var nextTransferID: Int32 = 0",
                "private var nextDestinationToken: UInt64 = 0",
                "nextTransferID += 1",
                "nextDestinationToken += 1",
                "ViewerFileTransferDestinationOwner(",
                "manifestRequestID: transferID",
                "destination.teardown(sessionEpoch: sessionEpoch)",
            )
        ),
        "teardownClosesSessionBeforeDedicatedCore": ordered(
            teardown,
            "owner?.teardown(sessionEpoch: sessionEpoch)",
            "core?.disconnect()",
            "teardownComplete = true",
        ),
        "appOwnsCompositionAndStopsBeforeDesktopCore": all(
            marker in app
            for marker in (
                "private var viewerFileTransferComposition:",
                "prepareViewerFileTransferComposition(",
                "ViewerFileTransferProductComposition(",
                "onFileTransferEvent: callbacks.onTransfer",
                "onFileTransferManifest: callbacks.onManifest",
                "private func stopViewerFileTransfer()",
                "let composition = viewerFileTransferComposition",
                "composition?.teardown()",
            )
        ) and ordered(home, "stopViewerFileTransfer()", "coreClient?.disconnect()")
            and ordered(finish, "stopViewerFileTransfer()", "coreClient?.disconnect()"),
        "regressionsCoverProjectionRoutingFailuresAndOrder": all(
            marker in tests
            for marker in (
                "testProjectsDedicatedConfigurationAndRoutesOneCompletedDownload",
                "testExplicitTeardownCancelsAndDiscardsBeforeDisconnect",
                "testTerminalConnectionFailsClosedAndRejectsFurtherDownloads",
                "testCoreCreationAndConnectFailureAreStableAndDisconnectOwnedCore",
                "testInvalidEpochUnsafeDestinationAndPreReadyDownloadFailClosed",
                "testSynchronousReadyCallbackIsDeferredUntilStartCanTeardownReentrantly",
                ".cancel(epoch: 32, transferID: 1)",
                ".discard(epoch: 32, transferID: 1)",
                ".disconnect",
            )
        ),
        "viewerABIUnchangedAndHostProductOptInRemainsOff": (
            "#define RDN_ABI_VERSION 13u" in sources["header"]
            and "ViewerFileTransferProductComposition" not in sources["header"]
            and "fileTransferEnabled: true" not in product_sources
            and "fileTransferReceiveRoot:" not in product_sources
            and ".start(baseConfiguration:" not in app
            and ".beginDownload(destinationDirectory:" not in app
            and "composition.requestDownload(" in app
            and "product composition" in sources["readme"]
            and "product composition" in sources["architecture"]
        ),
        "downstreamDownloadPickerActionImplemented": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2s Viewer download picker/action lifecycle",
                NEXT_BOUNDARY,
            )
        ) and "private func handleViewerFileTransferAction()" in app,
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2r Viewer product composition lifecycle",
        ),
        "coreProtocol": line_number(
            composition,
            "package protocol ViewerFileTransferProductCore:",
        ),
        "composition": line_number(
            composition,
            "package final class ViewerFileTransferProductComposition",
        ),
        "start": line_number(composition, "    package func start("),
        "download": line_number(composition, "    package func beginDownload("),
        "teardown": line_number(composition, "    package func teardown()"),
        "appOwner": line_number(app, "private var viewerFileTransferComposition:"),
        "appPreparation": line_number(
            app,
            "private func prepareViewerFileTransferComposition(",
        ),
        "regression": line_number(
            tests,
            "testProjectsDedicatedConfigurationAndRoutesOneCompletedDownload",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-product-composition-implemented-action-downstream"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-product-composition-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerSessionOrchestrationImplemented": status == expected_status,
            "viewerProductCompositionImplemented": status == expected_status,
            "viewerDownloadPickerActionImplemented": status == expected_status,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
