#!/usr/bin/env python3
"""Audit H6.3f2b2q Viewer file-transfer session orchestration."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-session-orchestration-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-product-composition-lifecycle"


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
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "core": repository / "Sources/CoreBridge/CoreBridge.swift",
        "contract": repository / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "owner": repository / "Sources/CoreBridge/ViewerFileTransferSessionOwner.swift",
        "composition": repository / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferSessionOwnerTests.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
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

    owner = sources["owner"]
    core = sources["core"]
    contract = sources["contract"]
    tests = sources["tests"]
    composition = sources["composition"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designRecordsBoundedH63f2b2q": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2q Viewer session orchestration lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "oneExactEpochSerializesManifestAndBoundsDownloads": all(
            marker in owner
            for marker in (
                "private let sessionEpoch: UInt64",
                "private var pendingDownload: PendingDownload?",
                "pendingDownload == nil",
                "activeDownloads.count < Self.maximumConcurrentDownloads",
                "activeDownloads[transferID] == nil",
                "destinationOwner.lease?.sessionEpoch == sessionEpoch",
                "ViewerFileTransferProgressAuthority.maximumConcurrentTransfers",
            )
        ),
        "manifestStartAndDestinationOwnershipAreOneChain": all(
            marker in owner
            for marker in (
                "manifestAuthority.begin(",
                "core.requestFileTransferRecursiveManifest(",
                "event.recursiveManifestPart",
                "ViewerFileTransferDownloadRequest(",
                "progressAuthority.begin(request)",
                "core.startFileTransferDownload(",
                "destinationOwner: pending.destinationOwner",
                "closePending(pending",
                "closeActive(active, outcome: .failed(.coreCommandRejected))",
            )
        ),
        "terminalRequiresReceiveProofAndExactProgressAuthority": all(
            marker in owner
            for marker in (
                "private enum TerminalProof",
                "active.nextCommittedFileNumber == active.request.manifest.files.count",
                "active.terminalProof == .completed",
                "active.terminalProof == .cancelled",
                "active.terminalProof == .failed(event.failure)",
                "progressAuthority.observe(update)",
                "closeActive(active, outcome: terminalOutcome)",
                "case receive(ViewerFileTransferReceiveFailure)",
            )
        ),
        "cancelAndProtocolFailureDiscardOnlyExactReceiveRoute": all(
            marker in owner
            for marker in (
                "progressAuthority.requestCancellation(",
                "core.cancelFileTransfer(",
                "core.discardFileTransferReceive(",
                "sessionEpoch: sessionEpoch",
                "transferID: transferID",
                "outcome: .failed(.coreCommandRejected)",
                "failure: .protocolViolation",
            )
        ) and all(
            marker in core
            for marker in (
                "package func discardFileTransferReceive(",
                "callbackBox.rollbackFileTransferReceive(",
            )
        ),
        "teardownWaitsForCommandsAndClosesEveryOwnedResource": all(
            marker in owner
            for marker in (
                "private var operationsInFlight = 0",
                "while operationsInFlight > 0 { condition.wait() }",
                "activeDownloads.values.sorted",
                "progressAuthority.teardown(sessionEpoch: sessionEpoch)",
                "item.destinationOwner.teardown(sessionEpoch: sessionEpoch)",
                "pending.destinationOwner.teardown(sessionEpoch: sessionEpoch)",
                "outcome: .failed(.connectionClosed)",
                "teardownComplete = true",
            )
        ),
        "progressAuthoritySupportsExactTransferTeardown": all(
            marker in contract
            for marker in (
                "package mutating func teardown(sessionEpoch: UInt64, transferID: Int32)",
                "active.snapshot.sessionEpoch == sessionEpoch",
                "activeTransfers.removeValue(forKey: transferID)",
            )
        ),
        "regressionsCoverChainLimitsProofsFailuresAndTeardown": all(
            marker in tests
            for marker in (
                "testRequestsManifestStartsDownloadAndRequiresLocalCompletionProof",
                "testSerializesManifestRequestsWhileAllowingActiveDownload",
                "testRejectedCancelFailsClosedAndDiscardsExactReceiveRoute",
                "testCoreTerminalWithoutReceiveProofFailsProtocolClosed",
                "testManifestFailureClosesOnlyTheAcceptedDestination",
                "testExactEpochTeardownCancelsActiveAndClosesPendingOwners",
                "testCommandRejectionPreservesUnacceptedOwnerAndClosesStartedOwner",
                "testRemoteFailureRequiresMatchingReceiveProof",
                "testTeardownWaitsForInFlightManifestCommandBeforeClosingDestination",
                "testConcurrentDownloadLimitIsEightAndRejectedOwnerStaysOpen",
            )
        ),
        "viewerABIUnchangedAndProductRemainsOff": (
            "#define RDN_ABI_VERSION 13u" in sources["header"]
            and "ViewerFileTransferSessionOwner" not in sources["header"]
            and "ViewerFileTransferSessionOwner" not in product
            and "fileTransferEnabled: true" not in product
            and "session owner now" in sources["readme"]
            and "session owner" in sources["architecture"]
        ),
        "downstreamProductCompositionImplemented": all(
            marker in composition
            for marker in (
                "package final class ViewerFileTransferProductComposition",
                "fileTransferEnabled: true",
                "owner?.teardown(sessionEpoch: sessionEpoch)",
                "core?.disconnect()",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2q Viewer session orchestration lifecycle",
        ),
        "coreProtocol": line_number(owner, "package protocol ViewerFileTransferSessionCore"),
        "owner": line_number(owner, "package final class ViewerFileTransferSessionOwner"),
        "begin": line_number(owner, "    package func beginDownload("),
        "manifest": line_number(owner, "    package func observeManifest("),
        "terminal": line_number(owner, "    package func observeCore("),
        "cancel": line_number(owner, "    package func requestCancellation("),
        "teardown": line_number(owner, "    package func teardown(sessionEpoch:"),
        "coreDiscard": line_number(core, "    package func discardFileTransferReceive("),
        "regression": line_number(
            tests,
            "testRequestsManifestStartsDownloadAndRequiresLocalCompletionProof",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-session-orchestration-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-session-orchestration-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerReceiveWriteAdapterImplemented": status == expected_status,
            "viewerSessionOrchestrationImplemented": status == expected_status,
            "viewerProductCompositionImplemented": status == expected_status,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
