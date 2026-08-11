#!/usr/bin/env python3
"""Audit H6.3f2b2s Viewer download picker/action lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-download-picker-action-lifecycle-audit"
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
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "dialogs": repository / "Sources/RustDeskNative/ViewerFileTransferDialogs.swift",
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
    ui = sources["viewer_ui"]
    dialogs = sources["dialogs"]
    tests = sources["tests"]
    context = app[
        app.find("private struct ViewerFileTransferConnectionContext"):
        app.find("private final class HostMediaPipelineReference")
    ]
    stop = app[
        app.find("    private func stopViewerFileTransfer()"):
        app.find("    private func nextViewerFileTransferSessionEpoch()")
    ]
    action = app[
        app.find("    private func handleViewerFileTransferAction()"):
        app.find("    private func handleViewerFileTransferProductEvent(")
    ]
    event = app[
        app.find("    private func handleViewerFileTransferProductEvent("):
        app.find("    private func handleViewerClipboardText(")
    ]
    product_sources = app + sources["agent"]

    evidence = {
        "designRecordsBoundedH63f2b2s": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2s Viewer download picker/action lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "explicitActionPinsDestinationBeforeStartingCore": ordered(
            composition,
            "package func requestDownload(",
            "ViewerFileTransferDestinationOwner(",
            "queuedDownload = QueuedDownload(",
            "guard start(baseConfiguration: baseConfiguration)",
        ) and all(
            marker in composition
            for marker in (
                "case accepted(transferID: Int32)",
                "case destinationRejected",
                "private func beginQueuedActionIfNeeded()",
                "beginQueuedActionIfNeeded()",
            )
        ),
        "queuedActionCancelAndFailureCloseAuthority": all(
            marker in composition
            for marker in (
                "queued.transferID == transferID",
                "queued.destinationOwner.teardown(sessionEpoch: sessionEpoch)",
                "outcome: .cancelled",
                "let queued = queuedDownload",
                "queuedDownload = nil",
                "phase = .failed(failure)",
            )
        ),
        "pickerIsDirectoryOnlySingleSheetAndAliasClosed": all(
            marker in dialogs
            for marker in (
                "let panel = NSOpenPanel()",
                "panel.canChooseFiles = false",
                "panel.canChooseDirectories = true",
                "panel.allowsMultipleSelection = false",
                "panel.canCreateDirectories = true",
                "panel.resolvesAliases = false",
                "panel.beginSheetModal(for: window)",
                "权限 0700",
            )
        ),
        "credentialIsLazyAndNotRetainedInActionContext": (
            "let password" not in context
            and "var password" not in context
            and "print(" not in action
            and "fputs(" not in action
            and "print(" not in dialogs
            and all(
                marker in action
                for marker in (
                    "credentialStore.read(deviceID: deviceID)",
                    "ViewerFileTransferPasswordPromptController()",
                    "context.configuration(password: password)",
                    "configuration = context.configuration(password: \"\")",
                )
            )
            and all(
                marker in app
                for marker in (
                    "let verifiedCredentialDeviceID = pendingProductConnection.flatMap",
                    "$0.usedStoredCredential || $0.savePassword",
                    "credentialDeviceID: verifiedCredentialDeviceID",
                )
            )
            and all(
                marker in dialogs
                for marker in (
                    "private let passwordField = NSSecureTextField()",
                    "self.passwordField.stringValue = \"\"",
                    "password = \"\"",
                    "该密码不会因本次操作保存",
                )
            )
        ),
        "liveViewerButtonIsExplicitAndStateGated": all(
            marker in ui
            for marker in (
                "var onFileTransferAction: (() -> Void)?",
                "NSButton(title: \"接收文件\"",
                "views.append(fileTransferButton)",
                "func setFileTransferAvailable(_ available: Bool)",
                "func updateFileTransferAction(",
                "onFileTransferAction?()",
            )
        ) and all(
            marker in app
            for marker in (
                "showsFileTransferControls: liveConfiguration != nil",
                "chrome.onFileTransferAction =",
                "if event.state == .streaming",
                "!viewerFileTransferActionConsumed",
            )
        ),
        "appUsesExactEpochAndOneShotAction": all(
            marker in action + event
            for marker in (
                "composition.snapshot().sessionEpoch",
                "viewerFileTransferComposition?.snapshot().sessionEpoch",
                "composition.requestDownload(",
                "viewerFileTransferActiveTransferID = transferID",
                "viewerFileTransferActionConsumed = true",
                "composition.requestCancellation(transferID: transferID)",
                "viewerChrome?.setFileTransferAvailable(false)",
                "Recursive manifest authority is intentionally one-shot",
            )
        ),
        "teardownInvalidatesUiBeforeCompositionAndDesktopCore": ordered(
            stop,
            "viewerFileTransferComposition = nil",
            "destinationPicker?.cancel()",
            "passwordPrompt?.cancel()",
            "composition?.teardown()",
        ) and ordered(
            app[
                app.find("    private func showHomeUI("):
                app.find("    private func refreshHomeUI(")
            ],
            "stopViewerFileTransfer()",
            "coreClient?.disconnect()",
        ),
        "regressionsCoverAdmissionReadyCancelAndFailure": all(
            marker in tests
            for marker in (
                "testExplicitDownloadActionPinsDestinationAndStartsOnlyAfterReady",
                "testQueuedDownloadActionCanBeCancelledBeforeConnectionIsReady",
                "testDownloadActionRejectsUnsafeDestinationAndSynchronousFailure",
                ".accepted(transferID: 1)",
                ".destinationRejected",
                ".unavailable",
            )
        ),
        "viewerABIUnchangedAndHostProductOptInStillOff": (
            "#define RDN_ABI_VERSION 18u" in sources["header"]
            and "fileTransferEnabled: true" not in product_sources
            and "farpane.host.fileTransfer.enabled" in product_sources and "return .disabled" in product_sources
            and "Viewer download picker" in sources["readme"]
            and "live Viewer" in sources["architecture"]
            and "directory-only" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2s Viewer download picker/action lifecycle",
        ),
        "requestDownload": line_number(composition, "package func requestDownload("),
        "queuedCancel": line_number(composition, "queued.transferID == transferID"),
        "picker": line_number(dialogs, "let panel = NSOpenPanel()"),
        "passwordPrompt": line_number(
            dialogs,
            "final class ViewerFileTransferPasswordPromptController",
        ),
        "viewerButton": line_number(ui, "NSButton(title: \"接收文件\""),
        "appAction": line_number(app, "private func handleViewerFileTransferAction()"),
        "appEvent": line_number(
            app,
            "private func handleViewerFileTransferSessionEvent(",
        ),
        "regression": line_number(
            tests,
            "testExplicitDownloadActionPinsDestinationAndStartsOnlyAfterReady",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-download-picker-action-implemented-host-opt-in-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-download-picker-action-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDownloadPickerActionImplemented": status == expected_status,
            "viewerActionIsOneShot": status == expected_status,
            "hostReceiveRootOptInImplemented": False,
            "endToEndProductFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
