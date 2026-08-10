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
        "preflight": repository / "Scripts/preflight-host-mode-h1-golden.sh",
        "snapshot": repository / "Sources/CoreBridge/HostControlClient.swift",
        "poller": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryPollingOwner.swift"
        ),
        "trigger": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryTriggerOwner.swift"
        ),
        "composition": (
            repository
            / "Sources/RustDeskNative/HostAgentNetworkPathRecoveryComposition.swift"
        ),
        "process_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentNetworkPathRecoveryProcessOwner.swift"
        ),
        "delivery": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathDeliveryOwner.swift"
        ),
        "ingress": (
            repository
            / "Sources/RustDeskNative/HostAgentNWPathMonitorIngress.swift"
        ),
        "process": repository / "Sources/RustDeskNative/HostAgentProcess.swift",
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
    network_recovery = section(
        bridge,
        "fn fail_host_network_recovery",
        "fn fail_host_sleep_recovery",
    )

    evidence = {
        "hostABIV13AndSnapshotV8PreserveNetworkRecovery": (
            rust_abi == 13 and header_abi == 13 and snapshot_schema == 8
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
        "targetOperationIsExportedEndToEnd": (
            target_symbol in sources["bridge"]
            and target_symbol in sources["header"]
            and f'"{target_symbol}"' in sources["shim"]
            and "host_recover_network_path =" in sources["shim"]
            and f"_{target_symbol}" in sources["build"]
            and f"_{target_symbol}" in sources["preflight"]
        ),
        "networkGenerationIsSeparateAndResetPerHostStart": all(
            marker in bridge
            for marker in (
                "network_path_generation: u64",
                "network_path_generation: 0",
                "host.network_path_generation = 0;",
                "fn is_next_network_path_generation",
            )
        ),
        "admissionIsExactNextAndSleepIndependent": all(
            marker in network_recovery
            for marker in (
                "host.recovery_state != HostRecoveryState::Running",
                "RdnHostState::Starting | RdnHostState::Ready",
                "host.runtime.is_none()",
                "is_next_network_path_generation(",
                "return RDN_HOST_ERR_STALE_GENERATION;",
            )
        ),
        "restartRetiresOldOnlineStateBeforeReplacement": ordered(
            network_recovery,
            "host.network_path_generation = path_generation;",
            'host.registration_status = "pending";',
            "host.state = RdnHostState::Starting;",
            "runtime.stop()",
            "HostRuntime::start(host.rendezvous_server.clone())",
            "host.emit_snapshot_changed();",
            "RDN_HOST_OK",
        ),
        "restartPreservesIdentityMediaPasswordSleepAndRouteEpochs": all(
            marker not in network_recovery
            for marker in (
                "Config::set_option",
                "host.local_id =",
                "unbind_media_host",
                "bind_media_host",
                "update_temporary_password",
                "set_permanent_password",
                "host.recovery_epoch =",
                "native_host_suspend_wakelock",
                "native_host_resume_wakelock",
                "connection_epoch =",
                "codec_epoch =",
                "display_revision =",
            )
        ),
        "runtimeFailuresAreTerminalRegistrationOnly": all(
            marker in network_recovery
            for marker in (
                'host.registration_status = "degraded";',
                "host.recovery_state = HostRecoveryState::Running;",
                "host.state = RdnHostState::Error;",
                "registration.runtimeJoinFailedDuringNetworkRecovery",
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            )
        ),
        "swiftClientExposesTypedNetworkRecovery": all(
            marker in sources["snapshot"]
            for marker in (
                "case networkPathRecovery(Int32)",
                "public var networkPathRecoveryFailure:",
                "public func recoverNetworkPath(generation: UInt64) throws",
                "rdn_shim_host_recover_network_path(",
                "RDN_HOST_ERR_STALE_GENERATION",
                "Acceptance is",
                "pending only",
            )
        ),
        "swiftPollingPinsHostAndSleepEpochBeforeOneRestart": all(
            marker in sources["poller"]
            for marker in (
                "productIntervalMilliseconds: UInt64 = 50",
                "productMaximumAttempts: UInt64 = 100",
                "productTimeoutMilliseconds: UInt64 = 5_000",
                "baselineRecoveryEpoch(",
                "snapshot.hostInstanceId == expectedHostInstanceID",
                "snapshot.recoveryEpoch == recoveryEpoch",
                "snapshot.recoveryStatus == .running",
                '("starting", "pending")',
                '("ready", "ready")',
                "let accepted = recover(pathGeneration)",
                "while operationInFlight || completionInFlight",
            )
        ),
        "swiftNetworkRecoveryIsComposedInProcessLifetime": (
            all(
                marker in sources["composition"]
                for marker in (
                    "HostAgentNetworkPathRecoveryPollingOwner.makeProduct(",
                    "HostAgentNetworkPathRecoveryTriggerOwner {",
                    "lifetime.recoverNetworkPath(",
                    "return .snapshot(try lifetime.copySnapshot())",
                    "snapshotCoordinator.requestPoll()",
                    "lifetime?.requestTermination(reason: .error)",
                    "triggerOwner.cancelAndWait()",
                    "pollingOwner.cancelAndWait()",
                )
            )
            and all(
                marker in sources["process_owner"]
                for marker in (
                    "HostAgentNetworkPathRecoveryComposition(",
                    "guard state == .installed",
                    "composition?.cancelAndWait()",
                )
            )
            and all(
                marker in sources["process"]
                for marker in (
                    "HostAgentNetworkPathRecoveryProcessOwner()",
                    "networkPathRecoveryOwner.install(",
                    "networkPathRecoveryOwner.cancelAndWait()",
                )
            )
        ),
        "productNWPathMonitorIsStrictAndProcessOwned": (
            all(
                marker in sources["ingress"]
                for marker in (
                    "monitor: NWPathMonitor()",
                    "monitor.pathUpdateHandler = { [weak self] path in",
                    "monitor.start(queue: queue)",
                    "switch path.status",
                    "path.usesInterfaceType(interface.type)",
                    "monitor.pathUpdateHandler = nil",
                    "monitor.cancel()",
                    "deliveryOwner.cancelAndWait()",
                )
            )
            and all(
                marker in sources["delivery"]
                for marker in (
                    "case accepted",
                    "case rejected",
                    "case closed",
                    "while deliveryInFlight",
                )
            )
            and all(
                marker in sources["process_owner"]
                for marker in (
                    "HostAgentNWPathMonitorIngress.makeProduct(",
                    "guard pathIngress.start()",
                    "pathIngress?.cancelAndWait()",
                    "composition?.cancelAndWait()",
                )
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    target_contract = {
        "hostABIVersion": 13,
        "snapshotSchemaVersion": 8,
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
        "schemaVersion": 5,
        "status": "contract-implemented" if not missing else "audit-failed",
        "implementation": {
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
                "networkRestart": line_number(
                    bridge,
                    'pub unsafe extern "C" fn rdn_host_recover_network_path',
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
            "realNetworkSwitchEvidenceRequired": True,
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
