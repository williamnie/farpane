#!/usr/bin/env python3
"""Audit H6.3f2b1 Viewer dedicated file-session and cancel lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-viewer-dedicated-session-audit"


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
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
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

    bridge = sources["bridge"]
    product = sources["app"] + sources["agent"]
    admission = bridge.find("let file_transfer_admission =")
    state_mutation = bridge.find("client.shared.active.store(true")
    evidence = {
        "designRecordsBoundedH63f2b1": all(
            marker in sources["design"]
            for marker in (
                "H6.3f2b1 Viewer dedicated file-session and cancel dispatch lifecycle",
                "host-file-transfer-viewer-destination-descriptor-owner",
            )
        ),
        "exactModePairRejectsDesktopClipboard": all(
            marker in bridge
            for marker in (
                "fn viewer_file_transfer_mode_admission(",
                "if enabled != (session_epoch > 0)",
                "else if enabled && desktop_clipboard_requested",
                "let desktop_clipboard_requested = (*config).receive_clipboard_text",
            )
        ),
        "admissionPrecedesRuntimeMutation": (
            admission >= 0 and state_mutation >= 0 and admission < state_mutation
        ),
        "enabledModeUsesDedicatedUpstreamConnection": all(
            marker in bridge
            for marker in (
                "let file_transfer_mode = (*config).enable_file_transfer;",
                ".store(file_transfer_mode, Ordering::Release);",
                ".store((*config).file_transfer_session_epoch, Ordering::Release);",
                "ConnType::FILE_TRANSFER",
                "ConnType::DEFAULT_CONN",
            )
        ),
        "fileModeNeverEnablesInput": all(
            marker in bridge
            for marker in (
                "let allowed = !file_transfer",
                "!self.shared.file_transfer_enabled.load(Ordering::Acquire)",
                'emit_state(RDNState::Streaming, 0, "file-transfer-ready")',
            )
        ),
        "fileModeSkipsDesktopHousekeeping": all(
            marker in bridge
            for marker in (
                "let housekeeping = if file_transfer_mode",
                "None",
                "native_stream_configuration_message(",
                "*client.housekeeping.lock().unwrap() = housekeeping;",
            )
        ),
        "workerAndDisconnectClearModeEpoch": (
            bridge.count(".file_transfer_enabled\n            .store(false, Ordering::Release);") >= 2
            and bridge.count(".file_transfer_session_epoch\n            .store(0, Ordering::Release);") >= 2
        ),
        "cancelRequiresLifecyclePermissionAndExactEpoch": all(
            marker in bridge
            for marker in (
                "pub unsafe extern \"C\" fn rdn_client_file_transfer_cancel(",
                "if session_epoch == 0 || transfer_id <= 0",
                "return -10;",
                "if !client.shared.authenticated.load(Ordering::Acquire)",
                "if !*session.server_file_transfer_enabled.read().unwrap()",
                "if sender.send(Data::CancelJob(transfer_id)).is_err()",
            )
        ),
        "rustRegressionReadsRealCancelChannel": all(
            marker in bridge
            for marker in (
                "viewer_file_transfer_mode_dispatches_exact_epoch_cancel_only_when_ready",
                "mpsc::unbounded_channel()",
                "rdn_client_file_transfer_cancel(client_pointer, 6, 23)",
                "rdn_client_file_transfer_cancel(client_pointer, 7, 23)",
                "receiver.try_recv(), Ok(Data::CancelJob(23))",
            )
        ),
        "abiV12RetainsDedicatedSessionAndProductOff": (
            "#define RDN_ABI_VERSION 13u" in sources["header"]
            and "fileTransferEnabled:" not in product
        ),
        "remainingManifestAndDestinationGapIsExplicit": (
            "destination\n  owner" in sources["architecture"]
            and "No download command" in sources["readme"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b1 Viewer dedicated file-session and cancel dispatch lifecycle",
        ),
        "admission": line_number(bridge, "fn viewer_file_transfer_mode_admission("),
        "connect": line_number(bridge, "pub unsafe extern \"C\" fn rdn_client_connect("),
        "dedicatedMode": line_number(bridge, "ConnType::FILE_TRANSFER"),
        "housekeepingGate": line_number(bridge, "let housekeeping = if file_transfer_mode"),
        "cancel": line_number(bridge, "fn rdn_client_file_transfer_cancel("),
        "regression": line_number(
            bridge,
            "fn viewer_file_transfer_mode_dispatches_exact_epoch_cancel_only_when_ready()",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    expected_status = "viewer-dedicated-file-session-cancel-implemented-product-off"
    status = expected_status if not missing and not missing_lines else "audit-failed"
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-viewer-dedicated-session",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "viewerDedicatedFileSessionImplemented": status == expected_status,
            "viewerCancelDispatchImplemented": status == expected_status,
            "viewerListManifestLifecycleImplemented": False,
            "viewerDestinationIOImplemented": False,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": (
            "host-file-transfer-viewer-destination-descriptor-owner"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
