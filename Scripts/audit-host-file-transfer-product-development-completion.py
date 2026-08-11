#!/usr/bin/env python3
"""Audit current H6.3 product-development completion without claiming live acceptance."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess


SCHEMA = "farpane-host-file-transfer-product-development-completion-audit"
NEXT_BOUNDARY = "host-file-transfer-viewer-upload-selection-manifest-contract"
MINIMUM_REQUIRED_AUDITS = 37


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def run_required_audits(repository: Path) -> tuple[set[str], list[str]]:
    current = Path(__file__).resolve()
    passed: set[str] = set()
    failed: list[str] = []
    for audit in sorted((repository / "Scripts").glob(
        "audit-host-file-transfer-*.py"
    )):
        if audit.resolve() == current:
            continue
        try:
            completed = subprocess.run(
                ["python3", str(audit)],
                cwd=repository,
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
            document = json.loads(completed.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            failed.append(audit.name)
            continue

        missing_lists_are_empty = all(
            not value
            for key, value in document.items()
            if key.startswith("missing") and isinstance(value, list)
        )
        schema = document.get("schema")
        status = document.get("status")
        if (
            completed.returncode == 0
            and isinstance(schema, str)
            and schema.startswith("farpane-host-file-transfer-")
            and status != "audit-failed"
            and missing_lists_are_empty
        ):
            passed.add(audit.name)
        else:
            failed.append(audit.name)
    return passed, failed


def includes_all(passed: set[str], names: tuple[str, ...]) -> bool:
    return set(names).issubset(passed)


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "viewer_dialogs": repository
        / "Sources/RustDeskNative/ViewerFileTransferDialogs.swift",
        "viewer_contract": repository
        / "Sources/CoreBridge/ViewerFileTransferContract.swift",
        "viewer_composition": repository
        / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift",
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

    passed_audits, failed_audits = run_required_audits(repository)
    policy_audits = (
        "audit-host-file-transfer-explicit-policy-abi-contract.py",
        "audit-host-file-transfer-bootstrap-publication-policy-lifecycle.py",
        "audit-host-file-transfer-host-home-receive-root-opt-in-lifecycle.py",
    )
    host_receive_audits = (
        "audit-host-file-transfer-native-new-write-lifecycle.py",
        "audit-host-file-transfer-native-resume-digest-lifecycle.py",
        "audit-host-file-transfer-native-existing-target-lifecycle.py",
    )
    host_send_audits = (
        "audit-host-file-transfer-native-read-list-snapshot.py",
        "audit-host-file-transfer-native-read-list-download-connection.py",
    )
    viewer_download_audits = (
        "audit-host-file-transfer-viewer-product-composition-lifecycle.py",
        "audit-host-file-transfer-viewer-download-picker-action-lifecycle.py",
        "audit-host-file-transfer-viewer-session-orchestration-lifecycle.py",
        "audit-host-file-transfer-viewer-download-wire-request-lifecycle.py",
        "audit-host-file-transfer-viewer-download-digest-confirmation-lifecycle.py",
        "audit-host-file-transfer-viewer-receive-write-adapter-lifecycle.py",
    )
    safety_audits = (
        "audit-host-file-transfer-bounded-block-envelope.py",
        "audit-host-file-transfer-safe-receive-root.py",
        "audit-host-file-transfer-safe-root-mutations.py",
        "audit-host-file-transfer-viewer-destination-descriptor-owner.py",
        "audit-host-file-transfer-viewer-safe-staging-reservation-lifecycle.py",
        "audit-host-file-transfer-viewer-safe-receive-write-lifecycle.py",
        "audit-host-file-transfer-viewer-safe-receive-commit-lifecycle.py",
    )

    app = sources["app"]
    home = sources["home"]
    viewer_ui = sources["viewer_ui"]
    viewer_dialogs = sources["viewer_dialogs"]
    viewer_contract = sources["viewer_contract"]
    viewer_composition = sources["viewer_composition"]

    host_opt_in = includes_all(passed_audits, policy_audits) and all(
        marker in app + home
        for marker in (
            "farpane.host.fileTransfer.enabled",
            "HostFileTransferReceiveRootPickerController",
            "fileTransferPolicy: currentHostFileTransferPolicy()",
            "允许远端发送文件到本机",
        )
    )
    host_receive = includes_all(passed_audits, host_receive_audits)
    host_send = includes_all(passed_audits, host_send_audits)
    viewer_download = includes_all(passed_audits, viewer_download_audits) and all(
        marker in viewer_ui + viewer_dialogs + viewer_composition
        for marker in (
            'NSButton(title: "接收文件"',
            "ViewerFileTransferDestinationPickerController",
            "requestDownload(",
        )
    )
    safety_complete = includes_all(passed_audits, safety_audits)

    upload_markers = (
        "ViewerFileTransferUploadRequest",
        "requestFileTransferUpload",
        "onFileTransferUploadAction",
        'NSButton(title: "发送文件"',
        "panel.canChooseFiles = true",
    )
    upload_sources = viewer_contract + viewer_composition + viewer_ui + viewer_dialogs
    viewer_upload = all(marker in upload_sources for marker in upload_markers)
    viewer_upload_gap_proven = (
        "case download = 1" in viewer_contract
        and not viewer_upload
        and "onFileTransferUploadAction" not in viewer_ui
        and "panel.canChooseFiles = true" not in viewer_dialogs
    )

    evidence = {
        "designKeepsFileTransferIndependentAndUntrusted": all(
            marker in sources["design"]
            for marker in (
                "H6.3 文件传输：复用上游 file 服务",
                "远端文件名/UTI/payload 视为不可信输入",
                "完整文件管理器、远程终端、远程打印和隐私模式",
            )
        ),
        "singleMacDevelopmentCompletionBoundaryPreserved": (
            "当前开发完成口径（2026-08-11）" in sources["design"]
            and "文件传输、Direct/Relay" in sources["design"]
            and "现场检查继续如实记为“未验证”" in sources["design"]
        ),
        "allRequiredMachineAuditsPass": (
            len(passed_audits) >= MINIMUM_REQUIRED_AUDITS
            and not failed_audits
        ),
        "hostExplicitReceiveOptInIsDefaultOff": (
            host_opt_in
            and "return .disabled" in app
            and "文件接收（默认关闭）" in home
        ),
        "hostDescriptorOwnedReceiveAndSendPlanesExist": (
            host_receive and host_send
        ),
        "viewerDownloadActionReachesSafeReceiveComposition": viewer_download,
        "untrustedMetadataPayloadAndRootsAreBounded": safety_complete,
        "conflictAndResumeBoundaryIsExplicit": (
            "不会覆盖已有文件" in viewer_dialogs
            and "audit-host-file-transfer-native-existing-target-lifecycle.py"
                in passed_audits
            and "audit-host-file-transfer-native-resume-digest-lifecycle.py"
                in passed_audits
        ),
        "viewerUploadGapIsProvenByCurrentProductSources": (
            viewer_upload_gap_proven
        ),
    }

    development_complete = all((
        host_opt_in,
        host_receive,
        host_send,
        viewer_download,
        viewer_upload,
        safety_complete,
    ))
    remaining_gaps = [] if viewer_upload else ["viewerUploadProductAction"]
    expected_incomplete = (
        all(evidence.values())
        and remaining_gaps == ["viewerUploadProductAction"]
        and not development_complete
    )
    if development_complete and all(evidence.values()):
        status = "product-development-complete"
        next_boundary = "host-file-transfer-installed-single-mac-smoke"
    elif expected_incomplete:
        status = "product-development-incomplete-viewer-upload"
        next_boundary = NEXT_BOUNDARY
    else:
        status = "audit-failed"
        next_boundary = NEXT_BOUNDARY

    source_lines = {
        "designRequirement": line_number(
            sources["design"],
            "H6.3 文件传输：复用上游 file 服务",
        ),
        "hostOptIn": line_number(home, "文件接收（默认关闭）"),
        "viewerDownloadAction": line_number(
            viewer_ui, 'NSButton(title: "接收文件"'
        ),
        "viewerDownloadOnlyDirection": line_number(
            viewer_contract, "case download = 1"
        ),
        "viewerUploadAction": line_number(
            viewer_ui, "onFileTransferUploadAction"
        ),
    }
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": status,
        "coverageScope": "h6-host-file-transfer-product-development-completion",
        "requiredAuditCount": len(passed_audits) + len(failed_audits),
        "failedRequiredAudits": failed_audits,
        "evidence": evidence,
        "sourceLines": source_lines,
        "claims": {
            "hostExplicitReceiveOptInImplemented": host_opt_in,
            "hostReceiveDataPlaneImplemented": host_receive,
            "hostSendDataPlaneImplemented": host_send,
            "viewerDownloadProductActionImplemented": viewer_download,
            "viewerUploadProductActionImplemented": viewer_upload,
            "fileTransferProductDevelopmentComplete": development_complete,
            "installedSingleMacSmokeComplete": False,
            "twoMacBidirectionalAcceptanceComplete": False,
        },
        "remainingDevelopmentGaps": remaining_gaps,
        "nonBlockingAcceptanceGaps": [
            "installedSingleMacSmoke",
            "twoMacBidirectionalFileTransfer",
            "crossMachinePerformanceAndInteroperability",
        ],
        "nextImplementationBoundary": next_boundary,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status != "audit-failed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
