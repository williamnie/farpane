#!/usr/bin/env python3
"""Audit H6.1 audio ownership and freeze the next default-off ABI checkpoints."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-audio-product-ownership-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def define_version(source: str, name: str) -> int:
    match = re.search(rf"^#define {re.escape(name)} (\d+)u$", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    verifier = repository / "Scripts/verify-rustdesk-core-source.sh"
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_host_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "audio_service": repository / "Vendor/rustdesk/src/server/audio_service.rs",
        "common": repository / "Vendor/rustdesk/src/common.rs",
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "client_io": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_swift": repository / "Sources/CoreBridge/HostControlClient.swift",
        "viewer_swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "permission": repository
        / "Sources/RustDeskNative/HostAgentDisplayTCCRecoveryAuthority.swift",
        "microphone": repository
        / "Sources/RustDeskNative/HostMicrophoneAuthorizationAuthority.swift",
        "bootstrap": repository
        / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "info": repository / "App/Info.plist",
        "build_core": repository / "Scripts/build-rust-core.sh",
        "cargo": repository / "Vendor/rustdesk/Cargo.toml",
    }
    try:
        verified = subprocess.run(
            [str(verifier)],
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
        viewer_abi = define_version(sources["header"], "RDN_ABI_VERSION")
        host_abi = define_version(sources["header"], "RDN_HOST_ABI_VERSION")
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

    design = sources["design"]
    header = sources["header"]
    host_bridge = sources["host_bridge"]
    connection = sources["connection"]
    audio_service = sources["audio_service"]
    client = sources["client"]
    client_io = sources["client_io"]
    viewer_bridge = sources["viewer_bridge"]
    product = sources["app"] + sources["agent"]
    evidence = {
        "designFreezesIndependentOptionalAudioBoundary": all(marker in design for marker in (
            "音频、剪贴板和文件传输采用独立功能开关和阶段门禁",
            "Microphone/System Audio | 远程音频 | 仅禁用音频，不阻塞屏幕 MVP",
            "hearSystemAudio",
            "V1 不包含 system audio",
            "H6.1 音频：麦克风采集为原生主路",
            "第三方虚拟设备（如 BlackHole）可选路径",
        )),
        "releaseBuildExcludesScreenCaptureKitLoopbackFeature": (
            "rdn-native-core,rdn-native-host" in sources["build_core"]
            and "screencapturekit" not in sources["build_core"]
            and 'screencapturekit = ["cpal/screencapturekit"]' in sources["cargo"]
        ),
        "upstreamHostConnectionOwnsAudioPermissionAndSubscription": all(
            marker in connection for marker in (
                "audio: Self::permission(keys::OPTION_ENABLE_AUDIO, &control_permissions)",
                "fn audio_enabled(&self) -> bool",
                "self.audio && !self.disable_audio",
                "noperms.push(super::audio_service::NAME)",
                "super::audio_service::NAME,",
                "self.audio_enabled(),",
            )
        ),
        "upstreamHostNativeMicrophoneAndOpusPathExists": all(
            marker in audio_service for marker in (
                '#[cfg(not(any(windows, feature = "screencapturekit")))]',
                "get_audio_input(&audio_input)",
                "HOST.default_input_device()",
                "Encoder::new(sample_rate, encode_channel, LowDelay)",
                "create_format_msg(sample_rate, ch as _)",
                "msg_out.set_audio_frame(AudioFrame",
            )
        ),
        "upstreamSupportsExplicitVirtualInputWithoutNewWire": all(
            marker in audio_service + sources["common"] for marker in (
                "https://github.com/ExistentialAudio/BlackHole",
                'Config::get_option("audio-input")',
                "fn get_audio_input(audio_input: &str)",
                "set_sound_input(device: String)",
            )
        ),
        "upstreamViewerOwnsOpusDecodeBufferAndNativePlayback": all(
            marker in client + client_io for marker in (
                "audio_sender: crate::client::start_audio_thread()",
                "MediaData::AudioFormat(f)",
                "MediaData::AudioFrame(Box::new(frame))",
                "pub struct AudioHandler",
                "AudioDecoder::new",
                "default_output_device()",
                "d.decode_float(&frame.data, buffer, false)",
            )
        ),
        "nativeHostOwnsExplicitDefaultOffAudioPolicyBeforeRuntime": all(
            marker in host_bridge for marker in (
                "audio_enabled: (*options).enable_audio",
                "OPTION_ENABLE_AUDIO",
                "native_host_audio_option(audio_enabled)",
                "apply_native_host_optional_capability_policy(",
                "host.local_id = config::Config::get_id();",
            )
        ),
        "nativeViewerExplicitPolicyDefaultsAudioOff": (
            "receiveAudio: Bool = false" in sources["viewer_swift"]
            and "native_viewer_audio_disabled(receive_audio: bool)" in client
            and "!receive_audio" in client
            and "let receive_audio = (*config).receive_audio;" in viewer_bridge
        ),
        "viewerProductOptInAndRemotePermissionLifecycleAreImplemented": all(
            marker in sources["viewer_swift"] + sources["home"] + product
            for marker in (
                "public enum CoreRemotePermission",
                "ViewerAudioSessionOwner",
                "viewerAudioOptInForNextConnection = false",
                "本次连接接收远端音频（默认关闭，断开后重置）",
                "onRemotePermission:",
                "receiveAudio: viewerSessionReceiveAudio",
            )
        ) and all(
            marker in viewer_bridge + client + client_io
            for marker in (
                'else if name == "audio"',
                "emit_remote_audio_permission",
                "native_viewer_audio_is_active",
                "native_viewer_set_remote_audio_permission",
                "self.audio_sender.send(MediaData::Reset).ok();",
            )
        ),
        "activeSessionAudioRevocationAlreadyUsesConnectionAuthority": all(
            marker in host_bridge + connection for marker in (
                "NativeSessionCommand::DisableAudio",
                'name: "audio".to_owned()',
                "self.disable_audio = q == BoolOption::Yes",
                "conn.send_permission(Permission::Audio, false).await",
            )
        ),
        "audioStaysInsidePinnedRustDataPlane": (
            "RDNAudio" not in header
            and "AudioCallback" not in header
            and "CoreAudio" not in sources["viewer_swift"]
        ),
        "canonicalAndVendoredHostBridgeMatch": (
            host_bridge == sources["vendor_host_bridge"]
        ),
        "hostMicrophoneOptInAndTCCProjectionAreImplemented": all(
            marker in sources["microphone"] + sources["info"] + sources["bootstrap"]
            + sources["home"] + product
            for marker in (
                "AVCaptureDevice.requestAccess(",
                "NSMicrophoneUsageDescription",
                "public let audioPolicy: HostAgentAudioPolicy",
                "远程音频（默认关闭）",
                "farpane.host.audio.enabled",
                "isAuthorizedWithoutPrompt()",
            )
        ),
        "explicitVirtualInputABIAndFailClosedFallbackAreImplemented": all(
            marker in header + host_bridge + audio_service + sources["host_swift"]
            for marker in (
                "const char *audio_input_device;",
                "valid_native_host_audio_input_device(",
                '("audio-input", audio_input_device)',
                "native_explicit_audio_input_is_available",
                "public let audioInputDeviceName: String?",
            )
        ),
    }

    gaps = {
        "virtualInputSelectionHasNoFarPaneProductOwner": (
            '"audio-input"' not in product
            and "BlackHole" not in product
        ),
        "installedAudioAcceptanceHasNoEvidence": (
            "现场检查继续如实记为“未验证”" in design
            and not any(
                path.is_file()
                for path in (repository / "Evidence/HostMode").glob("**/*audio*acceptance*.md")
            )
        ),
    }

    source_lines = {
        "designAudioMilestone": line_number(design, "H6.1 音频：麦克风采集为原生主路"),
        "designPermissionDegrade": line_number(design, "Microphone/System Audio | 远程音频"),
        "designCapability": line_number(design, "hearSystemAudio"),
        "buildFeatureSet": line_number(sources["build_core"], "rdn-native-core,rdn-native-host"),
        "hostAudioPermission": line_number(connection, "audio: Self::permission(keys::OPTION_ENABLE_AUDIO"),
        "hostAudioSubscription": line_number(connection, "fn audio_enabled(&self) -> bool"),
        "hostAudioCapture": line_number(audio_service, "fn get_audio_input(audio_input: &str)"),
        "hostOpusEncoder": line_number(audio_service, "Encoder::new(sample_rate, encode_channel, LowDelay)"),
        "viewerAudioDefaultOff": line_number(
            sources["viewer_swift"], "receiveAudio: Bool = false"
        ),
        "viewerAudioIngress": line_number(client_io, "Some(misc::Union::AudioFormat(f))"),
        "viewerAudioPlayback": line_number(client, "pub struct AudioHandler"),
        "viewerRemotePermission": line_number(
            viewer_bridge, "emit_remote_audio_permission"
        ),
        "hostAudioPolicyPin": line_number(host_bridge, "native_host_audio_option(audio_enabled)"),
        "activeSessionRevoke": line_number(host_bridge, "NativeSessionCommand::DisableAudio"),
        "hostMicrophoneOptIn": line_number(product, "farpane.host.audio.enabled"),
        "microphoneTCC": line_number(
            sources["microphone"], "AVCaptureDevice.requestAccess("
        ),
        "infoPlist": line_number(
            sources["info"], "NSMicrophoneUsageDescription"
        ),
        "virtualInputABI": line_number(
            header, "const char *audio_input_device;"
        ),
        "virtualInputFallbackGate": line_number(
            audio_service, "native_explicit_audio_input_is_available"
        ),
    }

    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_gaps = [name for name, present in gaps.items() if not present]
    healthy = (
        not missing_evidence
        and not missing_gaps
        and all(source_lines.values())
        and viewer_abi == 18
        and host_abi == 19
    )
    target_contract = {
        "hostABI": 19,
        "viewerABI": 18,
        "hostPolicy": "explicit immutable enableAudio boolean, default false",
        "viewerPolicy": "explicit immutable receiveAudio boolean, default false",
        "defaultCaptureSource": "native system-default microphone",
        "systemAudioRoute": "explicit user-selected virtual input device only",
        "captureOwner": "pinned RustDesk audio service cpal input and Opus encoder",
        "playbackOwner": "pinned RustDesk Viewer AudioHandler and cpal output",
        "wireOwner": "existing RustDesk AudioFormat and AudioFrame messages",
        "permissionOwner": "FarPane App microphone TCC policy projected to HostAgent",
        "sessionCapability": "hearSystemAudio compatibility capability",
        "sourceSelection": (
            "system-default microphone first; ABI-capable explicit input with product selector later"
        ),
        "swiftAudioPayloadBoundary": "none; encoded and decoded audio remains in Rust",
        "lifecycle": (
            "capture only while an admitted audio-capable session subscribes; Viewer playback "
            "only when receiveAudio is explicitly true"
        ),
    }
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "host-opt-in-implemented-development-incomplete"
            if healthy
            else "audit-failed"
        ),
        "pinnedRustDeskCommit": PINNED_RUSTDESK_COMMIT,
        "currentABI": {"host": host_abi, "viewer": viewer_abi},
        "evidence": evidence,
        "gaps": gaps,
        "missingEvidence": missing_evidence,
        "missingGaps": missing_gaps,
        "sourceLines": source_lines,
        "targetContract": target_contract,
        "claims": {
            "hostAudioEnabled": False,
            "viewerAudioEnabled": True,
            "audioProductDevelopmentComplete": False,
            "hostABIChangeRequired": False,
            "viewerABIChangeRequired": False,
            "rustDeskWireChangeRequired": False,
            "hermesChangeRequired": False,
            "rootDependencyChangeRequired": False,
            "installedAudioAcceptanceStillRequired": True,
        },
        "nextImplementationBoundary": (
            "host-audio-bootstrap-virtual-input-selection-contract"
        ),
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
