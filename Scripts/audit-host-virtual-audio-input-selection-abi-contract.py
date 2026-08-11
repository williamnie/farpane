#!/usr/bin/env python3
"""Audit H6.1f Host explicit audio-input ABI and fail-closed selection."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess


SCHEMA = "farpane-host-virtual-audio-input-selection-abi-contract-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(text: str, marker: str) -> int:
    offset = text.find(marker)
    return 0 if offset < 0 else text.count("\n", 0, offset) + 1


def define_version(text: str, name: str) -> int:
    match = re.search(rf"#define {name} (\d+)u", text)
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def rust_version(text: str, name: str) -> int:
    match = re.search(rf"const {name}: u32 = (\d+);", text)
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "host_swift": repository / "Sources/CoreBridge/HostControlClient.swift",
        "audio_service": repository / "Vendor/rustdesk/src/server/audio_service.rs",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-host-audio-explicit-input-fail-closed.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
        "swift_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "script_tests": repository
        / "Tests/ScriptTests/test_host_virtual_audio_input_selection_abi_contract_audit.py",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "bootstrap_config": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
    }
    try:
        verified = subprocess.run(
            [str(repository / "Scripts/verify-rustdesk-core-source.sh")],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout.strip()
        if verified != (
            "RUSTDESK_CORE_SOURCE_VERIFIED "
            f"commit={PINNED_RUSTDESK_COMMIT}"
        ):
            raise ValueError("RustDesk source verification returned an unexpected result")
        sources = {name: read(path) for name, path in paths.items()}
        host_abi = define_version(sources["header"], "RDN_HOST_ABI_VERSION")
        viewer_abi = define_version(sources["header"], "RDN_ABI_VERSION")
        bridge_abi = rust_version(sources["bridge"], "HOST_ABI_VERSION")
    except (
        OSError,
        UnicodeError,
        ValueError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    header = sources["header"]
    bridge = sources["bridge"]
    host_swift = sources["host_swift"]
    audio_service = sources["audio_service"]
    product = sources["app"] + sources["agent"] + sources["bootstrap_config"]
    start_offset = bridge.find('pub unsafe extern "C" fn rdn_host_start(')
    policy_offset = bridge.find(
        "apply_native_host_optional_capability_policy(", start_offset
    )
    identity_offset = bridge.find(
        "host.local_id = config::Config::get_id();", start_offset
    )

    evidence = {
        "designRecordsBoundedH61fBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.1f Host virtual audio input selection ABI contract",
                "host-audio-bootstrap-virtual-input-selection-contract",
            )
        ),
        "hostABIIsV19AndViewerRemainsV18": (
            host_abi == bridge_abi == 19 and viewer_abi == 18
        ),
        "cRustAndSwiftCarryOneCopiedOptionalDeviceName": all(
            marker in header + bridge + host_swift
            for marker in (
                "const char *audio_input_device;",
                "audio_input_device: *const c_char",
                "audio_input_device: String",
                "audio_input_device: audioInputDevice",
                "public let audioInputDeviceName: String?",
                "audioInputDeviceName: String? = nil",
            )
        ),
        "selectionIsBoundedAndRequiresEnabledAudio": all(
            marker in bridge
            for marker in (
                "AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES: usize = 512",
                "valid_native_host_audio_input_device(",
                "enabled\n        && device.len() <= AUDIO_INPUT_DEVICE_MAX_UTF8_BYTES",
                "device.trim() == device",
                "device.chars().any(char::is_control)",
            )
        ),
        "defaultMicrophoneIsRepresentedOnlyByEmptySelection": (
            "if device.is_empty() {\n        return true;" in bridge
            and '(configuration.audioInputDeviceName ?? "").withCString'
            in host_swift
        ),
        "selectionIsPersistedBeforeIdentityAndReadBackExactly": (
            policy_offset >= 0
            and identity_offset >= 0
            and policy_offset < identity_offset
            and '"audio-input".to_owned()' in bridge
            and '("audio-input", audio_input_device)' in bridge
        ),
        "missingExplicitInputFailsClosedWithoutDefaultFallback": all(
            marker in audio_service + sources["patch"]
            for marker in (
                "native_explicit_audio_input_is_available",
                'return Err(anyhow!("Selected audio input is unavailable"));',
                "requested.is_empty() || match_count == 1",
                "explicit_audio_input_never_falls_back_to_default",
            )
        ),
        "patchStackOwnsAndVerifiesUpstreamChange": all(
            "h6-host-audio-explicit-input-fail-closed.patch" in sources[name]
            for name in ("bootstrap", "verifier")
        ),
        "canonicalAndVendoredBridgeMatch": (
            bridge == sources["vendor_bridge"]
        ),
        "regressionsCoverDefaultExplicitInvalidAndFallbackCases": all(
            marker in bridge + audio_service + sources["swift_tests"]
            for marker in (
                "native_host_audio_input_device_is_bounded_explicit_and_default_safe",
                "explicit_audio_input_never_falls_back_to_default",
                "XCTAssertNil(disabled.audioInputDeviceName)",
                'audioInputDeviceName: "BlackHole 2ch"',
            )
        ),
        "productAndBootstrapRemainDefaultMicrophone": (
            "audioInputDeviceName:" not in product
            and '"inputDevice"' not in sources["bootstrap_config"]
            and '"audioInputDevice"' not in sources["bootstrap_config"]
        ),
        "existingRustDeskAudioWireAndPayloadOwnershipRemainUnchanged": (
            "RDNAudio" not in header
            and "AudioCallback" not in header
            and "AudioFormat" in audio_service
            and "AudioFrame" in audio_service
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.1f Host virtual audio input selection ABI contract",
        ),
        "hostABI": line_number(header, "RDN_HOST_ABI_VERSION 19u"),
        "cSelection": line_number(header, "const char *audio_input_device;"),
        "rustSelectionCopy": line_number(
            bridge, "audio_input_device: (*options).audio_input_device"
        ) or line_number(
            bridge, "optional_string((*options).audio_input_device)"
        ),
        "rustValidation": line_number(
            bridge, "fn valid_native_host_audio_input_device("
        ),
        "rustPersistence": line_number(bridge, '"audio-input".to_owned()'),
        "rustReadback": line_number(bridge, '("audio-input", audio_input_device)'),
        "swiftDefault": line_number(
            host_swift, "audioInputDeviceName: String? = nil"
        ),
        "swiftProjection": line_number(
            host_swift, "audio_input_device: audioInputDevice"
        ),
        "fallbackGate": line_number(
            audio_service, "native_explicit_audio_input_is_available"
        ),
        "bridgeRegression": line_number(
            bridge,
            "native_host_audio_input_device_is_bounded_explicit_and_default_safe",
        ),
        "fallbackRegression": line_number(
            audio_service, "explicit_audio_input_never_falls_back_to_default"
        ),
        "swiftRegression": line_number(
            sources["swift_tests"], "audioInputDeviceName: \"BlackHole 2ch\""
        ),
        "patchStack": line_number(
            sources["bootstrap"],
            "h6-host-audio-explicit-input-fail-closed.patch",
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
            "host-virtual-audio-input-abi-capable-product-default-microphone"
            if healthy
            else "audit-failed"
        ),
        "currentABI": {"host": host_abi, "viewer": viewer_abi},
        "evidence": evidence,
        "missingEvidence": missing_evidence,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "claims": {
            "virtualInputSelectedByDefault": False,
            "virtualInputProductSelectorImplemented": False,
            "missingExplicitInputFallsClosed": True,
            "installedAudioAcceptanceComplete": False,
            "rustDeskWireChanged": False,
            "hermesChanged": False,
        },
        "nextImplementationBoundary": (
            "host-audio-bootstrap-virtual-input-selection-contract"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
