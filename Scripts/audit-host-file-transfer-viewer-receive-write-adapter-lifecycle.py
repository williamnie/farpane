#!/usr/bin/env python3
"""Audit H6.3f2b2p Viewer receive/write adapter lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-receive-write-adapter-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-session-orchestration-lifecycle"


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
        "adapter": repository / "Sources/CoreBridge/ViewerFileTransferReceiveAdapter.swift",
        "sessionOwner": repository / "Sources/CoreBridge/ViewerFileTransferSessionOwner.swift",
        "destination": repository / "Sources/CoreBridge/ViewerFileTransferDestinationOwner.swift",
        "tests": repository / "Tests/CoreBridgeTests/ViewerFileTransferReceiveAdapterTests.swift",
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

    adapter = sources["adapter"]
    destination = sources["destination"]
    core = sources["core"]
    product = sources["app"] + sources["agent"]
    tests = sources["tests"]
    session_owner = sources["sessionOwner"]
    evidence = {
        "designRecordsBoundedH63f2b2p": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b2p Viewer receive/write adapter lifecycle",
                NEXT_BOUNDARY,
            )
        ),
        "adapterAdmissionBindsExactLeaseAndBoundsConcurrency": all(
            marker in adapter
            for marker in (
                "package static let maximumConcurrentTransfers = 8",
                "activeTransfers[request.transferID] == nil",
                "destinationOwner.lease == request.destination",
                "let request: ViewerFileTransferDownloadRequest",
                "let destinationOwner: ViewerFileTransferDestinationOwner",
            )
        ),
        "blocksAreExactOrderedBoundedAndCommittedThroughOwner": all(
            marker in adapter
            for marker in (
                "block.sessionEpoch == active.request.sessionEpoch",
                "fileNumber >= active.nextFileNumber",
                "nextSize.partialValue <= declaredSize",
                "destinationOwner.reserveNewFile",
                "destinationOwner.writePayload",
                "destinationOwner.commitReservation",
                ".fileCommitted(fileNumber: fileNumber)",
            )
        ),
        "zeroFilesAndEmptyDirectoriesCompleteBeforeRemoteCompletionForwards": all(
            marker in adapter
            for marker in (
                "materializeZeroFiles(",
                "active.nextFileNumber == active.request.manifest.files.count",
                "active.request.manifest.emptyDirectories.indices",
                "destinationOwner.createEmptyDirectory",
                "active.onEvent(.completed)",
            )
        ) and all(
            marker in destination
            for marker in (
                "package func createEmptyDirectory(",
                "Self.destinationNameIsAbsent(",
                "Darwin.mkdirat",
                "O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.fsync(childDescriptor)",
                "Darwin.fsync(parentDescriptor)",
                ".durabilityUnconfirmed",
            )
        ),
        "localFailureCleanupAndDurabilityRemainDistinct": all(
            marker in adapter
            for marker in (
                "case protocolViolation",
                "case localIO",
                "case durabilityUnconfirmed",
                "case connectionClosed",
                "cancelReservation(reservation)",
                "case .durabilityUnconfirmed:",
                "disposition: ViewerFileTransferReceiveCoreEventDisposition = .suppress",
            )
        ),
        "coreStartPairsAdapterBeforeWireAndRollsBackRejectedStart": all(
            marker in core
            for marker in (
                "func beginFileTransferReceive(",
                "callbackBox.beginFileTransferReceive(",
                "rdn_shim_client_file_transfer_download_start",
                "if result != 0 {",
                "callbackBox.rollbackFileTransferReceive(",
                "destinationOwner: ViewerFileTransferDestinationOwner",
                "onReceiveEvent:",
            )
        ) and core.find("callbackBox.beginFileTransferReceive(")
            < core.find("let result = rdn_shim_client_file_transfer_download_start"),
        "callbackDeliveryWritesBeforeObservationAndCancelsLocalFailure": all(
            marker in core
            for marker in (
                "switch fileTransferReceiveAdapter.receive(block)",
                "case .unhandled, .accepted:",
                "onFileTransferReceiveBlock(block)",
                "switch fileTransferReceiveAdapter.observe(event)",
                "case .suppress:",
                "fileTransferCancelRelay.cancel(",
                "fileTransferReceiveAdapter.teardownAll()",
                "fileTransferCancelRelay.unbind()",
            )
        ),
        "regressionsCoverFilesystemOrderFailureRollbackAndTerminalTruth": all(
            marker in tests
            for marker in (
                "testWritesCommitsZeroFilesAndEmptyDirectoriesInManifestOrder",
                "testRejectsStaleOutOfOrderAndOversizeBlocksAndCleansStaging",
                "testTerminalFailureCancellationRollbackAndTeardownAreExact",
                "testRemoteTerminalAndPrematureCompletionDoNotMasqueradeAsLocalCommit",
                'Data("hello".utf8)',
                'mode_t(0o700)',
                ".failed(.protocolViolation)",
                ".failed(.remote(.unavailable))",
            )
        ),
        "downstreamSessionOrchestrationImplemented": all(
            marker in session_owner
            for marker in (
                "package final class ViewerFileTransferSessionOwner",
                "core.requestFileTransferRecursiveManifest(",
                "core.startFileTransferDownload(",
                "core.discardFileTransferReceive(",
            )
        ),
        "viewerABIUnchangedAndProductRemainsOff": (
            "#define RDN_ABI_VERSION 15u" in sources["header"]
            and "ViewerFileTransferReceiveAdapter" not in sources["header"]
            and "startFileTransferDownload(" not in product
            and "ViewerFileTransferReceiveAdapter" not in product
            and "The receive/write" in sources["readme"]
            and "adapter now binds" in sources["readme"]
            and "receive/write adapter" in sources["architecture"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2p Viewer receive/write adapter lifecycle",
        ),
        "adapter": line_number(adapter, "package final class ViewerFileTransferReceiveAdapter"),
        "blockAdmission": line_number(adapter, "    package func receive("),
        "terminalAdmission": line_number(adapter, "    package func observe("),
        "emptyDirectoryCommit": line_number(destination, "    package func createEmptyDirectory("),
        "coreStart": line_number(core, "    package func startFileTransferDownload("),
        "regression": line_number(
            tests,
            "testWritesCommitsZeroFilesAndEmptyDirectoriesInManifestOrder",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-receive-write-adapter-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-receive-write-adapter-lifecycle",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDownloadWireRequestImplemented": status == expected_status,
            "viewerDigestConfirmationImplemented": status == expected_status,
            "viewerReceiveWriteAdapterImplemented": status == expected_status,
            "viewerSessionOrchestrationImplemented": status == expected_status,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
