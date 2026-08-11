#!/usr/bin/env python3
"""Audit H6.1d Viewer receive-audio explicit-policy ABI seam."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-viewer-audio-explicit-policy-abi-contract-audit"
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


def rust_version(source: str) -> int:
    match = re.search(r"^const ABI_VERSION: u32 = (\d+);$", source, re.MULTILINE)
    if match is None:
        raise ValueError("missing Rust Viewer ABI version")
    return int(match.group(1))


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_bridge.rs",
        "client": repository / "Vendor/rustdesk/src/client.rs",
        "client_io": repository / "Vendor/rustdesk/src/client/io_loop.rs",
        "swift": repository / "Sources/CoreBridge/CoreBridge.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "file_product": repository
        / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-viewer-audio-explicit-policy.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
        "swift_tests": repository
        / "Tests/CoreBridgeTests/CoreBridgeContractTests.swift",
        "host_tests": repository
        / "Tests/CoreBridgeTests/HostBridgeContractTests.swift",
    }
    try:
        verified = subprocess.run(
            [str(paths["verifier"])],
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
        bridge_abi = rust_version(sources["bridge"])
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
    client = sources["client"]
    swift = sources["swift"]
    app_product = sources["app"] + sources["home"] + sources["file_product"]
    receive_policy_read = bridge.find("let receive_audio = (*config).receive_audio;")
    epoch_creation = bridge.find("let Some(connection_epoch) = next_viewer_connection_epoch()")
    worker_spawn = bridge.find("let worker = std::thread::spawn")
    evidence = {
        "designRecordsBoundedH61dBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.1d Viewer audio explicit-policy ABI contract",
                "viewer-audio-product-opt-in-permission-lifecycle",
            )
        ),
        "currentABIsStillCarryViewerV17AndHostV18Policies": (
            viewer_abi == bridge_abi == 18 and host_abi == 19
        ),
        "cSwiftAndRustCarryOneImmutableReceivePolicy": all(
            marker in header + swift + bridge
            for marker in (
                "bool receive_audio;",
                "public let receiveAudio: Bool",
                "receiveAudio: Bool = false",
                "receive_audio: config.receiveAudio",
                "receive_audio: bool",
                "let receive_audio = (*config).receive_audio;",
            )
        ),
        "policyIsReadBeforeEpochAndWorkerCreation": (
            receive_policy_read >= 0
            and epoch_creation >= 0
            and worker_spawn >= 0
            and receive_policy_read < epoch_creation < worker_spawn
        ),
        "rustProjectsExactDisableAudioBeforeLogin": all(
            marker in client + bridge
            for marker in (
                "native_viewer_audio_disabled(receive_audio: bool)",
                "!receive_audio",
                "self.config.disable_audio.v = native_viewer_audio_disabled(",
                ".configure_native_viewer(",
                "receive_audio,",
            )
        ),
        "existingWireAndPlaybackRemainRustOwned": all(
            marker in client + sources["client_io"]
            for marker in (
                "msg.disable_audio = BoolOption::Yes.into();",
                "MediaData::AudioFormat(f)",
                "MediaData::AudioFrame(Box::new(frame))",
                "if !lc.disable_audio.v && audio_active",
            )
        ),
        "dedicatedFileSessionRejectsDesktopAudio": all(
            marker in bridge
            for marker in (
                "desktop_capability_requested: bool",
                "enabled && desktop_capability_requested",
                "desktop_clipboard_requested || receive_audio",
            )
        ),
        "productPolicyRemainsDefaultOff": (
            "receiveAudio: Bool = false" in swift
            and "viewerAudioOptInForNextConnection = false" in app_product
            and "本次连接接收远端音频（默认关闭，断开后重置）" in app_product
        ),
        "canonicalAndVendoredBridgeMatch": bridge == sources["vendor_bridge"],
        "patchStackOwnsUpstreamClientChange": all(
            "h6-viewer-audio-explicit-policy.patch" in sources[name]
            for name in ("bootstrap", "verifier")
        ) and all(
            marker in sources["patch"]
            for marker in (
                "native_viewer_audio_disabled",
                "receive_audio: bool",
            )
        ),
        "regressionCoversDefaultExplicitAndFileIsolation": all(
            marker in sources["swift_tests"] + sources["host_tests"] + bridge
            for marker in (
                "testViewerAudioPolicyDefaultsOffAndRemainsIndependent",
                "XCTAssertFalse(disabled.receiveAudio)",
                "receiveAudio: true",
                "XCTAssertFalse(reserved.receiveAudio)",
                "native_viewer_audio_disabled(false)",
                "native_viewer_audio_disabled(true)",
                "viewer ABI must expose v18",
            )
        ),
        "noNewAudioPayloadABIOrWire": (
            "RDNAudio" not in header
            and "AudioCallback" not in header
            and "CoreAudio" not in swift
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"], "H6.1d Viewer audio explicit-policy ABI contract"
        ),
        "viewerABICurrent": line_number(header, "RDN_ABI_VERSION 18u"),
        "hostABIv19": line_number(header, "RDN_HOST_ABI_VERSION 19u"),
        "cPolicy": line_number(header, "bool receive_audio;"),
        "swiftDefault": line_number(swift, "receiveAudio: Bool = false"),
        "swiftProjection": line_number(swift, "receive_audio: config.receiveAudio"),
        "rustPolicyRead": line_number(bridge, "let receive_audio = (*config).receive_audio;"),
        "rustProjection": line_number(client, "native_viewer_audio_disabled(receive_audio: bool)"),
        "loginWire": line_number(client, "msg.disable_audio = BoolOption::Yes.into();"),
        "frameGate": line_number(
            sources["client_io"],
            "if !lc.disable_audio.v && audio_active",
        ),
        "fileIsolation": line_number(bridge, "desktop_clipboard_requested || receive_audio"),
        "patchStack": line_number(
            sources["bootstrap"], "h6-viewer-audio-explicit-policy.patch"
        ),
        "swiftRegression": line_number(
            sources["swift_tests"],
            "testViewerAudioPolicyDefaultsOffAndRemainsIndependent",
        ),
        "rustRegression": line_number(bridge, "native_viewer_audio_disabled(false)"),
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
            "viewer-audio-abi-capable-product-default-off"
            if healthy
            else "audit-failed"
        ),
        "currentABI": {"host": host_abi, "viewer": viewer_abi},
        "evidence": evidence,
        "missingEvidence": missing_evidence,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "claims": {
            "viewerReceiveAudioABICapable": True,
            "viewerAudioEnabledByDefault": False,
            "viewerAudioProductEnabled": True,
            "dedicatedFileSessionRejectsAudio": True,
            "viewerRemoteAudioPermissionPresented": True,
            "virtualAudioInputSelectionImplemented": False,
            "installedAudioAcceptanceComplete": False,
            "rustDeskWireChanged": False,
            "hermesChanged": False,
        },
        "nextImplementationBoundary": "virtual-audio-input-selection",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
