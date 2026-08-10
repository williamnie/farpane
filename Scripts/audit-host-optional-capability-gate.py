#!/usr/bin/env python3
"""Audit FarPane Host optional data-bearing capability defaults."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-optional-capability-gate-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "readme": repository / "README.md",
        "host_bridge": (
            repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs"
        ),
        "vendor_host_bridge": (
            repository / "Vendor/rustdesk/src/rdn_host_bridge.rs"
        ),
        "connection": (
            repository / "Vendor/rustdesk/src/server/connection.rs"
        ),
        "config": (
            repository / "Vendor/rustdesk/libs/hbb_common/src/config.rs"
        ),
        "clipboard": repository / "Vendor/rustdesk/src/clipboard.rs",
        "viewer_bridge": (
            repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs"
        ),
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

    design = sources["design"]
    readme = sources["readme"]
    host_bridge = sources["host_bridge"]
    connection = sources["connection"]
    config = sources["config"]
    clipboard = sources["clipboard"]
    viewer_bridge = sources["viewer_bridge"]
    apply_offset = host_bridge.find(
        "apply_native_host_optional_capability_defaults();"
    )
    identity_offset = host_bridge.find("host.local_id = config::Config::get_id();")

    evidence = {
        "designRequiresIndependentClipboardGate": all(
            marker in design
            for marker in (
                "read/write 分权",
                "默认支持小型文本",
                "fallback 轮询必须动态退避",
                "采用独立功能开关和阶段门禁",
            )
        ),
        "productClaimsOptionalDataCapabilitiesDisabled": (
            "音频、剪贴板和文件传输默认关闭" in readme
            and "Audio, clipboard, and file transfer default to disabled"
            in readme
        ),
        "upstreamMissingEnableOptionDefaultsOn": all(
            marker in config
            for marker in (
                'if option.starts_with("enable-")',
                'value != "N"',
                'pub const OPTION_ENABLE_CLIPBOARD: &str = "enable-clipboard"',
            )
        ),
        "hostPinsOptionalDataCapabilitiesOffBeforeIdentity": (
            all(
                marker in host_bridge
                for marker in (
                    "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS",
                    "OPTION_ENABLE_CLIPBOARD",
                    "OPTION_ENABLE_FILE_TRANSFER",
                    "OPTION_ENABLE_AUDIO",
                    'Config::set_option(key.to_owned(), "N".to_owned())',
                )
            )
            and apply_offset >= 0
            and identity_offset >= 0
            and apply_offset < identity_offset
        ),
        "hostRequiresPersistedDefaultOffReadback": all(
            marker in host_bridge
            for marker in (
                '(config::keys::OPTION_ENABLE_CLIPBOARD, "N")',
                '(config::keys::OPTION_ENABLE_FILE_TRANSFER, "N")',
                '(config::keys::OPTION_ENABLE_AUDIO, "N")',
                "PersistenceMismatch",
            )
        ),
        "canonicalAndVendoredHostBridgeMatch": (
            sources["host_bridge"] == sources["vendor_host_bridge"]
        ),
        "connectionGatesBothClipboardDirections": all(
            marker in host_bridge + connection
            for marker in (
                "self.clipboard && !self.disable_clipboard",
                "active_policy().allows_remote_read()",
                "native_host_allows_remote_clipboard_write(",
            )
        ),
        "readWritePolicyIsIndependent": all(
            marker in host_bridge
            for marker in (
                "struct NativeClipboardPolicy",
                "remote_read: bool",
                "remote_write: bool",
                'names.push("readClipboard")',
                'names.push("writeClipboard")',
            )
        ),
        "RichPayloadAndBackoffGatesStillMissing": all(
            marker in clipboard
            for marker in (
                "pub const CLIPBOARD_INTERVAL: u64 = 333",
                "ClipboardFormat::ImageRgba",
                "ClipboardFormat::ImagePng",
                "decompress(&clipboard.content)",
            )
        ),
        "nativeViewerClipboardRemainsDisabled": (
            "server_clipboard_enabled: Arc::new(RwLock::new(false))"
            in viewer_bridge
            and "rdn_client_send_clipboard" not in viewer_bridge
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    source_lines = {
        "designClipboardPolicy": line_number(design, "### 12.2 剪贴板"),
        "upstreamEnableDefault": line_number(
            config, 'if option.starts_with("enable-")'
        ),
        "hostDefaultOffKeys": line_number(
            host_bridge, "NATIVE_HOST_DEFAULT_DISABLED_OPTION_KEYS"
        ),
        "hostDefaultOffApplication": line_number(
            host_bridge,
            "apply_native_host_optional_capability_defaults();",
        ),
        "hostReadback": line_number(
            host_bridge, '(config::keys::OPTION_ENABLE_CLIPBOARD, "N")'
        ),
        "connectionClipboardGate": line_number(
            connection, "self.clipboard && !self.disable_clipboard"
        ),
        "fixedClipboardInterval": line_number(
            clipboard, "pub const CLIPBOARD_INTERVAL: u64 = 333"
        ),
        "unboundedDecompression": line_number(
            clipboard, "decompress(&clipboard.content)"
        ),
        "viewerClipboardDisabled": line_number(
            viewer_bridge,
            "server_clipboard_enabled: Arc::new(RwLock::new(false))",
        ),
    }
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "optional-data-capabilities-default-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-optional-data-capability-defaults",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "clipboardEnabled": False,
            "richClipboardImplemented": False,
            "fileTransferEnabled": False,
            "systemAudioEnabled": False,
        },
        "remainingBoundary": {
            "independentRevocationCommandsRequired": False,
            "directionalXPCUIRequired": False,
            "eventDrivenDynamicBackoffRequired": False,
            "temporaryObjectCleanupRequired": False,
            "explicitProductEnablementRequired": True,
        },
        "nextImplementationBoundary": "viewer-small-text-clipboard-api-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "optional-data-capabilities-default-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
