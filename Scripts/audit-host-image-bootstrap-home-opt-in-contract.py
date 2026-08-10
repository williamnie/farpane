#!/usr/bin/env python3
"""Audit the H6.2k5 Host image bootstrap and Home opt-in contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-image-bootstrap-home-opt-in-contract-audit"


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
        "viewer_control": repository / "Sources/CoreBridge/CoreBridge.swift",
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
                "H6.2k5 Host image bootstrap and Home opt-in contract",
                "host-image-clipboard-installed-two-mac-acceptance",
            )
        ),
        "bootstrapV4CarriesSixIndependentDirections": all(
            marker in bootstrap
            for marker in (
                "public static let currentSchemaVersion = 4",
                "public let allowRemoteImageRead: Bool",
                "public let allowRemoteImageWrite: Bool",
                '"allowRemoteImageRead", "allowRemoteImageWrite"',
            )
        ),
        "legacySchemasKeepNewerFormatsDisabled": all(
            marker in bootstrap
            for marker in (
                "if schemaVersion == 1",
                "clipboardPolicy = .disabled",
                "if schemaVersion == 2",
                "allowRemoteRichTextRead = false",
                "if schemaVersion <= 3",
                "allowRemoteImageRead = false",
                "allowRemoteImageWrite = false",
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
        "projectionAndRevisionIncludeImagePolicy": all(
            marker in builder + coordinator
            for marker in (
                '"allowRemoteImageRead":',
                '"allowRemoteImageWrite":',
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
        "sixPreferencesAreIndependentAndAbsentMeansOff": all(
            marker in app
            for marker in (
                "farpane.host.clipboard.allowRemoteRead",
                "farpane.host.clipboard.allowRemoteWrite",
                "farpane.host.clipboard.richText.allowRemoteRead",
                "farpane.host.clipboard.richText.allowRemoteWrite",
                "farpane.host.clipboard.image.allowRemoteRead",
                "farpane.host.clipboard.image.allowRemoteWrite",
                "allowRemoteImageRead ?? current.allowRemoteImageRead",
                "allowRemoteImageWrite ?? current.allowRemoteImageWrite",
            )
        ),
        "homeShowsExplicitBoundedImageDirections": all(
            marker in home
            for marker in (
                "图片（RGBA/PNG 最多 128 MiB，SVG 最多 4 MiB）",
                "允许远端读取本机图片",
                "允许远端写入图片到本机",
                "onHostClipboardImageReadToggle",
                "onHostClipboardImageWriteToggle",
            )
        ),
        "policyChangesReuseHostOffRepublishGate": (
            "allowsClipboardPolicyChange(" in routing
            and "&& !control.isOn" in routing
            and "&& !viewerConnectionInProgress" in routing
            and "guard HostAgentBackgroundHomeRoutingPolicy" in app
            and "reconcileHostAgentBootstrap()" in app
        ),
        "backgroundAndLegacyOwnersUseAllSixDirections": all(
            marker in app + agent
            for marker in (
                "clipboardPolicy: currentHostClipboardPolicy()",
                "clipboardImageReadEnabled:",
                "clipboardImageWriteEnabled:",
                ".allowRemoteImageRead",
                ".allowRemoteImageWrite",
            )
        ),
        "coreDefaultsRemainClosed": all(
            marker in sources["host_control"]
            for marker in (
                "clipboardImageReadEnabled: Bool = false",
                "clipboardImageWriteEnabled: Bool = false",
            )
        ),
        "viewerProductDirectionsAreExplicitlyEnabled": all(
            marker in app + sources["viewer_control"]
            for marker in (
                "receiveClipboardImage: Bool = false",
                "sendClipboardImage: Bool = false",
                "receiveClipboardImage: true",
                "sendClipboardImage: true",
            )
        ),
        "regressionsCoverMigrationRevisionProjectionAndRoutes": all(
            marker in tests
            for marker in (
                "testSchemaThreePreservesTextAndDisablesImage",
                "testSchemaThreePublicationUpgradesWithImageDisabled",
                "testClipboardPolicyChangesAdvanceRevisionAndRemainDirectional",
                "testReconcilesExplicitClipboardPolicyIntoCanonicalProjection",
                "testClipboardPolicyChangesRequireInteractiveHostOffAndNoViewerStart",
                "testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection",
            )
        ),
        "documentationRecordsExplicitHostImageOptIn": all(
            marker in docs
            for marker in (
                "bootstrap schema v4",
                "RGBA/PNG",
                "six independent",
                "off by default",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.2k5 Host image bootstrap and Home opt-in contract",
        ),
        "bootstrapSchema": line_number(
            bootstrap, "public static let currentSchemaVersion = 4"
        ),
        "imagePolicyField": line_number(
            bootstrap, "public let allowRemoteImageRead: Bool"
        ),
        "schemaThreeMigration": line_number(
            bootstrap, "if schemaVersion <= 3"
        ),
        "strictBoolean": line_number(bootstrap, "private static func strictBool"),
        "projection": line_number(builder, '"allowRemoteImageRead":'),
        "revisionComparison": line_number(
            coordinator, "desiredAtCurrentRevision == existing"
        ),
        "imageReadPreference": line_number(
            app, "farpane.host.clipboard.image.allowRemoteRead"
        ),
        "homeImageReadSwitch": line_number(home, "允许远端读取本机图片"),
        "homeImageWriteSwitch": line_number(home, "允许远端写入图片到本机"),
        "policyRoute": line_number(routing, "allowsClipboardPolicyChange("),
        "agentProjection": line_number(agent, "clipboardImageReadEnabled:"),
        "legacyProjection": line_number(app, "clipboardImageReadEnabled:"),
        "migrationTest": line_number(
            sources["coordinator_tests"],
            "testSchemaThreePublicationUpgradesWithImageDisabled",
        ),
        "routeTest": line_number(
            sources["routing_tests"],
            "testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection",
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-image-bootstrap-home-opt-in-ready"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-image-bootstrap-home-opt-in",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "legacyConfigurationEnablesImage": False,
            "hostImageEnabledByDefault": False,
            "independentHostImageOptInAvailable": True,
            "endToEndImageExplicitOptInCapable": True,
            "svgSanitizedForRendering": False,
            "filePromiseClipboardEnabled": False,
        },
        "remainingBoundary": {
            "installedTwoMacImageClipboardAcceptanceRequired": True,
            "physicalOwnershipAndTeardownAcceptanceRequired": True,
            "physicalLatencyAndIdleCPUAcceptanceRequired": True,
            "filePromiseImplementationRequired": True,
        },
        "nextImplementationBoundary": (
            "host-image-clipboard-installed-two-mac-acceptance"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-image-bootstrap-home-opt-in-ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
