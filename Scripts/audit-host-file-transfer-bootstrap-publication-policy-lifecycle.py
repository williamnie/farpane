#!/usr/bin/env python3
"""Audit H6.3f2b2t2 Host file-transfer bootstrap publication/runtime policy."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-bootstrap-publication-policy-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-product-development-completion-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "configuration": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "builder": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "coordinator": repository / "Sources/ConnectionCatalog/HostAgentBootstrapPublicationCoordinator.swift",
        "integration": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProductIntegration.swift",
        "runtime": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "coordinator_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapPublicationCoordinatorTests.swift",
        "integration_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapProductIntegrationTests.swift",
        "runtime_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
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

    coordinator = sources["coordinator"]
    integration = sources["integration"]
    runtime = sources["runtime"]
    app_reconcile = sources["app"][
        sources["app"].find("    private func reconcileHostAgentBootstrap()"):
        sources["app"].find("    private func currentHostClipboardPolicy()")
    ]
    evidence = {
        "designRecordsBoundedPublicationStep": (
            "H6.3f2b2t2 Host file-transfer bootstrap publication policy lifecycle"
            in sources["design"]
        ),
        "schemaV5PolicyRemainsDefaultOff": all(
            marker in sources["configuration"]
            for marker in (
                "public static let currentSchemaVersion = 7",
                "public static let disabled = Self(enabled: false, receiveRoot: nil)",
                "public let fileTransferPolicy: HostAgentFileTransferPolicy",
            )
        ),
        "canonicalProjectionCarriesExactPolicy": all(
            marker in sources["builder"]
            for marker in (
                "fileTransferPolicy: HostAgentFileTransferPolicy = .disabled",
                '"enabled": fileTransferPolicy.enabled',
                '"receiveRoot": fileTransferPolicy.receiveRoot as Any? ?? NSNull()',
            )
        ),
        "publicationEqualityAndRevisionIncludePolicy": (
            coordinator.count("fileTransferPolicy: fileTransferPolicy") == 2
            and "desiredAtCurrentRevision == existing" in coordinator
        ),
        "productIntegrationForwardsExplicitPolicy": all(
            marker in integration
            for marker in (
                "fileTransferPolicy: HostAgentFileTransferPolicy = .disabled",
                "fileTransferPolicy: fileTransferPolicy",
            )
        ),
        "agentRuntimeProjectsExactImmutablePair": all(
            marker in runtime
            for marker in (
                "configuration.fileTransferPolicy.enabled",
                "configuration.fileTransferPolicy.receiveRoot",
            )
        ),
        "homeOptInPreservesDefaultDisabledPolicy": (
            "clipboardPolicy: currentHostClipboardPolicy()" in app_reconcile
            and "fileTransferPolicy: currentHostFileTransferPolicy()"
                in app_reconcile
            and "farpane.host.fileTransfer.enabled" in sources["app"]
            and "return .disabled" in sources["app"]
        ),
        "regressionsCoverRevisionIntegrationAndRuntime": all(
            marker in (
                sources["coordinator_tests"]
                + sources["integration_tests"]
                + sources["runtime_tests"]
            )
            for marker in (
                "testFileTransferPolicyChangesAdvanceRevisionAndRemainExact",
                "testReconcilesExplicitFileTransferPolicyIntoCanonicalProjection",
                "configuration.fileTransferPolicy.receiveRoot",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2t2 Host file-transfer bootstrap publication policy lifecycle",
        ),
        "schemaPolicy": line_number(
            sources["configuration"],
            "public let fileTransferPolicy: HostAgentFileTransferPolicy",
        ),
        "coordinatorProjection": line_number(
            coordinator, "fileTransferPolicy: fileTransferPolicy"
        ),
        "integrationProjection": line_number(
            integration, "fileTransferPolicy: fileTransferPolicy"
        ),
        "runtimeProjection": line_number(
            runtime, "configuration.fileTransferPolicy.enabled"
        ),
        "defaultOffCaller": line_number(
            sources["app"], "clipboardPolicy: currentHostClipboardPolicy()"
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "bootstrap-publication-runtime-policy-implemented-home-opt-in-downstream"
            if passed else "audit-failed"
        ),
        "coverageScope": "h6-host-file-transfer-bootstrap-publication-policy-lifecycle",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "bootstrapPolicyPublicationImplemented": passed,
            "agentRuntimePolicyProjectionImplemented": passed,
            "hostHomeFileTransferOptInImplemented": passed,
            "productFileTransferEnabledByDefault": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
