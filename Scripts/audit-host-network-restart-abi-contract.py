#!/usr/bin/env python3
"""Freeze the next HostCore network-path registration restart ABI contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SCHEMA = "farpane-host-network-restart-abi-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def version(pattern: str, source: str, label: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing {label}")
    return int(match.group(1))


def section(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset <= start_offset:
        return ""
    return source[start_offset:end_offset]


def ordered(source: str, *markers: str) -> bool:
    offset = 0
    for marker in markers:
        found = source.find(marker, offset)
        if found < 0:
            return False
        offset = found + len(marker)
    return True


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "build": repository / "Scripts/build-rust-core.sh",
        "snapshot": repository / "Sources/CoreBridge/HostControlClient.swift",
        "trigger": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryTriggerOwner.swift"
        ),
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        rust_abi = version(
            r"const HOST_ABI_VERSION: u32 = (\d+);",
            sources["bridge"],
            "Rust Host ABI version",
        )
        header_abi = version(
            r"#define RDN_HOST_ABI_VERSION (\d+)u",
            sources["header"],
            "C Host ABI version",
        )
        snapshot_schema = version(
            r"const SNAPSHOT_SCHEMA_VERSION: u32 = (\d+);",
            sources["bridge"],
            "snapshot schema version",
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    bridge = sources["bridge"]
    runtime = section(bridge, "impl HostRuntime {", "impl RdnHost {")
    host_start = section(
        bridge,
        'pub unsafe extern "C" fn rdn_host_start',
        'pub unsafe extern "C" fn rdn_host_stop',
    )
    host_stop = section(
        bridge,
        'pub unsafe extern "C" fn rdn_host_stop',
        "fn fail_host_sleep_recovery",
    )
    sleep = section(
        bridge,
        'pub unsafe extern "C" fn rdn_host_begin_sleep',
        "fn fail_host_after_password_persistence_mismatch",
    )
    target_symbol = "rdn_host_recover_network_path"

    evidence = {
        "currentHostABIV8AndSnapshotV6ArePinned": (
            rust_abi == 8 and header_abi == 8 and snapshot_schema == 6
        ),
        "runtimeOwnsOnlyBoundedRegistrationRestartPrimitives": (
            ordered(
                runtime,
                "fn start(rendezvous_server: String)",
                "prepare_native_host_runtime();",
                "fn request_stop(&self)",
                "stop_native_host_runtime();",
                "fn join(&mut self) -> bool",
                "config::Config::reset_online();",
            )
            and "unbind_media_host" not in runtime
            and "update_temporary_password" not in runtime
            and "native_host_suspend_wakelock" not in runtime
        ),
        "sameHostRetainsRegistrationConfigurationAndIdentity": all(
            marker in bridge
            for marker in (
                "instance_id: String",
                "local_id: String",
                "rendezvous_server: String",
                "relay_server: String",
                "server_public_key: String",
                "runtime: Option<HostRuntime>",
            )
        )
        and ordered(
            host_start,
            "host.local_id = config::Config::get_id();",
            "HostRuntime::start(host.rendezvous_server.clone())",
            'host.registration_status = "pending"',
        ),
        "terminalStopCannotBeReusedForPathRecovery": (
            "unbind_media_host();" in host_stop
            and "password_security::update_temporary_password();" in host_stop
            and 'host.registration_status = "notStarted"' in host_stop
        ),
        "sleepRecoveryCannotOwnPathGeneration": all(
            marker in sleep
            for marker in (
                "host.recovery_epoch = epoch",
                "native_host_suspend_wakelock(epoch)",
                "native_host_resume_wakelock(epoch)",
            )
        ),
        "swiftSnapshotCanRepresentPendingReadyAndTerminalNetworkFailure": all(
            marker in sources["snapshot"]
            for marker in (
                "case running",
                "let registrationStatus = json[\"registrationStatus\"] as? String",
                "case .running:\n            recoveryContractIsValid = true",
                "case .failed:",
                'registrationStatus == "degraded"',
            )
        ),
        "pathGenerationAlreadyHasSeparateExactMonotonicAuthority": all(
            marker in sources["trigger"]
            for marker in (
                "guard previousGeneration < UInt64.max",
                "let pathGeneration = previousGeneration + 1",
                "trigger(pathGeneration, path)",
            )
        ),
        "targetOperationIsStillAbsentEndToEnd": (
            target_symbol not in sources["bridge"]
            and target_symbol not in sources["header"]
            and target_symbol not in sources["shim"]
            and f"_{target_symbol}" not in sources["build"]
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    target_contract = {
        "hostABIVersion": 9,
        "snapshotSchemaVersion": 6,
        "symbol": target_symbol,
        "signature": "int32_t(RdnHost *, uint64_t path_generation)",
        "staleGenerationError": "RDN_HOST_ERR_STALE_GENERATION",
        "generationAuthority": "RdnHost.network_path_generation",
        "admission": [
            "pathGenerationIsExactNextAndNonZero",
            "hostStateIsStartingOrReady",
            "sleepRecoveryStatusIsRunning",
            "registrationRuntimeExists",
        ],
        "synchronousSuccessSequence": [
            "validateBeforeSideEffects",
            "commitPathGeneration",
            "publishStartingPending",
            "stopAndJoinOldRegistrationRuntime",
            "resetOldOnlineState",
            "startNewRuntimeWithPinnedRendezvousServer",
            "returnAcceptedPendingNeverReady",
        ],
        "readyConvergence": [
            "sameHostInstanceID",
            "sleepRecoveryStatusRunning",
            "registrationStatusReady",
            "boundedAuthoritativeSnapshotPolling",
        ],
        "terminalFailure": {
            "hostState": "error",
            "registrationStatus": "degraded",
            "sleepRecoveryStatus": "running",
            "lastError": [
                "registration.runtimeJoinFailedDuringNetworkRecovery",
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            ],
        },
        "forbiddenSideEffects": [
            "identityOrRegistrationConfigMutation",
            "mediaOrSessionBindUnbind",
            "temporaryOrPermanentPasswordMutation",
            "sleepRecoveryEpochOrWakelockMutation",
            "connectionCodecOrDisplayEpochMutation",
        ],
    }
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "contract-frozen" if not missing else "audit-failed",
        "baseline": {
            "hostABIVersion": rust_abi,
            "snapshotSchemaVersion": snapshot_schema,
            "evidence": evidence,
            "sourceLines": {
                "host": line_number(bridge, "pub struct RdnHost {"),
                "runtime": line_number(bridge, "impl HostRuntime {"),
                "start": line_number(
                    bridge,
                    'pub unsafe extern "C" fn rdn_host_start',
                ),
                "stop": line_number(
                    bridge,
                    'pub unsafe extern "C" fn rdn_host_stop',
                ),
                "sleep": line_number(
                    bridge,
                    'pub unsafe extern "C" fn rdn_host_begin_sleep',
                ),
                "pathTrigger": line_number(
                    sources["trigger"],
                    "package final class HostAgentNetworkPathRecoveryTriggerOwner",
                ),
            },
        },
        "targetContract": target_contract,
        "remainingBoundary": {
            "hostABIV9NetworkRestartNotImplemented": True,
            "swiftReadyConvergenceNotImplemented": True,
            "productNWPathMonitorAdapterAbsent": True,
            "realNetworkSwitchEvidenceRequired": True,
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
