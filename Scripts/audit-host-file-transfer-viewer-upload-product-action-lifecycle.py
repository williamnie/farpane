#!/usr/bin/env python3
"""Audit H6.3l Viewer upload product action lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-upload-product-action-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-installed-single-mac-smoke"


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
        "composition": repository
        / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift",
        "owner": repository
        / "Sources/CoreBridge/ViewerFileTransferUploadSessionOwner.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "dialogs": repository
        / "Sources/RustDeskNative/ViewerFileTransferDialogs.swift",
        "tests": repository
        / "Tests/CoreBridgeTests/ViewerFileTransferProductCompositionTests.swift",
        "build": repository / "Scripts/build-universal.sh",
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
    owner = sources["owner"]
    app = sources["app"]
    ui = sources["ui"]
    dialogs = sources["dialogs"]
    tests = sources["tests"]
    evidence = {
        "designRecordsBoundedProductBoundary": all(
            marker in sources["design"] for marker in (
                "H6.3l Viewer upload product action lifecycle",
                "双机上传仍未验证且不阻塞开发完成",
                NEXT_BOUNDARY,
            )
        ),
        "explicitPickerSupportsFilesDirectoriesAndNoAliases": all(
            marker in dialogs for marker in (
                "ViewerFileTransferUploadSourcePickerController",
                "panel.canChooseFiles = true",
                "panel.canChooseDirectories = true",
                "panel.allowsMultipleSelection = true",
                "panel.resolvesAliases = false",
                "guard let selected, !selected.isEmpty",
            )
        ),
        "viewerExposesIndependentSendAction": all(
            marker in ui for marker in (
                "var onFileTransferUploadAction: (() -> Void)?",
                'NSButton(title: "发送文件"',
                "#selector(fileTransferUploadAction)",
                "onFileTransferUploadAction?()",
                "发送文件到远端",
            )
        ),
        "appRoutesExactEpochCredentialAndDirection": all(
            marker in app for marker in (
                "handleViewerFileTransferUploadAction()",
                "ViewerFileTransferUploadSourcePickerController()",
                "selection: .upload(selectedURLs: selectedURLs)",
                "context.configuration(password: password)",
                "composition.requestFileTransferUpload(",
                "viewerFileTransferActiveDirection = outcome.direction",
                "progress.direction == .upload",
            )
        ) and "print(" not in app[
            app.find("    private func handleViewerFileTransferUploadAction()"):
            app.find("    private func handleViewerFileTransferProductEvent(")
        ],
        "compositionPinsSourceBeforeDedicatedCore": ordered(
            composition,
            "package func requestFileTransferUpload(",
            "ViewerFileTransferUploadSourceOwner(",
            "queuedUpload = QueuedUpload(",
            "guard start(baseConfiguration: baseConfiguration)",
        ) and all(marker in composition for marker in (
            "ViewerFileTransferUploadSessionCore",
            "beginQueuedActionIfNeeded()",
            "uploadOwner?.observeCore(event)",
            "queued.sourceOwner.teardown(sessionEpoch: sessionEpoch)",
        )),
        "uploadOwnerValidatesProgressCancelAndTeardown": all(
            marker in owner for marker in (
                "ViewerFileTransferProgressAuthority()",
                "event.totalFiles == UInt32(active.request.manifest.files.count)",
                "event.totalBytes == active.request.manifest.totalBytes",
                "core.cancelFileTransfer(",
                "core.discardFileTransferUpload(",
                "active.sourceOwner.teardown(sessionEpoch: sessionEpoch)",
                "outcome: .failed(.coreCommandRejected)",
            )
        ),
        "teardownCancelsPickersAndClosesUploadBeforeCore": ordered(
            app[
                app.find("    private func stopViewerFileTransfer()"):
                app.find("    private func nextViewerFileTransferSessionEpoch()")
            ],
            "viewerFileTransferComposition = nil",
            "uploadPicker?.cancel()",
            "passwordPrompt?.cancel()",
            "composition?.teardown()",
        ) and ordered(
            composition[
                composition.find("    package func teardown()"):
                composition.find("    private func observeState(")
            ],
            "uploadOwner?.teardown(sessionEpoch: sessionEpoch)",
            "core?.disconnect()",
        ),
        "regressionsCoverReadyTerminalCancelAndProtocolFailure": all(
            marker in tests for marker in (
                "testExplicitUploadActionPinsSourceAndStartsOnlyAfterReady",
                "testQueuedUploadCanBeCancelledAndUnsafeSourceFailsClosed",
                "testActiveUploadCancellationWaitsForExactTerminalEvent",
                "testUploadProtocolViolationCancelsDiscardsAndFailsClosed",
                ".sourceRejected",
                ".discardUpload(epoch: 45, transferID: 1)",
            )
        ),
        "appBuildRejectsCoreWithoutUploadABI": (
            "_rdn_client_file_transfer_upload_start" in sources["build"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3l Viewer upload product action lifecycle",
        ),
        "productRequest": line_number(
            composition,
            "package func requestFileTransferUpload(",
        ),
        "uploadOwner": line_number(
            owner,
            "package final class ViewerFileTransferUploadSessionOwner",
        ),
        "sendButton": line_number(ui, 'NSButton(title: "发送文件"'),
        "appAction": line_number(
            app,
            "private func handleViewerFileTransferUploadAction()",
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "viewer-upload-product-action-implemented" if passed else "audit-failed",
        "coverageScope": "h6-host-file-transfer-viewer-upload-product-action-lifecycle",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerUploadProductActionImplemented": passed,
            "uploadSourcePathsCrossABI": False,
            "installedSingleMacSmokeComplete": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
