#!/usr/bin/env python3
"""Audit H6.4 Viewer display-selection ownership and freeze its ABI checkpoint."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


SCHEMA = "farpane-host-multi-display-selection-ownership-audit"
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


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def define_version(source: str, name: str) -> int:
    match = re.search(rf"^#define {re.escape(name)} (\d+)u$", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def pinned_source(repository: Path, relative_path: str) -> str:
    vendor = repository / "Vendor/rustdesk"
    return subprocess.run(
        ["git", "show", f"{PINNED_RUSTDESK_COMMIT}:{relative_path}"],
        cwd=vendor,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    verifier = repository / "Scripts/verify-rustdesk-core-source.sh"
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "shim": repository / "CoreBridge/Shim/rdn_shim.c",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "server_connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "swift_bridge": repository / "Sources/CoreBridge/CoreBridge.swift",
        "host_switch_patch": repository
        / "CoreBridge/RustDeskPatch/h6-host-display-switch-validation.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
    }
    try:
        verified = subprocess.run(
            [str(verifier)],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if verified != (
            "RUSTDESK_CORE_SOURCE_VERIFIED "
            f"commit={PINNED_RUSTDESK_COMMIT}"
        ):
            raise ValueError("RustDesk source verification returned an unexpected result")
        sources = {name: read(path) for name, path in paths.items()}
        sources["upstream_ui_session"] = pinned_source(
            repository, "src/ui_session_interface.rs"
        )
        sources["upstream_display_service"] = pinned_source(
            repository, "src/server/display_service.rs"
        )
        sources["upstream_client_io"] = pinned_source(
            repository, "src/client/io_loop.rs"
        )
        viewer_abi = define_version(sources["header"], "RDN_ABI_VERSION")
        host_abi = define_version(sources["header"], "RDN_HOST_ABI_VERSION")
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

    client_switch = section(
        sources["upstream_ui_session"],
        "    pub fn switch_display(&self, display: i32)",
        "    #[cfg(not(any(target_os = \"android\", target_os = \"ios\")))]",
    )
    display_service = sources["upstream_display_service"]
    host_switch = section(
        sources["server_connection"],
        "    async fn handle_switch_display(&mut self, s: SwitchDisplay)",
        "    fn video_source(&self) -> VideoSource",
    )
    host_switch_owner = section(
        sources["server_connection"],
        "    fn switch_display_to(&mut self, display_idx: usize",
        "    #[cfg(windows)]",
    )
    viewer_impl = section(
        sources["viewer_bridge"],
        "impl InvokeUiSession for BridgeUi",
        "fn native_stream_fps",
    )
    display_frame = section(
        sources["header"],
        "typedef struct RDNEncodedVideoFrame",
        "} RDNEncodedVideoFrame;",
    )
    dynamic_peer_info = section(
        sources["upstream_client_io"],
        "Some(message::Union::PeerInfo(pi))",
        "Some(message::Union::ScreenshotResponse(response))",
    )

    evidence = {
        "designRequiresCommandEventAndRevisionedMapping": all(
            marker in sources["design"]
            for marker in (
                "- selectDisplay；",
                "所有 command 均带 `commandId`",
                "最终结果通过 event 回传",
                "display 切换和缩放变化使用 revisioned display mapping",
                "H6.4 多显示器切换",
            )
        ),
        "pinnedClientAlreadySendsCanonicalSwitchDisplay": ordered(
            client_switch,
            "misc.set_switch_display(SwitchDisplay",
            "display,",
            "self.send(Data::Message(msg_out))",
            "self.capture_displays(vec![], vec![], vec![display])",
        ),
        "pinnedDisplayServicePublishesInitialAndChangingInventories": (
            all(
                marker in display_service
                for marker in (
                    "fn displays_to_msg(displays: Vec<DisplayInfo>)",
                    "pi.displays = displays.clone();",
                    "msg_out.set_peer_info(pi);",
                    "fn check_get_displays_changed_msg()",
                    "if let Some(msg_out) = check_get_displays_changed_msg()",
                    "std::thread::sleep(Duration::from_millis(300))",
                )
            )
            and all(
                marker in sources["server_connection"]
                for marker in (
                    "update_get_sync_displays_on_login().await",
                    "pi.displays = displays;",
                    "pi.current_display = self.display_idx as _;",
                )
            )
            and "self.handler.set_displays(&pi.displays);" in dynamic_peer_info
        ),
        "nativeHostSwitchOwnsServiceSelectionAndInputEpoch": (
            ordered(
                host_switch,
                "validate_monitor_display_switch_target(",
                "self.switch_display_to(display_idx, server.clone())",
                "self.send_current_display_changed().await",
            )
            and all(
                marker in host_switch_owner
                for marker in (
                    "lock.subscribe(&old_service_name",
                    "lock.subscribe(&new_service_name",
                    "self.display_idx = display_idx;",
                    "self.input_mapping.advance();",
                )
            )
        ),
        "nativeHostRejectsInvalidMonitorTargetBeforeServiceMutation": (
            all(
                marker in sources["server_connection"]
                for marker in (
                    "fn validate_monitor_display_switch_target(",
                    "usize::try_from(requested_display).ok()?",
                    "let display = get_display(display_idx)?;",
                    "!display.online",
                    "display.width <= 0",
                    "display.height <= 0",
                    "!display.scale.is_finite()",
                    "display.x.checked_add(display.width)?;",
                    "display.y.checked_add(display.height)?;",
                    "self.send_current_display_changed().await;",
                    "monitor_display_switch_target_is_live_bounded_and_fail_closed",
                )
            )
            and ordered(
                host_switch,
                "validate_monitor_display_switch_target(",
                "let Some(display_idx) = display_idx else",
                "self.send_current_display_changed().await;",
                "return;",
                "self.switch_display_to(display_idx, server.clone())",
            )
            and all(
                marker in sources["host_switch_patch"]
                for marker in (
                    "validate_monitor_display_switch_target",
                    "send_current_display_changed",
                    "monitor_display_switch_target_is_live_bounded_and_fail_closed",
                )
            )
            and "host_display_switch_validation_patch_file=" in sources["bootstrap"]
            and 'apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file"'
            in sources["bootstrap"]
            and "host_display_switch_validation_patch=" in sources["verifier"]
            and 'apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch"'
            in sources["verifier"]
        ),
        "peerSwitchEchoIsConsumedBeforeFollowingDisplayFrames": (
            "Send SwitchDisplay on the same channel as VideoFrame" in sources["server_connection"]
            and ordered(
                sources["upstream_client_io"],
                "Some(misc::Union::SwitchDisplay(s))",
                "self.handler.handle_peer_switch_display(&s);",
                "thread.video_sender.send(MediaData::Reset)",
            )
        ),
        "nativeViewerFramesBindConnectionCatalogAndDisplay": (
            "uint32_t display;" in display_frame
            and "display_catalog_revision" in display_frame
            and "connection_epoch" in display_frame
        ),
        "nativeViewerNormalizesCatalogAndSelectedDisplay": all(
            marker in viewer_impl
            for marker in (
                "fn set_peer_info(&self, peer_info: &PeerInfo)",
                "publish_display_catalog(&peer_info.displays, Some(selected))",
                "fn set_displays(&self, displays: &Vec<DisplayInfo>)",
                "fn set_current_display(&self, display: i32)",
                "fn switch_display(&self, display: &SwitchDisplay)",
                "NativeViewerDisplaySelectionIngress::SwitchEcho",
                "NativeViewerDisplaySelectionIngress::RemoteFollow",
            )
        ),
        "viewerCatalogABIIsStrictAndConnectionScoped": all(
            marker in sources["header"]
            for marker in (
                "typedef struct RDNDisplayCatalogEntry",
                "typedef struct RDNDisplayCatalogEvent",
                "RDNDisplayCatalogCallback on_display_catalog;",
                "uint64_t connection_epoch;",
                "uint64_t display_catalog_revision;",
            )
        ),
        "viewerSelectionABIIsStrictAndTerminal": (
            all(
                marker in sources["header"]
                for marker in (
                    "typedef struct RDNDisplaySelectionRequest",
                    "typedef struct RDNDisplaySelectionEvent",
                    "RDNDisplaySelectionCallback on_display_selection;",
                    "int32_t rdn_client_select_display(",
                    "int32_t rdn_shim_client_select_display(",
                )
            )
            and all(
                marker in sources["shim"]
                for marker in (
                    'dlsym(handle, "rdn_client_select_display")',
                    "library->client_select_display == NULL",
                    "int32_t rdn_shim_client_select_display(",
                )
            )
            and all(
                marker in sources["viewer_bridge"]
                for marker in (
                    "pending_selection: Option<NativeViewerDisplaySelectionPending>",
                    "pub unsafe extern \"C\" fn rdn_client_select_display(",
                    "fn emit_display_selection(&self, snapshot: NativeViewerDisplaySelectionSnapshot)",
                    "DISPLAY_SELECTION_RESULT_ALREADY_SELECTED",
                    "DISPLAY_SELECTION_FAILURE_CATALOG_CHANGED",
                    "DISPLAY_SELECTION_FAILURE_CONNECTION_CLOSED",
                    "DISPLAY_SELECTION_FAILURE_REMOTE_SELECTION_DRIFT",
                )
            )
            and all(
                marker in sources["swift_bridge"]
                for marker in (
                    "public struct CoreDisplaySelectionRequest",
                    "public struct CoreDisplaySelectionEvent",
                    "private let displaySelectionCallback",
                    "public func selectDisplay(_ request: CoreDisplaySelectionRequest)",
                )
            )
        ),
        "hostMediaDisplayRevisionIsSeparateRouteLocalAuthority": (
            "display_revisions: HashMap<u64, u64>" in sources["host_bridge"]
            and "pending_display_reconfigures" in sources["host_bridge"]
            and "该内部 generation 不复用 media `displayRevision`" in sources["design"]
        ),
    }

    gaps = {
        "viewerProductDisplaySelectorMissing": (
            "onSelectDisplay" not in sources["viewer_ui"]
            and "displaySelector" not in sources["viewer_ui"]
            and "selectDisplay(" not in sources["app"]
        ),
        "viewerDoesNotQuiesceInputDuringSelection": (
            "displaySelectionPending" not in sources["app"]
            and "releaseAllInputForDisplaySelection" not in sources["app"]
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_gaps = [name for name, present in gaps.items() if not present]

    source_lines = {
        "designSelectDisplay": line_number(sources["design"], "- selectDisplay；"),
        "designRevisionedMapping": line_number(
            sources["design"],
            "display 切换和缩放变化使用 revisioned display mapping",
        ),
        "upstreamViewerSwitch": line_number(
            sources["upstream_ui_session"],
            "    pub fn switch_display(&self, display: i32)",
        ),
        "upstreamInventoryService": line_number(
            display_service,
            "fn displays_to_msg(displays: Vec<DisplayInfo>)",
        ),
        "nativeHostSwitch": line_number(
            sources["server_connection"],
            "    async fn handle_switch_display(&mut self, s: SwitchDisplay)",
        ),
        "nativeHostSwitchValidation": line_number(
            sources["server_connection"],
            "fn validate_monitor_display_switch_target(",
        ),
        "viewerCatalogOwner": line_number(
            sources["viewer_bridge"],
            "fn publish_display_catalog(&self, displays: &[DisplayInfo]",
        ),
        "viewerFrameDisplayIndex": line_number(
            sources["header"],
            "typedef struct RDNEncodedVideoFrame",
        ),
        "hostMediaRouteRevision": line_number(
            sources["host_bridge"],
            "display_revisions: HashMap<u64, u64>",
        ),
        "viewerSelectionRequest": line_number(
            sources["header"],
            "typedef struct RDNDisplaySelectionRequest",
        ),
        "viewerSelectionAuthority": line_number(
            sources["viewer_bridge"],
            "pub unsafe extern \"C\" fn rdn_client_select_display(",
        ),
        "swiftSelectionProjection": line_number(
            sources["swift_bridge"],
            "public struct CoreDisplaySelectionRequest",
        ),
    }

    target_contract = {
        "viewerABI": 16,
        "hostABI": 17,
        "catalogIdentity": "connectionEpoch + catalogRevision + displayIndex",
        "catalogOwner": "Rust Bridge normalized PeerInfo displays",
        "selectionOwner": "one Rust Bridge pending command per connection epoch",
        "inventoryIngress": {
            "initial": "set_peer_info installs displays and current_display atomically",
            "dynamic": "set_displays replaces inventory without trusting compatibility current_display",
            "remoteFollow": "set_current_display updates selected index without a local command",
            "remoteEcho": "switch_display updates geometry and resolves an exact pending command",
        },
        "selectionRequest": [
            "abiVersion",
            "connectionEpoch",
            "commandId",
            "catalogRevision",
            "displayIndex",
        ],
        "completionAuthority": (
            "matching remote SwitchDisplay echo under the unchanged catalog revision"
        ),
        "selectionRules": {
            "positiveUniqueCommandID": True,
            "atMostOnePendingCommand": True,
            "sameSelectedIndexEmitsAlreadySelectedEventWithoutWireSend": True,
            "functionReturnMeansAdmissionOnly": True,
            "everyAdmittedCommandGetsOneTerminalEvent": True,
            "disconnectOrCatalogChangeFailsPendingCommand": True,
        },
        "inventoryRules": {
            "maximumEntries": 64,
            "maximumNameUTF8Bytes": 512,
            "displayNameIsPresentationOnlyNeverIdentity": True,
            "displayNameMustNotEnterDiagnostics": True,
            "rejectPartialOrMalformedCatalog": True,
            "semanticDuplicateKeepsRevision": True,
            "semanticChangeAdvancesRevision": True,
            "catalogChangeTerminatesPendingSelection": True,
        },
        "frameBinding": (
            "connectionEpoch + catalogRevision + selected displayIndex; "
            "Swift drops mismatched frames"
        ),
        "inputBoundary": (
            "release and pause Viewer input while selection is pending; resume only "
            "after matching terminal success"
        ),
        "hostValidation": (
            "reject negative, offline, non-positive geometry, or out-of-range display "
            "before changing service subscription"
        ),
        "revisionSeparation": (
            "Viewer catalogRevision is not Host media displayRevision and not the "
            "Host input-mapping generation"
        ),
    }

    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "host-validation-implemented-product-pending"
            if not missing_evidence and not missing_gaps
            else "audit-drift"
        ),
        "pinnedRustDeskCommit": PINNED_RUSTDESK_COMMIT,
        "currentABI": {"viewer": viewer_abi, "host": host_abi},
        "authoritativeOwners": {
            "inventory": "pinned RustDesk display service PeerInfo",
            "selection": "pinned RustDesk client Session and Host connection",
            "mediaRoute": "pinned RustDesk monitor video service",
            "inputMapping": "Host connection-scoped generation",
        },
        "evidence": evidence,
        "gaps": gaps,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingGaps": missing_gaps,
        "targetContract": target_contract,
        "claims": {
            "currentMultiDisplayProductComplete": False,
            "viewerABIChangeRequired": False,
            "hostABIChangeRequired": False,
            "hostWireSchemaChangeRequired": False,
            "hermesChangeRequired": False,
            "installedTwoMacAcceptanceStillRequired": True,
        },
        "nextImplementationBoundary": "viewer-display-selection-input-quiescence-lifecycle",
    }
    print(json.dumps(document, sort_keys=True))
    return 0 if (
        not missing_evidence
        and not missing_gaps
        and all(source_lines.values())
        and viewer_abi == 16
        and host_abi == 17
    ) else 1


if __name__ == "__main__":
    sys.exit(main())
