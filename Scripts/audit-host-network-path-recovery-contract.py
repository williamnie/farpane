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
    rustdesk_native = repository / "Sources/RustDeskNative"
    paths = {
        "owner": owner_path,
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "poller": (
            repository
            / "Sources/CoreBridge/HostAgentNetworkPathRecoveryPollingOwner.swift"
        ),
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        product_sources = "\n".join(
            read(path) for path in sorted(rustdesk_native.glob("*.swift"))
        )
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
    }
    missing = [name for name, present in evidence.items() if not present]
    result = {
        "schema": SCHEMA,
        "schemaVersion": 3,
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
            "productNWPathMonitorAdapterAbsent": (
                "NWPathMonitor" not in product_sources
            ),
        },
        "missingEvidence": missing,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
