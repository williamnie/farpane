#!/usr/bin/env python3
"""Audit the H6.2f clipboard transient-object and provider teardown contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-temporary-object-cleanup-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "cargo": repository / "Vendor/rustdesk/Cargo.toml",
        "clipboard": repository / "Vendor/rustdesk/src/clipboard.rs",
        "service": repository / "Vendor/rustdesk/src/server/clipboard_service.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "provider": repository
        / "Vendor/rustdesk/libs/clipboard/src/platform/unix/macos/item_data_provider.rs",
        "context": repository
        / "Vendor/rustdesk/libs/clipboard/src/platform/unix/macos/pasteboard_context.rs",
        "observer": repository
        / "Vendor/rustdesk/libs/clipboard/src/platform/unix/macos/paste_observer.rs",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
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

    design = sources["design"]
    cargo = sources["cargo"]
    clipboard = sources["clipboard"]
    service = sources["service"]
    connection = sources["connection"]
    provider = sources["provider"]
    context = sources["context"]
    observer = sources["observer"]
    patch = sources["patch"]

    cleanup_call = "crate::clipboard::clear_native_host_clipboard_transient_state();"
    provider_finish = "unsafe fn pasteboardFinishedWithDataProvider"
    evidence = {
        "designRecordsBoundedH6Step": all(
            marker in design
            for marker in (
                "H6.2f temporary clipboard object",
                "Viewer small-text clipboard API contract",
            )
        ),
        "smallTextCacheAndContextAreCleared": all(
            marker in clipboard
            for marker in (
                "fn clear_native_host_clipboard_transient_state()",
                "*LAST_MULTI_CLIPBOARDS.lock().unwrap() = MultiClipboards::new();",
                "CLIPBOARD_CTX.lock().unwrap().take();",
            )
        ),
        "dormantRichContextIsDestroyed": all(
            marker in clipboard
            for marker in (
                '#[cfg(feature = "unix-file-copy-paste")]',
                "clipboard::ContextSend::enable(false);",
            )
        ),
        "lastListenerExitCleansTransientState": (
            "clipboard_listener::unsubscribe(&sp.name());" in service
            and cleanup_call in service
            and service.find(cleanup_call)
            > service.find("clipboard_listener::unsubscribe(&sp.name());")
        ),
        "revokeAndExactRemoteTeardownCleanState": (
            connection.count(cleanup_call) == 3
            and "if !enabled" in connection
            and "if holds_native_remote_lease" in connection
            and "native_host_holds_remote_lease_through_cleanup" in connection
        ),
        "providerUsesOfficialFinishCallback": all(
            marker in provider
            for marker in (
                "#[method(pasteboardFinishedWithDataProvider:)]",
                provider_finish,
                "self.ivars().lifecycle.finish();",
            )
        ),
        "finishedProviderCannotCreateObjects": (
            provider.count("lifecycle.is_finished()") >= 2
            and "std::fs::remove_file(&path).ok();" in provider
        ),
        "temporaryCreationIsExclusiveAndFailureSafe": all(
            marker in provider
            for marker in (
                ".create_new(true)",
                "fn send_provider_task(",
                "if tx.send(Ok(task_info)).is_err()",
                "std::fs::remove_file(source_path).ok();",
                "failed to fulfill pasteboard file URL promise",
            )
        ),
        "newerLocalPasteboardOwnershipIsPreserved": all(
            marker in context
            for marker in (
                "promised_change_count: Option<NSInteger>",
                "self.promised_change_count = Some(self.pasteboard.changeCount());",
                "fn should_clear_promised_pasteboard(",
                "promised_change_count == Some(current_change_count)",
            )
        ),
        "contextStopAndDropDrainOwnedWork": all(
            marker in context
            for marker in (
                "impl Drop for PasteboardContext",
                "self.empty_clipboard_(0);",
                "self.paste_task.lock().unwrap().cancel();",
                "PASTE_OBSERVER_INFO.lock().unwrap().take();",
                "tx_handle.handle.join().ok();",
                "remove_file_handle.join().ok();",
            )
        ),
        "observerStopClearsWorkerVisibleState": (
            "self.observer_info.lock().unwrap().take();" in observer
            and "self.observer_info = Default::default();" not in observer
        ),
        "regressionsCoverCleanupAndOwnership": all(
            marker in (clipboard + provider + context)
            for marker in (
                "native_clipboard_transient_cleanup_drops_cached_payload_and_context",
                "provider_lifecycle_finishes_once_and_stays_finished",
                "closed_provider_channel_removes_unclaimed_temporary_file",
                "promised_pasteboard_cleanup_preserves_newer_owner",
            )
        ),
        "trackedPatchCarriesEveryRuntimeLayer": all(
            marker in patch
            for marker in (
                "diff --git a/libs/clipboard/src/platform/unix/macos/item_data_provider.rs",
                "diff --git a/libs/clipboard/src/platform/unix/macos/pasteboard_context.rs",
                "diff --git a/src/server/clipboard_service.rs",
                cleanup_call,
            )
        ),
        "richClipboardRemainsOutsideProductFeatureSet": (
            'rdn-native-host = ["scrap/rdn-native-host"]' in cargo
            and 'unix-file-copy-paste = [' in cargo
            and 'config::Config::set_option(key.to_owned(), "N".to_owned())'
            in sources["bridge"]
        ),
    }
    source_lines = {
        "designMilestone": line_number(design, "H6.2f temporary clipboard object"),
        "cacheCleanup": line_number(
            clipboard, "fn clear_native_host_clipboard_transient_state()"
        ),
        "serviceCleanup": line_number(service, cleanup_call),
        "revokeCleanup": line_number(connection, cleanup_call),
        "remoteTeardown": line_number(connection, "if holds_native_remote_lease"),
        "providerFinish": line_number(provider, provider_finish),
        "providerGate": line_number(provider, "lifecycle.is_finished()"),
        "exclusiveCreate": line_number(provider, ".create_new(true)"),
        "failedSendCleanup": line_number(provider, "fn send_provider_task("),
        "ownershipGuard": line_number(context, "fn should_clear_promised_pasteboard("),
        "contextDrop": line_number(context, "impl Drop for PasteboardContext"),
        "removeThreadJoin": line_number(context, "remove_file_handle.join().ok();"),
        "observerReset": line_number(
            observer, "self.observer_info.lock().unwrap().take();"
        ),
        "trackedProviderPatch": line_number(
            patch,
            "diff --git a/libs/clipboard/src/platform/unix/macos/item_data_provider.rs",
        ),
        "defaultOffGate": line_number(
            sources["bridge"], "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "temporary-clipboard-objects-cleaned-on-teardown"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-temporary-clipboard-object-provider-teardown",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "smallTextTransientCacheCleared": True,
            "promiseProviderTeardownImplemented": True,
            "newerLocalClipboardPreserved": True,
            "richClipboardEnabledByDefault": False,
            "filePromiseCompiledInCurrentProduct": False,
        },
        "remainingBoundary": {
            "viewerSmallTextClipboardAPIRequired": True,
            "explicitProductEnablementRequired": True,
            "richPayloadTransferRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "viewer-small-text-clipboard-api-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "temporary-clipboard-objects-cleaned-on-teardown" else 1


if __name__ == "__main__":
    raise SystemExit(main())
