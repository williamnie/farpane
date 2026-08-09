#!/usr/bin/env python3
"""Audit the bounded Host network-path recovery trigger contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


SCHEMA = "farpane-host-network-path-recovery-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    owner_path = (
        repository
        / "Sources/CoreBridge/HostAgentNetworkPathRecoveryTriggerOwner.swift"
    )
    paths = {
        "owner": owner_path,
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "poller": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryPollingOwner.swift"
        ),
        "core_runtime": (
            repository / "Sources/CoreBridge/HostAgentCoreRuntime.swift"
        ),
        "owned_runtime": (
            repository / "Sources/CoreBridge/HostAgentOwnedCoreRuntime.swift"
        ),
        "process_runtime": (
            repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
        ),
        "lifetime": (
            repository / "Sources/RustDeskNative/HostAgentProcessLifetime.swift"
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
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    owner = sources["owner"]
    evidence = {
        "initialUsablePathOnlyEstablishesBaseline": all(
            marker in owner
            for marker in (
                "case baselineEstablished",
                "case awaitingInitialPath(pathGeneration: UInt64)",
                "return .baselineEstablished",
            )
        ),
        "outageAndMaterialPathChangeTriggerRecovery": all(
            marker in owner
            for marker in (
                "case waitingForUsablePath(",
                "path.recoveryIdentity != currentPath.recoveryIdentity",
                "return triggerRecovery(",
                "case recoveryTriggered(pathGeneration: UInt64)",
            )
        ),
        "usablePathRequiresInterfaceAndIPAddressFamily": all(
            marker in owner
            for marker in (
                "availability == .satisfied",
                "interfaceKinds.contains { $0 != .loopback }",
                "(supportsIPv4 || supportsIPv6)",
                "case invalidSatisfiedPath",
            )
        ),
        "pathGenerationIsExactMonotonicAndExhaustionSafe": all(
            marker in owner
            for marker in (
                "guard previousGeneration < UInt64.max",
                "let pathGeneration = previousGeneration + 1",
                "case generationExhausted",
                "pathGeneration: pathGeneration",
            )
        ),
        "rejectedAndConcurrentTriggersFailClosed": all(
            marker in owner
            for marker in (
                "guard !operationInFlight",
                "case triggerRejected",
                "case .triggering, .failed, .cancelling, .cancelled:",
                "return .rejected",
            )
        ),
        "terminalCancellationDrainsAcceptedTrigger": all(
            marker in owner
            for marker in (
                "state = .cancelling",
                "while operationInFlight",
                "state = .cancelled",
                "condition.broadcast()",
            )
        ),
        "hostCoreNetworkRecoveryOperationImplemented": (
            "rdn_host_recover_network_path" in sources["header"]
            and "rdn_host_recover_network_path" in sources["bridge"]
        ),
        "swiftReadyConvergenceImplemented": all(
            marker in sources["poller"]
            for marker in (
                "baselineRecoveryEpoch(",
                "snapshot.hostInstanceId == expectedHostInstanceID",
                "snapshot.recoveryEpoch == recoveryEpoch",
                "snapshot.recoveryStatus == .running",
                "productTimeoutMilliseconds: UInt64 = 5_000",
            )
        ),
        "sameLifetimeOperationPropagated": (
            "client.recoverNetworkPath(generation: generation)"
            in sources["core_runtime"]
            and "runtime.recoverNetworkPath(generation: generation)"
            in sources["owned_runtime"]
            and "ownedRuntime.recoverNetworkPath(generation: generation)"
            in sources["process_runtime"]
            and "runtime.recoverNetworkPath(generation: generation)"
            in sources["lifetime"]
        ),
        "productCompositionOwnsTriggerAndConvergence": (
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
            and "HostAgentNetworkPathRecoveryComposition("
            in sources["process_owner"]
            and "networkPathRecoveryOwner.install("
            in sources["process"]
            and "networkPathRecoveryOwner.cancelAndWait()"
            in sources["process"]
        ),
        "productNWPathIngressNormalizesAndDrains": (
            all(
                marker in sources["ingress"]
                for marker in (
                    "import Network",
                    "monitor: NWPathMonitor()",
                    "monitor.pathUpdateHandler = { [weak self] path in",
                    "monitor.start(queue: queue)",
                    "switch path.status",
                    "path.availableInterfaces.compactMap",
                    "path.usesInterfaceType(interface.type)",
                    "supportsIPv4: path.supportsIPv4",
                    "supportsIPv6: path.supportsIPv6",
                    "supportsDNS: path.supportsDNS",
                    "isExpensive: path.isExpensive",
                    "isConstrained: path.isConstrained",
                    "monitor.pathUpdateHandler = nil",
                    "monitor.cancel()",
                    "deliveryOwner.cancelAndWait()",
                )
            )
            and "currentPath" not in sources["ingress"]
            and all(
                marker in sources["delivery"]
                for marker in (
                    "case accepted",
                    "case rejected",
                    "case closed",
                    "while deliveryInFlight",
                    "state = .cancelled",
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
    result = {
        "schema": SCHEMA,
        "schemaVersion": 5,
        "status": "trigger-contract-implemented" if not missing else "audit-failed",
        "implementation": {
            "evidence": evidence,
            "sourceLines": {
                "snapshot": line_number(
                    owner,
                    "package struct HostAgentNetworkPathSnapshot",
                ),
                "owner": line_number(
                    owner,
                    "package final class HostAgentNetworkPathRecoveryTriggerOwner",
                ),
                "consume": line_number(owner, "package func consume("),
                "cancellation": line_number(owner, "package func cancelAndWait()"),
            },
        },
        "integrationBoundary": {
            "hostCoreNetworkRecoveryOperationImplemented": (
                "rdn_host_recover_network_path" in sources["header"]
                and "rdn_host_recover_network_path" in sources["bridge"]
            ),
            "swiftReadyConvergenceImplemented": all(
                marker in sources["poller"]
                for marker in (
                    "baselineRecoveryEpoch(",
                    "snapshot.recoveryEpoch == recoveryEpoch",
                    "productTimeoutMilliseconds: UInt64 = 5_000",
                )
            ),
            "productNetworkRecoveryCompositionImplemented": (
                "HostAgentNetworkPathRecoveryPollingOwner.makeProduct("
                in sources["composition"]
                and "HostAgentNetworkPathRecoveryTriggerOwner {"
                in sources["composition"]
                and "networkPathRecoveryOwner.install("
                in sources["process"]
            ),
            "productNWPathMonitorAdapterImplemented": (
                "NWPathMonitor()" in sources["ingress"]
                and "HostAgentNWPathMonitorIngress.makeProduct("
                in sources["process_owner"]
            ),
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
