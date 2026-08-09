#!/usr/bin/env python3
"""Audit the pinned Host sleep/recovery ABI baseline without mutating it."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SCHEMA = "farpane-host-sleep-recovery-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def version(pattern: str, source: str, label: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing {label}")
    return int(match.group(1))


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    bridge_path = repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs"
    header_path = repository / "CoreBridge/include/rustdesk_native.h"
    upstream_path = repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch"
    composition_path = (
        repository
        / "Sources/RustDeskNative/HostAgentSleepWakeRecoveryComposition.swift"
    )
    try:
        bridge = read(bridge_path)
        header = read(header_path)
        upstream = read(upstream_path)
        composition = read(composition_path)
        rust_abi = version(
            r"const HOST_ABI_VERSION: u32 = (\d+);",
            bridge,
            "Rust Host ABI version",
        )
        header_abi = version(
            r"#define RDN_HOST_ABI_VERSION (\d+)u",
            header,
            "C Host ABI version",
        )
        snapshot_schema = version(
            r"const SNAPSHOT_SCHEMA_VERSION: u32 = (\d+);",
            bridge,
            "snapshot schema version",
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({"schema": SCHEMA, "status": "audit-failed", "error": str(error)}))
        return 1

    sleep_symbols = (
        "rdn_host_begin_sleep",
        "rdn_host_finish_sleep",
        "rdn_host_resume_after_wake",
    )
    stop_start = bridge.find("pub unsafe extern \"C\" fn rdn_host_stop")
    stop_end = bridge.find("\nfn fail_host_after_password_persistence_mismatch", stop_start)
    stop_body = bridge[stop_start:stop_end] if stop_start >= 0 and stop_end > stop_start else ""
    evidence = {
        "hostABIV7Baseline": rust_abi == 7 and header_abi == 7,
        "snapshotSchemaV5Baseline": snapshot_schema == 5,
        "sleepABISurfaceAbsent": all(
            symbol not in bridge and symbol not in header for symbol in sleep_symbols
        ),
        "runtimeHasOnlyTerminalStop": (
            "fn stop(&mut self) -> bool" in bridge
            and "fn suspend(&mut self)" not in bridge
            and "fn resume(&mut self)" not in bridge
        ),
        "terminalStopUnbindsMediaAndSession": (
            "unbind_media_host();" in stop_body
            and 'reset_native_session_broker("hostStopped")' in bridge
        ),
        "terminalStopRotatesTemporaryPassword": (
            "password_security::update_temporary_password();" in stop_body
        ),
        "registrationRefreshHasNoSuspendedState": (
            "if !matches!(self.state, RdnHostState::Starting | RdnHostState::Ready)"
            in bridge
        ),
        "wakelockOwnedByAuthenticatedConnectionRAII": all(
            marker in upstream
            for marker in (
                "fn incoming_wakelock_display(",
                "fn start_wakelock_thread()",
                "fn check_wake_lock()",
                "impl Drop for AuthedConnID",
                "Self::check_wake_lock();",
            )
        ),
        "wakelockHasNoHostSuspendAck": (
            "NativeHostWakeLockCommand" not in upstream
            and "rdn_host_finish_sleep" not in upstream
        ),
        "compositionRegistrationIsSynchronous": all(
            marker in composition
            for marker in (
                "let resumeRegistration: @Sendable () -> Bool",
                "let publishAvailable: @Sendable () -> Bool",
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "contract-gap-confirmed" if not missing else "audit-failed",
        "baseline": {
            "hostABIVersion": rust_abi,
            "snapshotSchemaVersion": snapshot_schema,
            "evidence": evidence,
            "sourceLines": {
                "hostRuntimeStart": line_number(bridge, "fn start(rendezvous_server: String)"),
                "hostRuntimeStop": line_number(bridge, "fn stop(&mut self) -> bool"),
                "hostStopABI": line_number(
                    bridge, 'pub unsafe extern "C" fn rdn_host_stop'
                ),
                "wakelockPolicyPatch": line_number(
                    upstream, "fn incoming_wakelock_display("
                ),
                "authenticatedConnectionDropPatch": line_number(
                    upstream, "impl Drop for AuthedConnID"
                ),
            },
        },
        "requiredContract": {
            "targetHostABIVersion": 8,
            "targetSnapshotSchemaVersion": 6,
            "symbols": list(sleep_symbols),
            "epoch": "strictly increasing UInt64; wrong, stale, duplicate, or exhausted fails closed",
            "beginSleep": (
                "withdraw registration and publish suspending for the accepted epoch; "
                "signal mediator exit without unbinding media/session, rotating passwords, "
                "or changing identity/config"
            ),
            "finishSleep": (
                "same epoch only; join the registration runtime, force the Rust-owned "
                "wakelock to drop, and wait for its acknowledgement before suspended"
            ),
            "resumeAfterWake": (
                "same epoch only; restart registration and return accepted/pending, never ready"
            ),
            "registrationConvergence": (
                "publish available only after an authoritative ready snapshot for the exact epoch"
            ),
            "assertionOwnership": (
                "remain in the authenticated-connection Rust wakelock thread; no Swift assertion"
            ),
            "snapshotFields": ["recoveryEpoch", "recoveryStatus", "registrationStatus"],
            "terminalStop": "unchanged and distinct from sleep recovery",
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
