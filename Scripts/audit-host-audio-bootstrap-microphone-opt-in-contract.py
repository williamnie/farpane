#!/usr/bin/env python3
"""Audit H6.1c Host audio bootstrap and microphone opt-in ownership."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-audio-bootstrap-microphone-opt-in-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "configuration": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "builder": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "coordinator": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapPublicationCoordinator.swift",
        "integration": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapProductIntegration.swift",
        "routing": repository
        / "Sources/CoreBridge/HostAgentBackgroundHomeRoutingPolicy.swift",
        "owner": repository
        / "Sources/CoreBridge/HostMicrophoneAuthorizationOwner.swift",
        "authority": repository
        / "Sources/RustDeskNative/HostMicrophoneAuthorizationAuthority.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository
        / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "info": repository / "App/Info.plist",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "viewer": repository / "Sources/CoreBridge/CoreBridge.swift",
        "configuration_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapConfigurationTests.swift",
        "preparation_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapPreparationTests.swift",
        "coordinator_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapPublicationCoordinatorTests.swift",
        "integration_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapProductIntegrationTests.swift",
        "owner_tests": repository
        / "Tests/CoreBridgeTests/HostMicrophoneAuthorizationOwnerTests.swift",
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
    app = sources["app"]
    home = sources["home"]
    authority = sources["authority"]
    agent = sources["agent"]
    tests = "".join(
        sources[name]
        for name in (
            "configuration_tests",
            "preparation_tests",
            "coordinator_tests",
            "integration_tests",
            "owner_tests",
            "routing_tests",
        )
    )
    evidence = {
        "designRecordsBoundedHostMicrophoneOptIn": all(
            marker in sources["design"]
            for marker in (
                "H6.1c Host audio bootstrap and microphone opt-in contract",
                "viewer-audio-explicit-policy-abi-contract",
            )
        ),
        "schemaSixCarriesStrictDefaultOffAudioPolicy": all(
            marker in configuration
            for marker in (
                "public static let currentSchemaVersion = 6",
                "public static let disabled = Self(enabled: false)",
                'Set(audio.keys) == Set(["enabled"])',
                'let enabled = strictBool(audio["enabled"])',
                "if schemaVersion <= 5",
                "audioPolicy = .disabled",
            )
        ),
        "canonicalProjectionAndRevisionCarryAudioPolicy": all(
            marker in sources["builder"] + sources["coordinator"]
            for marker in (
                "audioPolicy: HostAgentAudioPolicy = .disabled",
                '"audio": [',
                '"enabled": audioPolicy.enabled',
                "audioPolicy: audioPolicy",
                "desiredAtCurrentRevision == existing",
            )
        ),
        "productIntegrationDefaultsOffAndForwardsExplicitPolicy": all(
            marker in sources["integration"]
            for marker in (
                "audioPolicy: HostAgentAudioPolicy = .disabled",
                "audioPolicy: audioPolicy",
            )
        ),
        "homeOwnsExplicitDefaultOffMicrophoneToggle": all(
            marker in home
            for marker in (
                "var audioEnabled: Bool = false",
                "远程音频（默认关闭）",
                "允许远端收听本机麦克风",
                "onHostAudioToggle",
                "snapshot.host.allowsAudioPolicyChange",
            )
        ),
        "mainAppOwnsPromptAndEnablesOnlyAfterObservedAuthorization": all(
            marker in app
            for marker in (
                "farpane.host.audio.enabled",
                "handleHostAudioPolicyToggle",
                ".requestAuthorization",
                "guard status == .authorized,",
                "enableHostAudioAfterAuthorization()",
                "audioPolicy: currentHostAudioPolicy()",
            )
        ),
        "authorizationOwnerSerializesAndReobservesTCC": all(
            marker in sources["owner"]
            for marker in (
                "guard !requestPending else",
                "operations.requestAccess",
                "let observed = self.operations.observe()",
                "completion(observed)",
            )
        ),
        "productAdapterHasUsageDescriptionAndStableTCCIdentity": all(
            marker in authority + sources["info"]
            for marker in (
                "AVCaptureDevice.requestAccess(",
                "AVCaptureDevice.authorizationStatus(for: .audio)",
                "NSMicrophoneUsageDescription",
                "RustDeskNative",
                "io.rustdesknative.viewer",
            )
        ),
        "hostAgentNeverPromptsAndRechecksAuthorization": (
            "configuration.audioPolicy.enabled" in agent
            and "isAuthorizedWithoutPrompt()" in agent
            and "requestAuthorization" not in agent
            and "AVCaptureDevice.requestAccess" not in agent
        ),
        "policyMutationRequiresHostOffNoViewerAndNoPrompt": all(
            marker in sources["routing"] + app
            for marker in (
                "allowsAudioPolicyChange(",
                "authorizationRequestInProgress",
                "!authorizationRequestInProgress",
                "viewerConnectionInProgress: activeAttemptID != nil",
            )
        ),
        "backgroundAndLegacyHostUseSameEffectivePolicy": (
            app.count("audioPolicy: currentHostAudioPolicy()") >= 1
            and "let audioPolicy = currentHostAudioPolicy()" in app
            and "audioEnabled: audioPolicy.enabled" in app
            and "configuration.audioPolicy.enabled" in agent
        ),
        "coreHostDefaultsOffWhileViewerRemainsOff": (
            "audioEnabled: Bool = false" in sources["host_control"]
            and "receiveAudio" not in sources["viewer"]
        ),
        "focusedRegressionCoversSchemaPromptAndBothOwners": all(
            marker in tests
            for marker in (
                "testSchemaFivePreservesFileTransferAndDisablesAudio",
                "testBuildsExplicitAudioProjection",
                "testAudioPolicyChangesAdvanceRevisionAndRemainExact",
                "testReconcilesExplicitAudioPolicyIntoCanonicalProjection",
                "testOnlyNotDeterminedStatusAdmitsOneRequest",
                "testBackendBooleanCannotOverrideObservedDeniedStatus",
                "testAudioPolicyChangesRequireHostOffNoViewerAndNoAuthorizationRequest",
                "testMicrophoneOptInPromptsOnlyFromHomeAndBothHostOwnersFailClosed",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.1c Host audio bootstrap and microphone opt-in contract",
        ),
        "bootstrapSchema": line_number(
            configuration, "public static let currentSchemaVersion = 6"
        ),
        "legacyAudioMigration": line_number(
            configuration, "if schemaVersion <= 5"
        ),
        "projection": line_number(sources["builder"], '"audio": ['),
        "publication": line_number(
            sources["coordinator"], "audioPolicy: HostAgentAudioPolicy"
        ),
        "productIntegration": line_number(
            sources["integration"], "audioPolicy: HostAgentAudioPolicy"
        ),
        "homeToggle": line_number(home, "远程音频（默认关闭）"),
        "appToggle": line_number(app, "handleHostAudioPolicyToggle"),
        "tccOwner": line_number(
            sources["owner"], "package final class HostMicrophoneAuthorizationOwner"
        ),
        "tccAdapter": line_number(authority, "AVCaptureDevice.requestAccess("),
        "usageDescription": line_number(
            sources["info"], "NSMicrophoneUsageDescription"
        ),
        "agentGate": line_number(agent, "isAuthorizedWithoutPrompt()"),
        "legacyProjection": line_number(app, "audioEnabled: audioPolicy.enabled"),
        "routingGate": line_number(
            sources["routing"], "allowsAudioPolicyChange("
        ),
        "ownerRegression": line_number(
            sources["owner_tests"], "testOnlyNotDeterminedStatusAdmitsOneRequest"
        ),
        "productRegression": line_number(
            sources["routing_tests"],
            "testMicrophoneOptInPromptsOnlyFromHomeAndBothHostOwnersFailClosed",
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_source_lines = [
        name for name, source_line in source_lines.items() if source_line == 0
    ]
    healthy = not missing_evidence and not missing_source_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "host-audio-bootstrap-microphone-opt-in-ready"
            if healthy
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing_evidence,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "claims": {
            "hostAudioEnabledByDefault": False,
            "explicitHomeMicrophoneOptInImplemented": True,
            "mainAppOwnsPromptingAuthorization": True,
            "hostAgentNeverPromptsForMicrophone": True,
            "backgroundHostProjectionImplemented": True,
            "legacyHostProjectionImplemented": True,
            "viewerAudioImplemented": False,
            "virtualAudioInputSelectionImplemented": False,
            "installedAudioAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "viewer-audio-explicit-policy-abi-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
