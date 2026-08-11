#!/usr/bin/env python3
"""Audit H6.1 development completion without claiming installed audio acceptance."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-audio-product-development-completion-audit"
OWNERSHIP_SCHEMA = "farpane-host-audio-product-ownership-audit"
REQUIRED_AUDITS = {
    "audit-host-audio-product-ownership.py": (
        OWNERSHIP_SCHEMA,
        "product-selector-implemented-development-audit-pending",
    ),
    "audit-host-audio-explicit-policy-abi-contract.py": (
        "farpane-host-audio-explicit-policy-abi-contract-audit",
        "host-audio-abi-capable-product-default-off",
    ),
    "audit-host-audio-bootstrap-microphone-opt-in-contract.py": (
        "farpane-host-audio-bootstrap-microphone-opt-in-contract-audit",
        "host-audio-bootstrap-microphone-opt-in-ready",
    ),
    "audit-viewer-audio-explicit-policy-abi-contract.py": (
        "farpane-viewer-audio-explicit-policy-abi-contract-audit",
        "viewer-audio-abi-capable-product-default-off",
    ),
    "audit-viewer-audio-product-opt-in-permission-lifecycle.py": (
        "farpane-viewer-audio-product-opt-in-permission-lifecycle-audit",
        "viewer-audio-product-opt-in-permission-lifecycle-ready",
    ),
    "audit-host-virtual-audio-input-selection-abi-contract.py": (
        "farpane-host-virtual-audio-input-selection-abi-contract-audit",
        "host-virtual-audio-input-abi-capable-product-selector",
    ),
    "audit-host-audio-bootstrap-virtual-input-selection-contract.py": (
        "farpane-host-audio-bootstrap-virtual-input-selection-contract-audit",
        "host-audio-bootstrap-and-virtual-input-selection-implemented",
    ),
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def define_version(source: str, name: str) -> int:
    match = re.search(
        rf"^#define {re.escape(name)} (\d+)u$",
        source,
        re.MULTILINE,
    )
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def run_required_audits(repository: Path) -> dict[str, dict[str, object]]:
    documents: dict[str, dict[str, object]] = {}
    for script, (schema, status) in REQUIRED_AUDITS.items():
        completed = subprocess.run(
            ["python3", f"Scripts/{script}"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        document = json.loads(completed.stdout)
        if (
            completed.returncode != 0
            or not isinstance(document, dict)
            or document.get("schema") != schema
            or document.get("status") != status
            or document.get("missingEvidence") != []
            or document.get("missingSourceLines") not in (None, [])
        ):
            raise ValueError(f"required audio audit failed: {script}")
        documents[script] = document
    return documents


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "audio_service": repository / "Vendor/rustdesk/src/server/audio_service.rs",
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "client_io": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "host_swift": repository / "Sources/CoreBridge/HostControlClient.swift",
        "viewer_swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "viewer_owner": repository / "Sources/CoreBridge/ViewerAudioSessionOwner.swift",
        "bootstrap": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "projection": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapProjectionBuilder.swift",
        "input_catalog": repository
        / "Sources/RustDeskNative/HostAudioInputDeviceCatalog.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "bootstrap_tests": repository
        / "Tests/ConnectionCatalogTests/HostAgentBootstrapConfigurationTests.swift",
        "microphone_tests": repository
        / "Tests/CoreBridgeTests/HostMicrophoneAuthorizationOwnerTests.swift",
        "viewer_audio_tests": repository
        / "Tests/CoreBridgeTests/ViewerAudioSessionOwnerTests.swift",
        "home_tests": repository
        / "Tests/CoreBridgeTests/HostAgentBackgroundHomeRoutingPolicyTests.swift",
        "bridge_tests": repository
        / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
    }
    evidence_paths = tuple(
        repository / "Evidence/HostMode/2026-08-11" / name
        for name in (
            "h6-host-audio-product-ownership-audit.md",
            "h6-host-audio-explicit-policy-abi-contract.md",
            "h6-host-audio-bootstrap-microphone-opt-in-contract.md",
            "h6-viewer-audio-explicit-policy-abi-contract.md",
            "h6-viewer-audio-product-opt-in-permission-lifecycle.md",
            "h6-host-virtual-audio-input-selection-abi-contract.md",
            "h6-host-audio-bootstrap-virtual-input-selection-contract.md",
        )
    )
    try:
        sources = {name: read(path) for name, path in paths.items()}
        audits = run_required_audits(repository)
        viewer_abi = define_version(sources["header"], "RDN_ABI_VERSION")
        host_abi = define_version(sources["header"], "RDN_HOST_ABI_VERSION")
    except (
        OSError,
        UnicodeError,
        ValueError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    ownership = audits["audit-host-audio-product-ownership.py"]
    ownership_evidence = ownership.get("evidence", {})
    ownership_source_lines = ownership.get("sourceLines", {})
    ownership_passes = (
        isinstance(ownership_evidence, dict)
        and bool(ownership_evidence)
        and all(ownership_evidence.values())
        and isinstance(ownership_source_lines, dict)
        and bool(ownership_source_lines)
        and all(ownership_source_lines.values())
        and ownership.get("gaps") == {}
        and ownership.get("missingGaps") == []
    )
    host_policy = all(
        marker in sources["host_bridge"] + sources["host_swift"]
        + sources["connection"]
        for marker in (
            "enable_audio",
            "audioEnabled: Bool = false",
            "native_host_audio_option(audio_enabled)",
            "self.audio && !self.disable_audio",
            "NativeSessionCommand::DisableAudio",
        )
    )
    microphone = all(
        marker in sources["bootstrap"] + sources["projection"]
        + sources["home"] + sources["app"] + sources["agent"]
        for marker in (
            "public static let currentSchemaVersion = 7",
            "public let audioPolicy: HostAgentAudioPolicy",
            '"enabled": audioPolicy.enabled',
            "远程音频（默认关闭）",
            "farpane.host.audio.enabled",
            "isAuthorizedWithoutPrompt()",
        )
    )
    viewer_policy = all(
        marker in sources["viewer_bridge"] + sources["viewer_swift"]
        + sources["viewer_owner"] + sources["home"] + sources["app"]
        for marker in (
            "receive_audio",
            "receiveAudio: Bool = false",
            "CoreRemotePermissionEvent",
            "ViewerAudioSessionOwner",
            "本次连接接收远端音频（默认关闭，断开后重置）",
            "receiveAudio: viewerSessionReceiveAudio",
        )
    )
    playback_gate = all(
        marker in sources["viewer_bridge"] + sources["client"]
        + sources["client_io"]
        for marker in (
            "emit_remote_audio_permission",
            "native_viewer_audio_is_active",
            "native_viewer_set_remote_audio_permission",
            "MediaData::AudioFormat",
            "MediaData::AudioFrame",
            "MediaData::Reset",
        )
    )
    virtual_input = all(
        marker in sources["host_bridge"] + sources["audio_service"]
        + sources["input_catalog"] + sources["home"] + sources["app"]
        + sources["agent"]
        for marker in (
            "valid_native_host_audio_input_device(",
            "native_explicit_audio_input_is_available",
            "kAudioHardwarePropertyDevices",
            "kAudioDevicePropertyScopeInput",
            "系统默认麦克风",
            "onHostAudioInputSelection",
            "不会回退默认麦克风",
            "audioInputDeviceName: audioPolicy.inputDeviceName",
            "configuration.audioPolicy.inputDeviceName",
        )
    )
    data_plane = (
        "RDNAudio" not in sources["header"]
        and "AudioCallback" not in sources["header"]
        and "Encoder::new(sample_rate, encode_channel, LowDelay)"
        in sources["audio_service"]
        and "AudioDecoder::new" in sources["client"]
    )
    regressions = all(
        marker in sources["bootstrap_tests"] + sources["microphone_tests"]
        + sources["viewer_audio_tests"] + sources["home_tests"]
        + sources["bridge_tests"]
        for marker in (
            "testSchemaSixPreservesAudioAndMigratesToDefaultInput",
            "testAudioInputPolicyIsStrictAndFailClosed",
            "testAudioInputCatalogOnlyExposesValidUniqueExactNames",
            "testOnlyNotDeterminedStatusAdmitsOneRequest",
            "testOptInTracksDeniedReceivingRevokedAndRegrant",
            "testEpochMismatchAndTerminalEventsFailClosed",
            "testAudioPolicyChangesRequireHostOffNoViewerAndNoAuthorizationRequest",
            "testViewerAudioPolicyDefaultsOffAndRemainsIndependent",
        )
    )
    evidence = {
        "designDefinesIndependentDefaultOffOptionalAudioBoundary": all(
            marker in sources["design"]
            for marker in (
                "音频、剪贴板和文件传输采用独立功能开关和阶段门禁",
                "H6.1 音频：麦克风采集为原生主路",
                "第三方虚拟设备（如 BlackHole）可选路径",
                "H6.1h Host audio product development completion audit",
            )
        ),
        "allStagedAudioAuditsPass": len(audits) == len(REQUIRED_AUDITS),
        "ownershipAuditPassesWithoutDevelopmentGaps": ownership_passes,
        "hostDefaultOffPolicyApprovalAndRevocationImplemented": host_policy,
        "microphoneTCCBootstrapAndHomeOptInImplemented": microphone,
        "viewerDefaultOffOptInAndPermissionOwnerImplemented": viewer_policy,
        "viewerPlaybackIntersectsLocalAndRemotePermission": playback_gate,
        "virtualInputSelectionAndDriftFailClosedImplemented": virtual_input,
        "audioPayloadAndCodecRemainInPinnedRustDataPlane": data_plane,
        "focusedRegressionsCoverEveryProductBoundary": regressions,
        "abiVersionsMatchImplementedContract": viewer_abi == 18 and host_abi == 19,
        "stagedEvidenceChainExists": all(path.is_file() for path in evidence_paths),
    }
    source_lines = {
        "designRequirement": line_number(
            sources["design"], "H6.1 音频：麦克风采集为原生主路"
        ),
        "designCompletion": line_number(
            sources["design"],
            "H6.1h Host audio product development completion audit",
        ),
        "hostPolicyABI": line_number(sources["header"], "enable_audio;"),
        "hostPolicyOwner": line_number(
            sources["host_bridge"], "native_host_audio_option(audio_enabled)"
        ),
        "microphoneBootstrap": line_number(
            sources["bootstrap"], "public let audioPolicy: HostAgentAudioPolicy"
        ),
        "viewerPolicyABI": line_number(sources["header"], "receive_audio;"),
        "viewerPermissionOwner": line_number(
            sources["viewer_owner"], "public final class ViewerAudioSessionOwner"
        ),
        "viewerPlaybackGate": line_number(
            sources["client"], "native_viewer_audio_is_active"
        ),
        "virtualInputFallback": line_number(
            sources["audio_service"], "native_explicit_audio_input_is_available"
        ),
        "coreAudioCatalog": line_number(
            sources["input_catalog"], "kAudioHardwarePropertyDevices"
        ),
        "homeHostAudio": line_number(
            sources["home"], "远程音频（默认关闭）"
        ),
        "homeVirtualInput": line_number(
            sources["home"], "private let hostAudioInputPopup"
        ),
        "hostAgentProjection": line_number(
            sources["agent"], "configuration.audioPolicy.inputDeviceName"
        ),
        "legacyHostProjection": line_number(
            sources["app"], "audioInputDeviceName: audioPolicy.inputDeviceName"
        ),
        "bootstrapRegression": line_number(
            sources["bootstrap_tests"],
            "testAudioInputPolicyIsStrictAndFailClosed",
        ),
        "viewerRegression": line_number(
            sources["viewer_audio_tests"],
            "testOptInTracksDeniedReceivingRevokedAndRegrant",
        ),
    }
    remaining_gaps = [name for name, present in evidence.items() if not present]
    complete = not remaining_gaps and all(source_lines.values())
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "product-development-complete" if complete else "audit-failed",
        "coverageScope": "h6-1-audio-product-development-completion",
        "currentABI": {"viewer": viewer_abi, "host": host_abi},
        "requiredAudits": sorted(REQUIRED_AUDITS),
        "evidence": evidence,
        "sourceLines": source_lines,
        "claims": {
            "hostAudioProductImplemented": host_policy and microphone,
            "viewerAudioProductImplemented": viewer_policy and playback_gate,
            "virtualInputProductSelectorImplemented": virtual_input,
            "audioProductDevelopmentComplete": complete,
            "installedCurrentBuildSingleMacSmokeComplete": False,
            "dualMacAudioAcceptanceComplete": False,
            "virtualAudioDeviceAutoInstalled": False,
        },
        "remainingDevelopmentGaps": remaining_gaps,
        "nonBlockingAcceptanceGaps": [
            "installedCurrentBuildSingleMacDeviceEnumerationAndTCC",
            "defaultMicrophoneCaptureAndPlayback",
            "virtualInputSystemAudioCaptureAndPlayback",
            "remotePermissionDenialAndRevocation",
            "deviceDisappearanceDuringLiveSession",
            "dualMacLatencyCPUAndInteroperability",
        ],
        "nextImplementationBoundary": "host-mode-development-completion-audit",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
