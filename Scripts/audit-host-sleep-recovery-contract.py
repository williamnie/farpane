#!/usr/bin/env python3
"""Audit the implemented Host sleep/recovery ABI without mutating it."""

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
        "upstream": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "snapshot": repository / "Sources/CoreBridge/HostControlClient.swift",
        "projection": repository / "Sources/CoreBridge/HostAgentSnapshotState.swift",
        "xpc": repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift",
        "composition": (
            repository
            / "Sources/RustDeskNative/HostAgentSleepWakeRecoveryComposition.swift"
        ),
        "recovery_owner": (
            repository / "Sources/CoreBridge/HostAgentSleepWakeRecoveryOwner.swift"
        ),
        "core_runtime": repository / "Sources/CoreBridge/HostAgentCoreRuntime.swift",
        "owned_runtime": (
            repository / "Sources/CoreBridge/HostAgentOwnedCoreRuntime.swift"
        ),
        "registration_polling": (
            repository
            / "Sources/CoreBridge/HostAgentRegistrationRecoveryPollingOwner.swift"
        ),
        "process": repository / "Sources/RustDeskNative/HostAgentProcess.swift",
        "process_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentSleepWakeRecoveryProcessOwner.swift"
        ),
        "notification_delivery": (
            repository
            / "Sources/CoreBridge/HostAgentSleepWakeNotificationDeliveryOwner.swift"
        ),
        "notification_ingress": (
            repository
            / "Sources/RustDeskNative/HostAgentNSWorkspaceSleepWakeIngress.swift"
        ),
        "process_runtime": (
            repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
        ),
        "lifetime": repository / "Sources/RustDeskNative/HostAgentProcessLifetime.swift",
        "build": repository / "Scripts/build-rust-core.sh",
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
        print(json.dumps({"schema": SCHEMA, "status": "audit-failed", "error": str(error)}))
        return 1

    sleep_symbols = (
        "rdn_host_begin_sleep",
        "rdn_host_finish_sleep",
        "rdn_host_resume_after_wake",
    )
    begin = section(
        sources["bridge"],
        'pub unsafe extern "C" fn rdn_host_begin_sleep',
        'pub unsafe extern "C" fn rdn_host_finish_sleep',
    )
    finish = section(
        sources["bridge"],
        'pub unsafe extern "C" fn rdn_host_finish_sleep',
        'pub unsafe extern "C" fn rdn_host_resume_after_wake',
    )
    resume = section(
        sources["bridge"],
        'pub unsafe extern "C" fn rdn_host_resume_after_wake',
        "fn fail_host_after_password_persistence_mismatch",
    )
    stop = section(
        sources["bridge"],
        'pub unsafe extern "C" fn rdn_host_stop',
        "fn fail_host_sleep_recovery",
    )
    evidence = {
        "sleepABIPreservedUnderHostABIV16": rust_abi == 16 and header_abi == 16,
        "snapshotSchemaV8Implemented": snapshot_schema == 8,
        "sleepSymbolsExportedEndToEnd": all(
            symbol in sources["bridge"]
            and symbol in sources["header"]
            and f'dlsym(handle, "{symbol}")' in sources["shim"]
            and f"_{symbol}" in sources["build"]
            for symbol in sleep_symbols
        ),
        "runtimeSeparatesSignalFromJoin": all(
            marker in sources["bridge"]
            for marker in (
                "fn request_stop(&self)",
                "fn join(&mut self) -> bool",
                "self.request_stop();\n        self.join()",
            )
        ),
        "beginWithdrawsWithoutTerminalSideEffects": (
            ordered(
                begin,
                "is_next_recovery_epoch",
                "HostRecoveryState::Suspending",
                'registration_status = "suspending"',
                "request_stop();",
                "emit_snapshot_changed();",
            )
            and "unbind_media_host" not in begin
            and "update_temporary_password" not in begin
            and "Config::set_option" not in begin
        ),
        "finishJoinsBeforeAssertionDropAck": ordered(
            finish,
            "runtime.join()",
            "native_host_suspend_wakelock(epoch)",
            'registration_status = "suspended"',
            "HostRecoveryState::Suspended",
        ),
        "resumeIsPendingNeverReady": (
            ordered(
                resume,
                "HostRecoveryState::Resuming",
                'registration_status = "pending"',
                "native_host_resume_wakelock(epoch)",
                "HostRuntime::start",
                "emit_snapshot_changed();",
            )
            and 'registration_status = "ready"' not in resume
        ),
        "wrongDuplicateFutureAndExhaustedEpochsFailClosed": all(
            marker in sources["bridge"]
            for marker in (
                "current.checked_add(1) == Some(requested)",
                "return RDN_HOST_ERR_STALE_EPOCH;",
                "host.recovery_epoch != epoch",
                "host.recovery_state != HostRecoveryState::Suspending",
                "host.recovery_state != HostRecoveryState::Suspended",
            )
        ),
        "wakelockThreadOwnsExactEpochSuspendAck": all(
            marker in sources["upstream"]
            for marker in (
                "enum WakeLockCommand",
                "SuspendNativeHost",
                "ResumeNativeHost",
                "ResetNativeHost",
                "NativeHostWakelockRecovery",
                "native_host_recovery.accepts_updates()",
                "acknowledgement.send(accepted)",
                "recv_timeout(std::time::Duration::from_secs(2))",
            )
        ),
        "snapshotAndXPCCarryRecoveryAuthority": all(
            marker in sources["bridge"]
            for marker in (
                'map.insert("recoveryEpoch".into()',
                'map.insert("recoveryStatus".into()',
            )
        )
        and all(
            marker in sources["snapshot"]
            for marker in (
                "public let recoveryEpoch: UInt64",
                "public let recoveryStatus: HostRecoveryStatus",
                'intValue == 8',
            )
        )
        and all(
            marker in sources["projection"]
            for marker in (
                "package let recoveryEpoch: UInt64",
                "package let recoveryStatus: HostRecoveryStatus",
            )
        )
        and all(
            marker in sources["xpc"]
            for marker in (
                '"recoveryEpoch": recoveryEpoch',
                '"recoveryStatus": recoveryStatus.rawValue',
                "guard schemaVersion == 8",
            )
        ),
        "terminalStopRemainsDistinct": (
            "unbind_media_host();" in stop
            and "password_security::update_temporary_password();" in stop
            and all(symbol not in stop for symbol in sleep_symbols)
        ),
        "swiftClientExposesTypedSleepABI": all(
            marker in sources["snapshot"]
            for marker in (
                "case sleepRecovery(HostSleepRecoveryOperation, Int32)",
                "public func beginSleep(epoch: UInt64)",
                "public func finishSleep(epoch: UInt64)",
                "public func resumeAfterWake(epoch: UInt64)",
                "guard epoch > 0",
                "rdn_shim_host_begin_sleep(library, handle, epoch)",
                "rdn_shim_host_finish_sleep(library, handle, epoch)",
                "rdn_shim_host_resume_after_wake(library, handle, epoch)",
                "readiness must converge through a later authoritative",
            )
        ),
        "registrationPollingRequiresMatchingAuthoritativeSnapshot": all(
            marker in sources["registration_polling"]
            for marker in (
                "productTimeoutMilliseconds: UInt64 = 5_000",
                "snapshot.hostInstanceId == expectedHostInstanceID",
                "snapshot.recoveryEpoch == epoch",
                "snapshot.recoveryStatus",
                'snapshot.registrationStatus == "ready"',
                "case .unavailable:",
                "return .pending",
                "case .failed, .suspending, .suspended:",
                "return .failed",
            )
        ),
        "compositionWaitsForAsynchronousRegistrationRecovery": all(
            marker in sources["recovery_owner"]
            for marker in (
                "case waitingForRegistration(epoch: UInt64)",
                "beginRegistrationRecovery: @Sendable",
                "registrationRecoveryDidComplete",
                "finishRegistrationRecovery",
            )
        )
        and all(
            marker in sources["composition"]
            for marker in (
                "registrationRecoveryOwner.start(",
                "beginRegistrationRecovery: { epoch, completion in",
                "registrationRecoveryOwner.cancelAndWait()",
            )
        )
        and "resumeRegistration" not in sources["composition"],
        "sleepABIStaysOnSingleProcessLifetime": all(
            marker in sources["core_runtime"]
            for marker in (
                "func beginSleep(epoch: UInt64) throws",
                "func finishSleep(epoch: UInt64) throws",
                "func resumeAfterWake(epoch: UInt64) throws",
                "client.beginSleep(epoch: epoch)",
                "client.finishSleep(epoch: epoch)",
                "client.resumeAfterWake(epoch: epoch)",
            )
        )
        and all(
            marker in sources["owned_runtime"]
            for marker in (
                "runtime.beginSleep(epoch: epoch)",
                "runtime.finishSleep(epoch: epoch)",
                "runtime.resumeAfterWake(epoch: epoch)",
            )
        )
        and all(
            marker in sources["process_runtime"]
            for marker in (
                "ownedRuntime.beginSleep(epoch: epoch)",
                "ownedRuntime.finishSleep(epoch: epoch)",
                "ownedRuntime.resumeAfterWake(epoch: epoch)",
            )
        )
        and all(
            marker in sources["lifetime"]
            for marker in (
                "gate.withRunningRuntime",
                "runtime.beginSleep(epoch: epoch)",
                "runtime.finishSleep(epoch: epoch)",
                "runtime.resumeAfterWake(epoch: epoch)",
            )
        )
        and all(
            marker in sources["composition"]
            for marker in (
                "lifetime.beginSleep(epoch: epoch)",
                "lifetime.finishSleep(epoch: epoch)",
                "lifetime.resumeAfterWake(epoch: epoch)",
                "lifetime.copySnapshot()",
            )
        )
        and all(
            marker in sources["recovery_owner"]
            for marker in (
                "self.operations.withdrawAvailability(epoch)",
                "self.operations.releaseSleepAssertion(epoch)",
                "self.operations.publishAvailable(epoch)",
            )
        ),
        "recoveryProjectionIsSerializedAndExactEpoch": all(
            marker in sources["projection"]
            for marker in (
                "package func publishRecoverySnapshot(",
                "while refreshing && !cancelled",
                "snapshot.hostInstanceId != expectedHostInstanceID",
                "snapshot.recoveryEpoch == epoch",
                "snapshot.recoveryStatus == recoveryStatus",
                "snapshot.registrationStatus == registrationStatus",
                "finishExclusiveRefresh(",
                "requireIdentityInvalidation(.copyFailed)",
            )
        ),
        "processOwnsRecoveryCompositionBeforeListener": all(
            marker in sources["process_owner"]
            for marker in (
                "HostAgentSleepWakeRecoveryComposition(",
                "HostAgentDisplayTCCRecoveryAuthority.makeProduct()",
                "snapshotCoordinator.publishRecoverySnapshot(",
                "recoveryStatus: .suspending",
                'registrationStatus: "suspending"',
                "recoveryStatus: .running",
                'registrationStatus: "ready"',
                "composition?.cancel()",
            )
        )
        and ordered(
            sources["process"],
            "mediaPipelineOwner.start(",
            "sleepWakeRecoveryOwner.install(",
            "pollingOwner.start()",
            "lifetime.activateXPCListener()",
        )
        and ordered(
            sources["process"],
            "sleepWakeRecoveryOwner.cancelAndWait()",
            "mediaState.cancelAndWait()",
            "mediaPipelineOwner.cancelAndWait()",
            "pollingOwner.cancel()",
        ),
        "processOwnsSerializedSystemSleepWakeIngress": all(
            marker in sources["notification_delivery"]
            for marker in (
                "case preparingForSleep",
                "case recoveringFromSleep",
                "guard !deliveryInFlight",
                "transitionForAcceptedEvent(event)",
                "while deliveryInFlight",
                "state = .cancelled",
            )
        )
        and all(
            marker in sources["notification_ingress"]
            for marker in (
                "NSWorkspace.shared.notificationCenter",
                "NSWorkspace.willSleepNotification",
                "NSWorkspace.didWakeNotification",
                "Thread { [weak self] in",
                "RunLoop.current.add(keepAlivePort",
                "CFRunLoopRun()",
                "removeObservers(tokens)",
                "deliveryOwner.cancelAndWait()",
                "CFRunLoopStop(runLoop)",
                "CFRunLoopWakeUp(runLoop)",
                "case .failed = deliveryOwner.stateSnapshot()",
                "requestProcessTermination()",
            )
        )
        and all(
            marker in sources["process_owner"]
            for marker in (
                "HostAgentNSWorkspaceSleepWakeIngress.makeProduct(",
                "guard notificationIngress.start()",
                "notificationIngress?.cancelAndWait()",
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    result = {
        "schema": SCHEMA,
        "schemaVersion": 8,
        "status": "contract-implemented" if not missing else "audit-failed",
        "implementation": {
            "hostABIVersion": rust_abi,
            "snapshotSchemaVersion": snapshot_schema,
            "symbols": list(sleep_symbols),
            "evidence": evidence,
            "sourceLines": {
                "beginSleep": line_number(sources["bridge"], sleep_symbols[0]),
                "finishSleep": line_number(sources["bridge"], sleep_symbols[1]),
                "resumeAfterWake": line_number(sources["bridge"], sleep_symbols[2]),
                "wakelockCommand": line_number(sources["upstream"], "enum WakeLockCommand"),
                "snapshotRecoveryEpoch": line_number(
                    sources["bridge"], 'map.insert("recoveryEpoch".into()'
                ),
                "swiftBeginSleep": line_number(
                    sources["snapshot"], "public func beginSleep(epoch: UInt64)"
                ),
                "registrationPolling": line_number(
                    sources["registration_polling"],
                    "package final class HostAgentRegistrationRecoveryPollingOwner",
                ),
                "lifetimeBeginSleep": line_number(
                    sources["lifetime"], "func beginSleep(epoch: UInt64) throws"
                ),
                "recoveryProjection": line_number(
                    sources["projection"], "package func publishRecoverySnapshot("
                ),
                "processRecoveryOwner": line_number(
                    sources["process_owner"],
                    "final class HostAgentSleepWakeRecoveryProcessOwner",
                ),
                "systemSleepWakeIngress": line_number(
                    sources["notification_ingress"],
                    "final class HostAgentNSWorkspaceSleepWakeIngress",
                ),
            },
        },
        "remainingBoundary": {
            "realMacSleepWakeLifecycleEvidenceRequired": True,
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
