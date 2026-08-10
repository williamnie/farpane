#!/usr/bin/env python3
"""Audit the H6.2e event-first clipboard and macOS fallback backoff contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-event-backoff-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "clipboard": repository / "Vendor/rustdesk/src/clipboard.rs",
        "service": repository
        / "Vendor/rustdesk/src/server/clipboard_service.rs",
        "cargo": repository / "Vendor/rustdesk/Cargo.toml",
        "lock": repository / "Vendor/rustdesk/Cargo.lock",
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
    clipboard = sources["clipboard"]
    service = sources["service"]
    patch = sources["patch"]
    event_branch = service.find("Ok(CallbackResult::Next) => {")
    clipboard_read = service.find("handler.get_clipboard_msg()", event_branch)
    timeout_branch = service.find("Err(RecvTimeoutError::Timeout) => {}")
    callback_branch = clipboard.find(
        "fn on_clipboard_change(&mut self) -> CallbackResult"
    )
    activity_reset = clipboard.find(
        "self.fallback_backoff.reset();", callback_branch
    )
    event_broadcast = clipboard.find(
        "tx.send(CallbackResult::Next).ok();", activity_reset
    )

    evidence = {
        "designRecordsBoundedH6Step": all(
            marker in design
            for marker in (
                "H6.2e event-first clipboard listener",
                "temporary clipboard object cleanup contract",
            )
        ),
        "macFallbackIsHostFeatureScoped": clipboard.count(
            '#[cfg(all(target_os = "macos", feature = "rdn-native-host"))]'
        ) >= 7,
        "fallbackBoundsAreExplicit": all(
            marker in clipboard
            for marker in (
                "NATIVE_CLIPBOARD_FALLBACK_MIN_INTERVAL_MS: u64 = 125",
                "NATIVE_CLIPBOARD_FALLBACK_MAX_INTERVAL_MS: u64 = 4_000",
                ".saturating_mul(2)",
                ".min(NATIVE_CLIPBOARD_FALLBACK_MAX_INTERVAL_MS)",
            )
        ),
        "listenerSuppliesDynamicFallbackInterval": all(
            marker in clipboard
            for marker in (
                "impl ClipboardHandler for Handler",
                "fn sleep_interval(&self) -> core::time::Duration",
                "self.fallback_backoff.next_wait()",
            )
        ),
        "activityResetsBeforeEventBroadcast": (
            callback_branch >= 0
            and activity_reset > callback_branch
            and event_broadcast > activity_reset
        ),
        "serviceReadsOnlyFromListenerEventBranch": (
            event_branch >= 0
            and clipboard_read > event_branch
            and timeout_branch > clipboard_read
            and service.count("handler.get_clipboard_msg()") == 1
        ),
        "serviceTimeoutDoesNotPollClipboard": (
            "Err(RecvTimeoutError::Timeout) => {}" in service
            and "match rx_cb_result.recv_timeout" in service
        ),
        "unsubscribeWakesAndJoinsListener": all(
            marker in clipboard
            for marker in (
                "tx.send(CallbackResult::Stop).ok();",
                "shutdown.signal();",
                "h.join().ok();",
            )
        ),
        "backoffAndCallbackRegressionTestsExist": all(
            marker in clipboard
            for marker in (
                "native_clipboard_fallback_backoff_is_bounded_and_exponential",
                "native_clipboard_activity_resets_listener_fallback_backoff",
                "[125, 250, 500, 1_000, 2_000, 4_000, 4_000]",
            )
        ),
        "clipboardMasterContractIsPinned": (
            'clipboard-master = { git = "https://github.com/rustdesk-org/clipboard-master" }'
            in sources["cargo"]
            and "clipboard-master#7762d74e38db37cfeb6ded88c964b9cdbddfb6db"
            in sources["lock"]
        ),
        "trackedPatchCarriesExactImplementation": all(
            marker in patch
            for marker in (
                "diff --git a/src/clipboard.rs b/src/clipboard.rs",
                "NATIVE_CLIPBOARD_FALLBACK_MIN_INTERVAL_MS: u64 = 125",
                "native_clipboard_activity_resets_listener_fallback_backoff",
            )
        ),
        "clipboardProductDefaultRemainsOff": all(
            marker in sources["bridge"]
            for marker in (
                "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS",
                "config::keys::OPTION_ENABLE_CLIPBOARD",
                'config::Config::set_option(key.to_owned(), "N".to_owned())',
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.2e event-first clipboard listener"
        ),
        "minimumInterval": line_number(
            clipboard, "NATIVE_CLIPBOARD_FALLBACK_MIN_INTERVAL_MS: u64 = 125"
        ),
        "maximumInterval": line_number(
            clipboard, "NATIVE_CLIPBOARD_FALLBACK_MAX_INTERVAL_MS: u64 = 4_000"
        ),
        "backoffAdvance": line_number(clipboard, ".saturating_mul(2)"),
        "activityReset": line_number(
            clipboard, "self.fallback_backoff.reset();"
        ),
        "dynamicSleepInterval": line_number(
            clipboard, "fn sleep_interval(&self) -> core::time::Duration"
        ),
        "eventBranch": line_number(service, "Ok(CallbackResult::Next) => {"),
        "timeoutBranch": line_number(
            service, "Err(RecvTimeoutError::Timeout) => {}"
        ),
        "boundedBackoffTest": line_number(
            clipboard,
            "native_clipboard_fallback_backoff_is_bounded_and_exponential",
        ),
        "callbackResetTest": line_number(
            clipboard,
            "native_clipboard_activity_resets_listener_fallback_backoff",
        ),
        "defaultOffGate": line_number(
            sources["bridge"], "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS"
        ),
        "trackedPatch": line_number(
            patch, "diff --git a/src/clipboard.rs b/src/clipboard.rs"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "event-first-bounded-macos-fallback"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-event-first-bounded-macos-fallback",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "listenerEventPathIsPrimary": True,
            "macFallbackBackoffIsBounded": True,
            "activityResetsFallbackBackoff": True,
            "nonHostUpstreamBehaviorChanged": False,
            "clipboardEnabledByDefault": False,
        },
        "remainingBoundary": {
            "temporaryObjectCleanupRequired": False,
            "explicitProductEnablementRequired": True,
            "viewerClipboardAPIRequired": False,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "viewer-pasteboard-owner-and-explicit-enablement-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "event-first-bounded-macos-fallback" else 1


if __name__ == "__main__":
    raise SystemExit(main())
