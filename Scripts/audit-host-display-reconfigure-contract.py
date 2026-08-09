#!/usr/bin/env python3
"""Audit the pinned native Host display-reconfigure ownership chain."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


SCHEMA = "farpane-host-display-reconfigure-contract-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def section(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset <= start_offset:
        return ""
    return source[start_offset:end_offset]


def ordered(source: str, *markers: str) -> bool:
    offset = 0
    for marker in markers:
        offset = source.find(marker, offset)
        if offset < 0:
            return False
        offset += len(marker)
    return True


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def pinned_service_source(repository: Path) -> str:
    vendor = repository / "Vendor/rustdesk"
    if not (vendor / ".git").is_dir():
        raise ValueError("missing pinned Vendor/rustdesk checkout")
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=vendor,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if commit != PINNED_RUSTDESK_COMMIT:
        raise ValueError(
            f"RustDesk checkout mismatch: expected={PINNED_RUSTDESK_COMMIT} actual={commit}"
        )
    return subprocess.run(
        ["git", "show", f"{PINNED_RUSTDESK_COMMIT}:src/server/service.rs"],
        cwd=vendor,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "media_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        ),
        "route_owner": (
            repository
            / "Sources/VideoPipeline/HostMediaPipelineRouteOwner.swift"
        ),
        "capture": repository / "Sources/VideoPipeline/HostScreenCapture.swift",
        "h0": repository / "docs/host-mode-h0.md",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        sources["service"] = pinned_service_source(repository)
    except (
        OSError,
        UnicodeError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    patch = sources["patch"]
    native_run = section(
        patch,
        "fn run_native(vs: VideoService)",
        "#[cfg(all(test, feature = \"rdn-native-host\"))]",
    )
    route_guard = section(
        patch,
        "struct NativeRouteGuard",
        "fn native_media_message(",
    )
    begin_route = section(
        sources["bridge"],
        "pub(crate) fn native_media_begin_route(",
        "pub(crate) fn native_media_record_dequeued",
    )
    end_route = section(
        sources["bridge"],
        "pub(crate) fn native_media_end_route(",
        "impl Drop for RuntimeFinished",
    )
    service_run = section(
        sources["service"],
        "pub fn run<F, Svc>",
        "pub fn active(&self)",
    )

    evidence = {
        "nativeMonitorUsesPinnedGenericServiceRestartLoop": (
            "if source.is_monitor()" in patch
            and "GenericService::run(&vs, run_native);" in patch
            and all(
                marker in service_run
                for marker in (
                    "while sp.active()",
                    "if sp.has_subscribes()",
                    "callback(sp.clone())",
                    "error_timeout *= 2",
                    "MAX_ERROR_TIMEOUT",
                )
            )
        ),
        "rustDisplayInventoryIsTheSingleAuthority": (
            ordered(
                native_run,
                "let display_idx = vs.idx;",
                "display_service::get_display_info(display_idx)",
                "let route = crate::rdn_host_bridge::native_media_begin_route(",
                "while sp.ok()",
                "display_service::get_display_info(display_idx).as_ref() != Some(&display)",
                "make_display_changed_msg(display_idx, None, VideoSource::Monitor)",
                "bail!(\"SWITCH\")",
            )
            and "CGDisplayRegisterReconfigurationCallback" not in sources["media_owner"]
        ),
        "displayChangeNotificationReachesCurrentAndJoiningSubscribers": (
            ordered(
                native_run,
                "sp.send_shared(message.clone());",
                "sp.snapshot(move |snapshot|",
                "snapshot.send_shared(message.clone());",
            )
        ),
        "oldRouteIsRetiredBeforeServiceRetry": (
            "native_media_end_route(&self.0);" in route_guard
            and all(
                marker in end_route
                for marker in (
                    "current.connection_epoch == route.connection_epoch",
                    "current.codec_epoch == route.codec_epoch",
                    "broker.routes.remove(&route.display_id)",
                    '"command": "stopCapture"',
                    '"connectionEpoch": route.connection_epoch',
                    '"codecEpoch": route.codec_epoch',
                )
            )
        ),
        "replacementRouteGetsFreshEpochsAndCurrentDimensions": (
            all(
                marker in begin_route
                for marker in (
                    "NEXT_CONNECTION_EPOCH.fetch_add(1, Ordering::Relaxed)",
                    "NEXT_CODEC_EPOCH.fetch_add(1, Ordering::Relaxed)",
                    '"command": "startCapture"',
                    '"command": "reconfigure"',
                    '"width": width',
                    '"height": height',
                )
            )
            and ordered(
                native_run,
                "display_service::get_display_info(display_idx)",
                "display.width.max(0) as u32",
                "display.height.max(0) as u32",
            )
        ),
        "swiftTreatsDisplayIDAsIndexAndRequiresExactEpochIdentity": (
            all(
                marker in sources["media_owner"]
                for marker in (
                    "control.connectionEpoch > 0",
                    "control.codecEpoch > 0",
                    "control.displayRevision > 0",
                    "displayIndex: Int(control.displayID)",
                    "recoveryOwner.stop(route: identity)",
                )
            )
            and "configuration.displayIndex >= 0" in sources["route_owner"]
        ),
        "screenCaptureReenumeratesAndBoundsChecksFreshIndex": ordered(
            sources["capture"],
            "SCShareableContent.excludingDesktopWindows(",
            "content.displays.indices.contains(configuration.displayIndex)",
            "let display = content.displays[configuration.displayIndex]",
            "SCContentFilter(",
        ),
        "routeOwnerRejectsLateGenerationCallbacks": all(
            marker in sources["route_owner"]
            for marker in (
                "generation += 1",
                "current?.generation == callbackGeneration",
                "current?.route == route",
                "telemetry.recordDrop(.reconfigure)",
            )
        ),
        "screenCallbackIsExplicitlyAccelerationOnly": all(
            marker in sources["h0"]
            for marker in (
                "display 变化继续走现有 SWITCH 重建",
                "ScreenCaptureKit 热插拔回调仅作加速提示",
                "权威判定交给 `check_display_changed`",
                "避免双检测竞争",
            )
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "monitorNativeBranch": line_number(patch, "if source.is_monitor()"),
        "displayBaseline": line_number(
            patch,
            "let display = display_service::get_display_info(display_idx)",
        ),
        "displayComparison": line_number(
            patch,
            "display_service::get_display_info(display_idx).as_ref() != Some(&display)",
        ),
        "routeRetirement": line_number(
            sources["bridge"],
            "pub(crate) fn native_media_end_route(",
        ),
        "freshEpochs": line_number(
            sources["bridge"],
            "let connection_epoch = NEXT_CONNECTION_EPOCH.fetch_add",
        ),
        "swiftDisplayIndex": line_number(
            sources["media_owner"],
            "displayIndex: Int(control.displayID)",
        ),
        "captureReenumeration": line_number(
            sources["capture"],
            "SCShareableContent.excludingDesktopWindows(",
        ),
    }

    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "ownership-frozen" if not missing else "contract-drift",
        "pinnedRustDeskCommit": PINNED_RUSTDESK_COMMIT,
        "authoritativeOwner": "pinned RustDesk monitor video service",
        "displayIdentity": "RustDesk display index, not CGDirectDisplayID",
        "rebuildTrigger": "display-info inequality -> SWITCH",
        "replacementFreshness": "new connectionEpoch and codecEpoch",
        "callbackPolicy": "optional acceleration only; never route authority",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "remainingBoundary": {
            "automaticSourcePathExists": True,
            "productCallbackNotRequiredForCorrectness": True,
            "callbackMayOnlyWakeExistingRustAuthority": True,
            "realDisplayReconfigureStillRequiresInstalledMacAcceptance": True,
            "multiDisplaySelectionRemainsH6": True,
        },
    }
    print(json.dumps(document, sort_keys=True))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
