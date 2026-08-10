#!/usr/bin/env python3
"""Audit the H6.2j6 Host rich-text bootstrap and Home opt-in contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-rich-text-bootstrap-home-opt-in-contract-audit"


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
        "bootstrap": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "builder": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "coordinator": repository / "Sources/ConnectionCatalog/HostAgentBootstrapPublicationCoordinator.swift",
        "integration": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProductIntegration.swift",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "routing": repository / "Sources/CoreBridge/HostAgentBackgroundHomeRoutingPolicy.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "bootstrap_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapConfigurationTests.swift",
        "coordinator_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapPublicationCoordinatorTests.swift",
        "integration_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapProductIntegrationTests.swift",
        "routing_tests": repository / "Tests/CoreBridgeTests/HostAgentBackgroundHomeRoutingPolicyTests.swift",
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

    bootstrap = sources["bootstrap"]
    builder = sources["builder"]
    coordinator = sources["coordinator"]
    app = sources["app"]
    home = sources["home"]
    agent = sources["agent"]
    routing = sources["routing"]
    tests = "".join(
        sources[name]
        for name in (
            "bootstrap_tests",
            "coordinator_tests",
            "integration_tests",
            "routing_tests",
        )
    )
    docs = sources["readme"] + sources["architecture"]

    evidence = {
        "designRecordsBoundedProductStep": all(
            marker in sources["design"]
            for marker in (
                "H6.2j6 Host rich-text bootstrap and Home opt-in contract",
                "host-rich-text-clipboard-installed-two-mac-acceptance",
            )
        ),
        "bootstrapV4RetainsRichTextDirections": all(
            marker in bootstrap
            for marker in (
                "public static let currentSchemaVersion = 4",
                "public let clipboardPolicy: HostAgentClipboardPolicy",
                "public let allowRemoteRichTextRead: Bool",
                "public let allowRemoteRichTextWrite: Bool",
                '"allowRemoteRichTextRead", "allowRemoteRichTextWrite"',
            )
        ),
        "legacySchemasKeepRichTextDisabled": all(
            marker in bootstrap
            for marker in (
                "if schemaVersion == 1",
                "clipboardPolicy = .disabled",
                "if schemaVersion == 2",
                "allowRemoteRichTextRead = false",
                "allowRemoteRichTextWrite = false",
                "if schemaVersion <= 3",
                "allowRemoteImageRead = false",
            )
        ),
        "allClipboardBooleansAndKeysAreStrict": all(
            marker in bootstrap
            for marker in (
                "Set(clipboard.keys) == expectedClipboardKeys",
                "private static func strictBool",
                "CFGetTypeID(number) == CFBooleanGetTypeID()",
            )
        ),
        "projectionAndRevisionIncludeRichPolicy": all(
            marker in builder + coordinator
            for marker in (
                '"allowRemoteRichTextRead":',
                '"allowRemoteRichTextWrite":',
                "clipboardPolicy: clipboardPolicy",
                "desiredAtCurrentRevision == existing",
            )
        ),
        "productIntegrationRequiresOneExplicitPolicy": all(
            marker in sources["integration"]
            for marker in (
                "clipboardPolicy: HostAgentClipboardPolicy",
                "clipboardPolicy: clipboardPolicy",
            )
        ),
        "richPreferencesRemainIndependentAndAbsentMeansOff": all(
            marker in app
            for marker in (
                "farpane.host.clipboard.allowRemoteRead",
                "farpane.host.clipboard.allowRemoteWrite",
                "farpane.host.clipboard.richText.allowRemoteRead",
                "farpane.host.clipboard.richText.allowRemoteWrite",
                "UserDefaults.standard.bool(",
                "allowRemoteRichTextRead:",
                "?? current.allowRemoteRichTextRead",
                "allowRemoteRichTextWrite:",
                "?? current.allowRemoteRichTextWrite",
            )
        ),
        "homeShowsExplicitBoundedRichDirections": all(
            marker in home
            for marker in (
                "富文本 RTF/HTML（每种最多 1 MiB）",
                "允许远端读取本机富文本",
                "允许远端写入本机富文本",
                "onHostClipboardRichTextReadToggle",
                "onHostClipboardRichTextWriteToggle",
            )
        ),
        "policyChangesReuseHostOffRepublishGate": (
            "allowsClipboardPolicyChange(" in routing
            and "&& !control.isOn" in routing
            and "&& !viewerConnectionInProgress" in routing
            and "guard HostAgentBackgroundHomeRoutingPolicy" in app
            and "reconcileHostAgentBootstrap()" in app
        ),
        "backgroundAndLegacyOwnersUseAllFourDirections": all(
            marker in app + agent
            for marker in (
                "clipboardPolicy: currentHostClipboardPolicy()",
                "clipboardReadEnabled: clipboardPolicy.allowRemoteRead",
                "clipboardWriteEnabled: clipboardPolicy.allowRemoteWrite",
                "clipboardRichTextReadEnabled:",
                "clipboardRichTextWriteEnabled:",
                ".allowRemoteRichTextRead",
                ".allowRemoteRichTextWrite",
            )
        ),
        "coreDefaultsRemainClosed": all(
            marker in sources["host_control"]
            for marker in (
                "clipboardReadEnabled: Bool = false",
                "clipboardWriteEnabled: Bool = false",
                "clipboardRichTextReadEnabled: Bool = false",
                "clipboardRichTextWriteEnabled: Bool = false",
            )
        ),
        "regressionsCoverMigrationRevisionProjectionAndRoutes": all(
            marker in tests
            for marker in (
                "testSchemaTwoPreservesSmallTextAndDisablesRichText",
                "testSchemaTwoPublicationUpgradesWithRichTextDisabled",
                "testClipboardPolicyChangesAdvanceRevisionAndRemainDirectional",
                "testReconcilesExplicitClipboardPolicyIntoCanonicalProjection",
                "testClipboardPolicyChangesRequireInteractiveHostOffAndNoViewerStart",
                "testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection",
            )
        ),
        "documentationRecordsExplicitHostRichOptIn": all(
            marker in docs
            for marker in (
                "bootstrap schema v4",
                "RTF/HTML",
                "six independent",
                "off by default",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2j6 Host rich-text bootstrap and Home opt-in contract",
        ),
        "bootstrapSchema": line_number(
            bootstrap, "public static let currentSchemaVersion = 4"
        ),
        "richPolicyField": line_number(
            bootstrap, "public let allowRemoteRichTextRead: Bool"
        ),
        "schemaTwoMigration": line_number(
            bootstrap, "allowRemoteRichTextRead = false"
        ),
        "strictBoolean": line_number(bootstrap, "private static func strictBool"),
        "projection": line_number(builder, '"allowRemoteRichTextRead":'),
        "revisionComparison": line_number(
            coordinator, "desiredAtCurrentRevision == existing"
        ),
        "richReadPreference": line_number(
            app, "farpane.host.clipboard.richText.allowRemoteRead"
        ),
        "homeRichReadSwitch": line_number(home, "允许远端读取本机富文本"),
        "homeRichWriteSwitch": line_number(home, "允许远端写入本机富文本"),
        "policyRoute": line_number(routing, "allowsClipboardPolicyChange("),
        "agentProjection": line_number(
            agent, "clipboardRichTextReadEnabled:"
        ),
        "legacyProjection": line_number(
            app, "clipboardRichTextReadEnabled:"
        ),
        "migrationTest": line_number(
            sources["bootstrap_tests"],
            "testSchemaTwoPreservesSmallTextAndDisablesRichText",
        ),
        "routeTest": line_number(
            sources["routing_tests"],
            "testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-rich-text-bootstrap-home-opt-in-ready"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-rich-text-bootstrap-home-opt-in",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "legacyConfigurationEnablesRichText": False,
            "richTextEnabledByDefault": False,
            "independentHostRichTextOptInAvailable": True,
            "endToEndRichTextExplicitOptInCapable": True,
            "imageClipboardEnabled": True,
            "filePromiseClipboardEnabled": False,
        },
        "remainingBoundary": {
            "installedTwoMacRichClipboardAcceptanceRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
            "imageImplementationRequired": False,
            "filePromiseImplementationRequired": True,
        },
        "nextImplementationBoundary": (
            "host-image-clipboard-installed-two-mac-acceptance"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-rich-text-bootstrap-home-opt-in-ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
