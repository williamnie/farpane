#!/usr/bin/env python3
"""Audit H6.1g bootstrap and Home virtual-audio input selection."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-audio-bootstrap-virtual-input-selection-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(text: str, marker: str) -> int:
    offset = text.find(marker)
    return 0 if offset < 0 else text.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "configuration": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "builder": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "catalog": repository
        / "Sources/RustDeskNative/HostAudioInputDeviceCatalog.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository
        / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "configuration_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapConfigurationTests.swift",
        "routing_tests": repository
        / "Tests/CoreBridgeTests/HostAgentBackgroundHomeRoutingPolicyTests.swift",
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

    configuration = sources["configuration"]
    evidence = {
        "designRecordsBoundedH61gBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.1g Host audio bootstrap and virtual-input selection contract",
                "host-audio-product-development-completion-audit",
            )
        ),
        "schemaV7CarriesStrictOptionalExactInput": all(
            marker in configuration + sources["builder"]
            for marker in (
                "public static let currentSchemaVersion = 7",
                "public let inputDeviceName: String?",
                '"inputDeviceName":',
                "audioPolicy.inputDeviceName as Any? ?? NSNull()",
                'Set(["enabled", "inputDeviceName"])',
                "audio[\"inputDeviceName\"] is NSNull",
                "inputDeviceName as Any? ?? NSNull()",
            )
        ),
        "schemaV6MigratesToNativeSystemAudio": all(
            marker in configuration
            for marker in (
                "if schemaVersion == 6",
                "HostAgentAudioPolicy(enabled: true)",
            )
        ),
        "inputNamesAreBoundedUniqueAndNeverNormalized": all(
            marker in configuration
            for marker in (
                "value.utf8.count <= 512",
                "value == value.trimmingCharacters",
                "Dictionary(",
                "count == 1 ? name : nil",
                "public func containsUnique",
            )
        ),
        "productDiscoversRealCoreAudioInputDevices": all(
            marker in sources["catalog"]
            for marker in (
                "kAudioHardwarePropertyDevices",
                "kAudioDevicePropertyStreamConfiguration",
                "kAudioDevicePropertyScopeInput",
                "kAudioObjectPropertyName",
                "mNumberChannels > 0",
            )
        ),
        "homeExposesDefaultExactAndRefreshSelection": all(
            marker in sources["home"]
            for marker in (
                "系统音频（原生）",
                "onHostAudioInputSelection",
                "onRefreshHostAudioInputs",
                "不可用：\\(selected)",
                "不会回退系统音频",
            )
        ),
        "selectionIsMutableOnlyThroughExistingHostOffGate": all(
            marker in sources["app"]
            for marker in (
                "handleHostAudioInputSelection",
                "refreshHostAudioInputs",
                "guard hostAudioPolicyChangeAllowed()",
                "farpane.host.audio.inputDeviceName",
            )
        ),
        "missingOrAmbiguousExplicitSelectionFailsClosed": all(
            marker in sources["app"]
            for marker in (
                "catalog.containsUnique",
                "return .disabled",
                "远程音频保持关闭",
                "不会回退系统音频",
            )
        ),
        "backgroundAndLegacyOwnersReceiveSameImmutableSelection": (
            "audioInputDeviceName: audioPolicy.inputDeviceName"
            in sources["app"]
            and "configuration.audioPolicy.inputDeviceName"
            in sources["agent"]
        ),
        "regressionsCoverSchemaMigrationValidationCatalogAndProductWiring": all(
            marker in sources["configuration_tests"] + sources["routing_tests"]
            for marker in (
                "testSchemaSixPreservesAudioAndMigratesToNativeSystemAudio",
                "testAudioInputPolicyIsStrictAndFailClosed",
                "testAudioInputCatalogOnlyExposesValidUniqueExactNames",
                "farpane.host.audio.inputDeviceName",
                "configuration.audioPolicy.inputDeviceName",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.1g Host audio bootstrap and virtual-input selection contract",
        ),
        "schema": line_number(
            configuration, "public static let currentSchemaVersion = 7"
        ),
        "policy": line_number(
            configuration, "public struct HostAgentAudioPolicy"
        ),
        "catalog": line_number(
            configuration, "public struct HostAudioInputDeviceCatalog"
        ),
        "coreAudioDiscovery": line_number(
            sources["catalog"], "kAudioHardwarePropertyDevices"
        ),
        "homeSelector": line_number(
            sources["home"], "private let hostAudioInputPopup"
        ),
        "productSelection": line_number(
            sources["app"], "private func handleHostAudioInputSelection"
        ),
        "backgroundProjection": line_number(
            sources["agent"], "configuration.audioPolicy.inputDeviceName"
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_source_lines = [
        name for name, source_line in source_lines.items() if source_line <= 0
    ]
    healthy = not missing_evidence and not missing_source_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "host-audio-bootstrap-and-virtual-input-selection-implemented"
            if healthy
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing_evidence,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "claims": {
            "nativeSystemAudioIsDefaultSource": True,
            "virtualInputAutoInstalled": False,
            "missingExplicitInputFallsClosed": True,
            "dualMacAudioAcceptanceComplete": False,
            "hermesChanged": False,
        },
        "nextImplementationBoundary": (
            "host-audio-product-development-completion-audit"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
