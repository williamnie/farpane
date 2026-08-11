#!/usr/bin/env python3
"""Audit the H6.1b Host audio explicit-policy ABI seam."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-audio-explicit-policy-abi-contract-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def version(pattern: str, source: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing version pattern: {pattern}")
    return int(match.group(1))


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "audio_service": repository / "Vendor/rustdesk/src/server/audio_service.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "viewer": repository / "Sources/CoreBridge/CoreBridge.swift",
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "info": repository / "App/Info.plist",
        "permission": repository
        / "Sources/RustDeskNative/HostAgentDisplayTCCRecoveryAuthority.swift",
        "microphone": repository
        / "Sources/RustDeskNative/HostMicrophoneAuthorizationAuthority.swift",
        "host_bootstrap": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "build": repository / "Scripts/build-rust-core.sh",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
        "core_tests": repository / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "host_tests": repository / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        header_abi = version(
            r"#define RDN_HOST_ABI_VERSION (\d+)u", sources["header"]
        )
        rust_abi = version(
            r"const HOST_ABI_VERSION: u32 = (\d+);", sources["bridge"]
        )
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
    connection = sources["connection"]
    host_control = sources["host_control"]
    product = sources["app"] + sources["agent"]
    tests = sources["core_tests"] + sources["host_tests"] + bridge + connection
    start_offset = bridge.find('pub unsafe extern "C" fn rdn_host_start(')
    policy_call = bridge.find(
        "apply_native_host_optional_capability_policy(", start_offset
    )
    identity_read = bridge.find(
        "host.local_id = config::Config::get_id();", start_offset
    )

    evidence = {
        "designRecordsBoundedH61bBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.1b Host audio explicit-policy ABI seam",
                "host-audio-bootstrap-microphone-opt-in-contract",
            )
        ),
        "currentHostABIPreservesV18AudioPolicy": header_abi == rust_abi == 19,
        "cCreateOptionsCarryDedicatedAudioPolicy": "bool enable_audio;" in header,
        "swiftPolicyDefaultsOffAndProjectsToC": all(
            marker in host_control
            for marker in (
                "public let audioEnabled: Bool",
                "audioEnabled: Bool = false",
                "enable_audio: configuration.audioEnabled",
            )
        ),
        "rustCopiesImmutableCreatePolicy": all(
            marker in bridge
            for marker in (
                "audio_enabled: bool",
                "audio_enabled: (*options).enable_audio",
                "host.audio_enabled",
            )
        ),
        "policyIsPersistedBeforeIdentityAndReadBackExactly": (
            policy_call >= 0
            and identity_read >= 0
            and policy_call < identity_read
            and "native_host_audio_option(audio_enabled)" in bridge
            and "PersistenceMismatch" in bridge
        ),
        "approvalIntersectsLocalAndRemotePolicy": all(
            marker in connection
            for marker in (
                "fn native_host_audio_capability_requested(",
                "local_audio_enabled && !remote_audio_disabled",
                "self.audio_enabled(),",
                'requested_capabilities.push("hearSystemAudio".to_owned())',
            )
        ),
        "upstreamSubscriptionConsumesSamePersistedOption": all(
            marker in connection
            for marker in (
                "audio: Self::permission(keys::OPTION_ENABLE_AUDIO",
                "fn audio_enabled(&self) -> bool",
                "self.audio && !self.disable_audio",
                "super::audio_service::NAME",
            )
        ),
        "pinnedAudioServiceRemainsRustOwned": all(
            marker in sources["audio_service"]
            for marker in (
                "HOST.default_input_device()",
                "Encoder::new(sample_rate, encode_channel, LowDelay)",
                "msg_out.set_audio_frame(AudioFrame",
            )
        ),
        "productPolicyRetainsDefaultOff": (
            "public static let disabled = Self(enabled: false)"
            in sources["host_bootstrap"]
            and "var audioEnabled: Bool = false"
            in sources["home"]
        ),
        "laterViewerPolicyExtensionPreservesDefaultOff": (
            "receiveAudio: Bool = false" in sources["viewer"]
            and "native_viewer_audio_disabled(receive_audio: bool)"
            in sources["client"]
            and "!receive_audio" in sources["client"]
        ),
        "laterExtensionsPreserveV18AudioPolicy": (
            "NSMicrophoneUsageDescription" in sources["info"]
            and "AVCaptureDevice.requestAccess(" in sources["microphone"]
            and header_abi == rust_abi == 19
        ),
        "releaseBuildStillExcludesScreenCaptureKit": (
            "rdn-native-core,rdn-native-host" in sources["build"]
            and "screencapturekit" not in sources["build"]
        ),
        "patchStackTracksApprovalIntersection": all(
            "h6-audio-local-policy-approval.patch" in sources[name]
            for name in ("bootstrap", "verifier")
        ),
        "defaultAndExplicitReadbackHaveTests": all(
            marker in tests
            for marker in (
                "XCTAssertFalse(disabled.audioEnabled)",
                "audioEnabled: true",
                "host_storage_readback_accepts_explicit_audio_opt_in_only",
                "native_host_audio_request_intersects_local_and_remote_policy",
            )
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.1b Host audio explicit-policy ABI seam"
        ),
        "hostABIv19": line_number(header, "RDN_HOST_ABI_VERSION 19u"),
        "cAudioPolicy": line_number(header, "bool enable_audio;"),
        "swiftDefault": line_number(host_control, "audioEnabled: Bool = false"),
        "rustPolicyCopy": line_number(
            bridge, "audio_enabled: (*options).enable_audio"
        ),
        "policyApplication": line_number(
            bridge, "apply_native_host_optional_capability_policy("
        ),
        "policyReadback": line_number(
            bridge, "native_host_audio_option(audio_enabled)"
        ),
        "approvalIntersection": line_number(
            connection, "fn native_host_audio_capability_requested("
        ),
        "approvalRequest": line_number(
            connection, 'requested_capabilities.push("hearSystemAudio".to_owned())'
        ),
        "rustReadbackTest": line_number(
            bridge, "host_storage_readback_accepts_explicit_audio_opt_in_only"
        ),
        "rustApprovalTest": line_number(
            connection, "native_host_audio_request_intersects_local_and_remote_policy"
        ),
        "swiftPolicyTest": line_number(
            sources["core_tests"], "audioOnly = HostServerConfiguration("
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "host-audio-abi-capable-product-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-audio-explicit-policy-abi-seam",
        "status": status,
        "implementation": {
            "hostABIVersion": rust_abi,
            "evidence": evidence,
            "sourceLines": source_lines,
        },
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostAudioEnabledByDefault": False,
            "hostAudioABICapable": True,
            "hostAudioProductEnabled": True,
            "viewerAudioImplemented": False,
            "microphoneTCCImplemented": True,
            "installedAudioAcceptanceComplete": False,
            "rustDeskWireChanged": False,
            "hermesChanged": False,
        },
        "nextImplementationBoundary": "viewer-audio-explicit-policy-abi-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "host-audio-abi-capable-product-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
