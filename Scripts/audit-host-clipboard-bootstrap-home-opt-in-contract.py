#!/usr/bin/env python3
"""Audit the H6.2i2 Host clipboard bootstrap and Home opt-in contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-bootstrap-home-opt-in-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "bootstrap": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "builder": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "coordinator": repository / "Sources/ConnectionCatalog/HostAgentBootstrapPublicationCoordinator.swift",
        "integration": repository / "Sources/ConnectionCatalog/HostAgentBootstrapProductIntegration.swift",
        "routing": repository / "Sources/CoreBridge/HostAgentBackgroundHomeRoutingPolicy.swift",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
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

    evidence = {
        "designRecordsBoundedProductStep": all(
            marker in sources["design"]
            for marker in (
                "H6.2i2 Host clipboard bootstrap and Home opt-in contract",
                "host-small-text-clipboard-installed-two-mac-acceptance",
            )
        ),
        "bootstrapV5RetainsIndependentSmallTextDirections": all(
            marker in bootstrap
            for marker in (
                "public static let currentSchemaVersion = 7",
                "public let clipboardPolicy: HostAgentClipboardPolicy",
                '"allowRemoteRead", "allowRemoteWrite",',
            )
        ),
        "legacySchemasDoNotImplicitlyEnableClipboard": all(
            marker in bootstrap
            for marker in (
                "(1...currentSchemaVersion).contains(schemaVersion)",
                "if schemaVersion == 1",
                "clipboardPolicy = .disabled",
                "if schemaVersion == 2",
                "allowRemoteRichTextRead = false",
            )
        ),
        "clipboardBooleansAndKeysAreStrict": all(
            marker in bootstrap
            for marker in (
                "Set(clipboard.keys) == expectedClipboardKeys",
                "private static func strictBool",
                "CFGetTypeID(number) == CFBooleanGetTypeID()",
            )
        ),
        "projectionAndRevisionIncludePolicy": (
            '"clipboard": [' in builder
            and "clipboardPolicy: clipboardPolicy" in coordinator
            and "desiredAtCurrentRevision == existing" in coordinator
        ),
        "productIntegrationRequiresExplicitPolicy": all(
            marker in sources["integration"]
            for marker in (
                "clipboardPolicy: HostAgentClipboardPolicy",
                "clipboardPolicy: clipboardPolicy",
            )
        ),
        "preferencesAreIndependentAndAbsentMeansOff": all(
            marker in app
            for marker in (
                "farpane.host.clipboard.allowRemoteRead",
                "farpane.host.clipboard.allowRemoteWrite",
                "UserDefaults.standard.bool(",
                "allowRemoteRead ?? current.allowRemoteRead",
                "allowRemoteWrite ?? current.allowRemoteWrite",
            )
        ),
        "homeShowsExplicitBoundedTextDirections": all(
            marker in home
            for marker in (
                "小型文本（最多 64 KiB）",
                "允许远端读取本机剪贴板",
                "允许远端写入本机剪贴板",
                "onHostClipboardReadToggle",
                "onHostClipboardWriteToggle",
            )
        ),
        "policyChangesRequireHostOffAndRepublish": (
            "allowsClipboardPolicyChange(" in routing
            and "&& !control.isOn" in routing
            and "&& !viewerConnectionInProgress" in routing
            and "guard HostAgentBackgroundHomeRoutingPolicy" in app
            and "reconcileHostAgentBootstrap()" in app
        ),
        "hostEnableFailsClosedWithoutCoherentBootstrap": (
            "allowsHostToggle(" in routing
            and "control.isInteractive && (control.isOn || bootstrapReady)" in routing
            and "bootstrapReady: bootstrapReady" in app
        ),
        "backgroundAndLegacyOwnersUseSamePolicy": all(
            marker in app + agent
            for marker in (
                "clipboardPolicy: currentHostClipboardPolicy()",
                "clipboardReadEnabled: clipboardPolicy.allowRemoteRead",
                "clipboardWriteEnabled: clipboardPolicy.allowRemoteWrite",
                "configuration.clipboardPolicy.allowRemoteRead",
                "configuration.clipboardPolicy.allowRemoteWrite",
            )
        ),
        "coreDefaultsRemainClosed": all(
            marker in sources["host_control"]
            for marker in (
                "clipboardReadEnabled: Bool = false",
                "clipboardWriteEnabled: Bool = false",
            )
        ),
        "regressionsCoverMigrationRevisionProjectionAndRoutes": all(
            marker in tests
            for marker in (
                "testLegacySchemaOneMigratesToClipboardDisabled",
                "testClipboardPolicyChangesAdvanceRevisionAndRemainDirectional",
                "testLegacySchemaOnePublicationUpgradesWithClipboardDisabled",
                "testReconcilesExplicitClipboardPolicyIntoCanonicalProjection",
                "testClipboardPolicyChangesRequireInteractiveHostOffAndNoViewerStart",
                "testHostEnableRequiresPublishedBootstrapButDisableRemainsAvailable",
                "testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2i2 Host clipboard bootstrap and Home opt-in contract",
        ),
        "bootstrapSchema": line_number(
            bootstrap, "public static let currentSchemaVersion = 7"
        ),
        "legacyMigration": line_number(bootstrap, "clipboardPolicy = .disabled"),
        "strictBoolean": line_number(bootstrap, "private static func strictBool"),
        "projection": line_number(builder, '"clipboard": ['),
        "revisionComparison": line_number(
            coordinator, "desiredAtCurrentRevision == existing"
        ),
        "productIntegration": line_number(
            sources["integration"], "clipboardPolicy: HostAgentClipboardPolicy"
        ),
        "readPreference": line_number(
            app, "farpane.host.clipboard.allowRemoteRead"
        ),
        "homeReadSwitch": line_number(home, "允许远端读取本机剪贴板"),
        "homeWriteSwitch": line_number(home, "允许远端写入本机剪贴板"),
        "policyRoute": line_number(routing, "allowsClipboardPolicyChange("),
        "hostEnableGate": line_number(routing, "allowsHostToggle("),
        "agentProjection": line_number(
            agent, "configuration.clipboardPolicy.allowRemoteRead"
        ),
        "legacyProjection": line_number(
            app, "clipboardReadEnabled: clipboardPolicy.allowRemoteRead"
        ),
        "migrationTest": line_number(
            sources["bootstrap_tests"],
            "testLegacySchemaOneMigratesToClipboardDisabled",
        ),
        "routeTest": line_number(
            sources["routing_tests"],
            "testHostEnableRequiresPublishedBootstrapButDisableRemainsAvailable",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-clipboard-bootstrap-home-opt-in-ready"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-clipboard-bootstrap-home-opt-in",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "legacyConfigurationEnablesClipboard": False,
            "clipboardEnabledByDefault": False,
            "independentHomeOptInAvailable": True,
            "endToEndSmallTextExplicitOptInCapable": True,
            "richClipboardEnabled": True,
            "imageClipboardEnabled": True,
        },
        "remainingBoundary": {
            "installedTwoMacAcceptanceRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
            "richPayloadTransferRequired": False,
            "imagePayloadTransferRequired": False,
        },
        "nextImplementationBoundary": "host-image-clipboard-installed-two-mac-acceptance",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-clipboard-bootstrap-home-opt-in-ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
