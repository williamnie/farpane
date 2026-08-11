#!/usr/bin/env python3
"""Audit H6.1e Viewer audio opt-in and remote-permission lifecycle."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-viewer-audio-product-opt-in-permission-lifecycle-audit"
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
        "owner": repository / "Sources/CoreBridge/ViewerAudioSessionOwner.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-viewer-audio-permission-lifecycle.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
        "swift_tests": repository
        / "Tests/CoreBridgeTests/ViewerAudioSessionOwnerTests.swift",
        "script_test": repository
        / "Tests/ScriptTests/test_viewer_audio_product_opt_in_permission_lifecycle_audit.py",
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
    client_io = sources["client_io"]
    swift = sources["swift"]
    owner = sources["owner"]
    home = sources["home"]
    app = sources["app"]
    viewer_ui = sources["viewer_ui"]
    evidence = {
        "viewerABIIsV18AndHostCarriesV19Extension": (
            viewer_abi == bridge_abi == 18 and host_abi == 19
        ),
        "typedPermissionEventMatchesAcrossCABIAndRustAndSwift": all(
            marker in header + bridge + swift
            for marker in (
                "RDNRemotePermissionEvent",
                "RDNRemotePermissionCallback",
                "on_remote_permission",
                "REMOTE_PERMISSION_AUDIO",
                "public enum CoreRemotePermission",
                "CoreRemotePermissionEvent",
                "remotePermissionCallback",
            )
        ),
        "rustEmitsAuthoritativePermissionAtAuthenticationAndChange": all(
            marker in bridge
            for marker in (
                "remote_audio_enabled: AtomicBool",
                "self.shared.emit_remote_audio_permission();",
                'else if name == "audio"',
                ".remote_audio_enabled",
                ".store(value, Ordering::Release);",
            )
        ),
        "rustIntersectsLocalAndRemotePolicyBeforeFormatAndFrame": all(
            marker in client + client_io
            for marker in (
                "native_viewer_audio_is_active(",
                "receive_audio && remote_audio_enabled && authenticated",
                "native_viewer_set_authenticated",
                "native_viewer_set_remote_audio_permission",
                "if audio_active {",
                "if !lc.disable_audio.v && audio_active",
            )
        ),
        "revocationResetsNativePlaybackState": all(
            marker in client + client_io
            for marker in (
                "self.audio_sender.send(MediaData::Reset).ok();",
                "MediaData::Reset => {",
                "audio_handler = AudioHandler::default();",
            )
        ),
        "nextConnectionOptInIsExplicitEphemeralAndDefaultOff": all(
            marker in home + app
            for marker in (
                "viewerAudioOptIn: Bool = false",
                "本次连接接收远端音频（默认关闭，断开后重置）",
                "viewerAudioOptInForNextConnection = false",
                "viewerAudioOptInSwitch.state",
                "viewerSessionReceiveAudio = receiveAudio",
            )
        ) and "farpane.viewer.audio" not in app,
        "productAndRecoveryPinSameImmutableOptIn": all(
            marker in app
            for marker in (
                "receiveAudio: receiveAudio",
                "receiveAudio: viewerSessionReceiveAudio",
                "ViewerAudioSessionOwner(",
                "receiveAudio: configuration.receiveAudio",
            )
        ),
        "swiftOwnerPinsEpochAndFailsClosedAcrossTerminal": all(
            marker in owner
            for marker in (
                "event.connectionEpoch > 0",
                "guard connectionEpoch == event.connectionEpoch else { return false }",
                "phase != .ended",
                "phase = .ended",
                "case revokedByRemote",
            )
        ),
        "viewerPresentsEveryAudioPermissionState": all(
            marker in owner + viewer_ui + app
            for marker in (
                "音频：本次未开启",
                "音频：等待远端授权",
                "音频：正在接收",
                "音频：远端未授权",
                "音频：远端已撤销",
                "updateAudioSession",
                "handleViewerRemotePermission",
            )
        ),
        "fileSessionStillCannotOpenAudio": (
            "desktop_clipboard_requested || receive_audio" in bridge
            and "receiveAudio" not in read(
                repository
                / "Sources/CoreBridge/ViewerFileTransferProductComposition.swift"
            )
        ),
        "canonicalBridgeAndPatchStackAreReproducible": (
            bridge == sources["vendor_bridge"]
            and all(
                "h6-viewer-audio-permission-lifecycle.patch" in sources[name]
                for name in ("bootstrap", "verifier")
            )
            and all(
                marker in sources["patch"]
                for marker in (
                    "native_viewer_audio_is_active",
                    "native_viewer_set_remote_audio_permission",
                    "MediaData::Reset",
                )
            )
        ),
        "regressionsCoverPolicyPermissionEpochAndPresentation": all(
            marker in sources["swift_tests"] + sources["script_test"] + bridge
            for marker in (
                "testDefaultOffOwnerIgnoresRemotePermission",
                "testOptInTracksDeniedReceivingRevokedAndRegrant",
                "testEpochMismatchAndTerminalEventsFailClosed",
                "testPresentationDistinguishesEveryPolicyAndPermissionState",
                "native_viewer_audio_is_active(false, true, true)",
                "native_viewer_audio_is_active(true, true, false)",
                "native_viewer_audio_is_active(true, true, true)",
            )
        ),
        "designRecordsBoundedH61eBoundary": all(
            marker in sources["design"]
            for marker in (
                "H6.1e Viewer audio product opt-in and permission lifecycle",
                "virtual-audio-input-selection",
            )
        ),
        "noAudioPayloadABIWireHermesOrRootDependencyChange": (
            "RDNRemotePermissionEvent" in header
            and "const uint8_t *audio" not in header
            and "CoreAudio" not in swift
            and "Hermes" not in sources["patch"]
        ),
    }
    source_lines = {
        "viewerABI": line_number(header, "RDN_ABI_VERSION 18u"),
        "hostABI": line_number(header, "RDN_HOST_ABI_VERSION 19u"),
        "cPermissionEvent": line_number(header, "RDNRemotePermissionEvent"),
        "rustPermissionEmit": line_number(bridge, "emit_remote_audio_permission"),
        "rustRemoteGate": line_number(client, "native_viewer_audio_is_active("),
        "rustRevocationReset": line_number(
            client_io, "self.audio_sender.send(MediaData::Reset).ok();"
        ),
        "swiftPermissionEvent": line_number(swift, "CoreRemotePermissionEvent"),
        "swiftOwner": line_number(owner, "public final class ViewerAudioSessionOwner"),
        "homeOptIn": line_number(home, "本次连接接收远端音频（默认关闭，断开后重置）"),
        "productProjection": line_number(app, "receiveAudio: receiveAudio"),
        "recoveryProjection": line_number(app, "receiveAudio: viewerSessionReceiveAudio"),
        "permissionHandler": line_number(app, "handleViewerRemotePermission"),
        "viewerPresentation": line_number(viewer_ui, "updateAudioSession"),
        "patchStack": line_number(
            sources["bootstrap"], "h6-viewer-audio-permission-lifecycle.patch"
        ),
        "swiftRegression": line_number(
            sources["swift_tests"], "testOptInTracksDeniedReceivingRevokedAndRegrant"
        ),
        "designMilestone": line_number(
            sources["design"], "H6.1e Viewer audio product opt-in and permission lifecycle"
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
            "viewer-audio-product-opt-in-permission-lifecycle-ready"
            if healthy
            else "audit-failed"
        ),
        "currentABI": {"host": host_abi, "viewer": viewer_abi},
        "evidence": evidence,
        "missingEvidence": missing_evidence,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "claims": {
            "viewerAudioEnabledByDefault": False,
            "nextConnectionOptInIsEphemeral": True,
            "remotePermissionIsConnectionScoped": True,
            "revocationClosesRustPlaybackGate": True,
            "virtualAudioInputSelectionImplemented": True,
            "installedAudioAcceptanceComplete": False,
            "rustDeskWireChanged": False,
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
