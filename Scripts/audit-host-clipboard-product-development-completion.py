#!/usr/bin/env python3
"""Audit H6.2 development completion without claiming two-Mac acceptance."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-clipboard-product-development-completion-audit"
REQUIRED_AUDITS = {
    "audit-host-optional-capability-gate.py": (
        "farpane-host-optional-capability-gate-audit",
        "optional-data-capabilities-default-off",
    ),
    "audit-host-clipboard-policy-contract.py": (
        "farpane-host-clipboard-policy-contract-audit",
        "clipboard-read-write-policy-contract",
    ),
    "audit-host-clipboard-data-plane-gate.py": (
        "farpane-host-clipboard-data-plane-gate-audit",
        "bounded-small-text-directional-gates",
    ),
    "audit-host-clipboard-directional-revoke-contract.py": (
        "farpane-host-clipboard-directional-revoke-contract-audit",
        "independent-directional-revoke-core-contract",
    ),
    "audit-host-clipboard-directional-xpc-ui-contract.py": (
        "farpane-host-clipboard-directional-xpc-ui-contract-audit",
        "directional-revoke-xpc-home-contract",
    ),
    "audit-host-clipboard-event-backoff-contract.py": (
        "farpane-host-clipboard-event-backoff-contract-audit",
        "event-first-bounded-macos-fallback",
    ),
    "audit-host-clipboard-temporary-object-cleanup-contract.py": (
        "farpane-host-clipboard-temporary-object-cleanup-contract-audit",
        "temporary-clipboard-objects-cleaned-on-teardown",
    ),
    "audit-viewer-clipboard-small-text-api-contract.py": (
        "farpane-viewer-small-text-clipboard-api-contract-audit",
        "viewer-small-text-clipboard-api-default-off",
    ),
    "audit-viewer-pasteboard-owner-explicit-enablement.py": (
        "farpane-viewer-pasteboard-owner-explicit-enablement-audit",
        "viewer-pasteboard-owner-explicitly-enabled",
    ),
    "audit-host-clipboard-explicit-policy-abi-contract.py": (
        "farpane-host-clipboard-explicit-policy-abi-contract-audit",
        "host-clipboard-explicit-policy-abi-ready-default-off",
    ),
    "audit-host-clipboard-bootstrap-home-opt-in-contract.py": (
        "farpane-host-clipboard-bootstrap-home-opt-in-contract-audit",
        "host-clipboard-bootstrap-home-opt-in-ready",
    ),
    "audit-host-clipboard-rich-transfer-boundary.py": (
        "farpane-host-clipboard-rich-transfer-boundary-audit",
        "rich-payload-independent-transfer-boundary",
    ),
    "audit-host-clipboard-bounded-rich-text-envelope.py": (
        "farpane-host-clipboard-bounded-rich-text-envelope-audit",
        "bounded-rich-text-envelope-contract",
    ),
    "audit-viewer-clipboard-rich-text-api-contract.py": (
        "farpane-viewer-rich-text-clipboard-api-contract-audit",
        "viewer-rich-text-clipboard-api-default-off",
    ),
    "audit-host-viewer-rich-text-transfer-wiring-contract.py": (
        "farpane-host-viewer-rich-text-transfer-wiring-contract-audit",
        "host-viewer-rich-text-transfer-wired-default-off",
    ),
    "audit-viewer-rich-text-pasteboard-owner-explicit-enablement.py": (
        "farpane-viewer-rich-text-pasteboard-owner-explicit-enablement-audit",
        "viewer-rich-text-pasteboard-owner-explicitly-enabled",
    ),
    "audit-host-rich-text-bootstrap-home-opt-in-contract.py": (
        "farpane-host-rich-text-bootstrap-home-opt-in-contract-audit",
        "host-rich-text-bootstrap-home-opt-in-ready",
    ),
    "audit-host-clipboard-bounded-image-envelope.py": (
        "farpane-host-clipboard-bounded-image-envelope-audit",
        "bounded-image-envelope-contract",
    ),
    "audit-viewer-clipboard-image-api-contract.py": (
        "farpane-viewer-image-clipboard-api-contract-audit",
        "viewer-image-clipboard-api-default-off",
    ),
    "audit-host-viewer-image-transfer-wiring-contract.py": (
        "farpane-host-viewer-image-transfer-wiring-contract-audit",
        "host-viewer-image-transfer-wired-viewer-enabled",
    ),
    "audit-viewer-image-pasteboard-owner-explicit-enablement.py": (
        "farpane-viewer-image-pasteboard-owner-explicit-enablement-audit",
        "viewer-image-pasteboard-owner-explicitly-enabled",
    ),
    "audit-host-image-bootstrap-home-opt-in-contract.py": (
        "farpane-host-image-bootstrap-home-opt-in-contract-audit",
        "host-image-bootstrap-home-opt-in-ready",
    ),
}


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
        missing_lists_are_empty = all(
            not value
            for key, value in document.items()
            if key.startswith("missing") and isinstance(value, list)
        )
        if (
            completed.returncode != 0
            or not isinstance(document, dict)
            or document.get("schema") != schema
            or document.get("status") != status
            or not missing_lists_are_empty
        ):
            raise ValueError(f"required clipboard audit failed: {script}")
        documents[script] = document
    return documents


def audits_present(audits: dict[str, dict[str, object]], names: tuple[str, ...]) -> bool:
    return set(names).issubset(audits)


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "viewer_control": repository / "Sources/CoreBridge/CoreBridge.swift",
        "bootstrap": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "polling": repository / "Sources/CoreBridge/ViewerClipboardPollingState.swift",
        "pasteboard": repository / "Sources/RustDeskNative/ViewerPasteboardOwner.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
    }
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

    small_text_audits = (
        "audit-host-clipboard-policy-contract.py",
        "audit-host-clipboard-data-plane-gate.py",
        "audit-viewer-clipboard-small-text-api-contract.py",
        "audit-viewer-pasteboard-owner-explicit-enablement.py",
    )
    rich_text_audits = (
        "audit-host-clipboard-rich-transfer-boundary.py",
        "audit-host-clipboard-bounded-rich-text-envelope.py",
        "audit-viewer-clipboard-rich-text-api-contract.py",
        "audit-host-viewer-rich-text-transfer-wiring-contract.py",
        "audit-viewer-rich-text-pasteboard-owner-explicit-enablement.py",
        "audit-host-rich-text-bootstrap-home-opt-in-contract.py",
    )
    image_audits = (
        "audit-host-clipboard-bounded-image-envelope.py",
        "audit-viewer-clipboard-image-api-contract.py",
        "audit-host-viewer-image-transfer-wiring-contract.py",
        "audit-viewer-image-pasteboard-owner-explicit-enablement.py",
        "audit-host-image-bootstrap-home-opt-in-contract.py",
    )
    lifecycle_audits = (
        "audit-host-clipboard-directional-revoke-contract.py",
        "audit-host-clipboard-directional-xpc-ui-contract.py",
        "audit-host-clipboard-event-backoff-contract.py",
        "audit-host-clipboard-temporary-object-cleanup-contract.py",
    )

    host_product = all(marker in sources["bootstrap"] + sources["home"] + sources["app"] + sources["agent"] for marker in (
        "public struct HostAgentClipboardPolicy",
        "剪贴板同步（默认关闭）",
        "allowRemoteRichTextRead",
        "allowRemoteImageWrite",
        "clipboardPolicy: currentHostClipboardPolicy()",
        "configuration.clipboardPolicy",
        ".allowRemoteImageRead",
    ))
    viewer_product = all(marker in sources["viewer_control"] + sources["pasteboard"] + sources["app"] for marker in (
        "receiveClipboardText: Bool = false",
        "receiveClipboardRichText: Bool = false",
        "receiveClipboardImage: Bool = false",
        "final class ViewerPasteboardOwner",
        "viewerPasteboardOwner.begin(",
        "viewerPasteboardOwner.receiveRemoteImage(",
        "viewerPasteboardOwner.stop(sessionEpoch:",
    ))
    bounded_payloads = all(marker in sources["host_bridge"] + sources["viewer_bridge"] + sources["polling"] for marker in (
        "MAX_CLIPBOARD_TEXT_UTF8_BYTES: usize = 64 * 1024",
        "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES: usize = 1024 * 1024",
        "MAX_CLIPBOARD_IMAGE_BYTES: usize = 128 * 1024 * 1024",
        "MAX_CLIPBOARD_SVG_UTF8_BYTES: usize = 4 * 1024 * 1024",
        "maximumRichTextUTF8Bytes = 1024 * 1024",
        "maximumImageBytes = maximumClipboardImageBytes",
    ))
    directional_policy = all(marker in sources["header"] + sources["host_bridge"] + sources["host_control"] + sources["home"] for marker in (
        "enable_clipboard_read;",
        "enable_clipboard_write;",
        "pub(crate) struct NativeClipboardPolicy",
        "disableClipboardReadForActiveSession",
        "disableClipboardWriteForActiveSession",
        "停止远端读取",
        "停止远端写入",
    ))
    event_and_cleanup = all(marker in sources["polling"] + sources["pasteboard"] for marker in (
        "productDelaysMilliseconds",
        "observeOwnedWrite",
        "timer?.invalidate()",
        "private var active = false",
    ))
    evidence = {
        "designDefinesIndependentBoundedClipboardCapability": all(marker in sources["design"] for marker in (
            "H6.2 剪贴板富类型",
            "read/write 分权、大小上限、事件驱动优先、轮询动态退避",
            "任何来自远端的文件名、UTI 和 payload 均视为不可信输入",
        )),
        "allStagedClipboardAuditsPass": len(audits) == len(REQUIRED_AUDITS),
        "smallTextProductChainImplemented": audits_present(audits, small_text_audits),
        "richTextProductChainImplemented": audits_present(audits, rich_text_audits),
        "imageProductChainImplemented": audits_present(audits, image_audits),
        "directionalRevokeBackoffAndCleanupImplemented": audits_present(audits, lifecycle_audits),
        "hostDefaultOffBootstrapHomeAndRuntimeProjectionImplemented": host_product,
        "viewerExplicitSessionScopedPasteboardOwnerImplemented": viewer_product,
        "allClipboardPayloadFamiliesAreBounded": bounded_payloads,
        "readWritePolicyAndSessionRevokeRemainIndependent": directional_policy,
        "eventFirstOwnerUsesBoundedFallbackAndTeardown": event_and_cleanup,
        "abiVersionsMatchImplementedContract": viewer_abi == 18 and host_abi == 19,
    }
    source_lines = {
        "designRequirement": line_number(sources["design"], "H6.2 剪贴板富类型"),
        "hostPolicyABI": line_number(sources["header"], "enable_clipboard_read;"),
        "viewerTextABI": line_number(sources["header"], "receive_clipboard_text;"),
        "viewerRichTextABI": line_number(sources["header"], "receive_clipboard_rich_text;"),
        "viewerImageABI": line_number(sources["header"], "receive_clipboard_image;"),
        "hostPolicyOwner": line_number(sources["host_bridge"], "pub(crate) struct NativeClipboardPolicy"),
        "hostRichTextBound": line_number(sources["host_bridge"], "MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES"),
        "viewerImageBound": line_number(sources["viewer_bridge"], "MAX_CLIPBOARD_IMAGE_BYTES"),
        "hostBootstrap": line_number(sources["bootstrap"], "public struct HostAgentClipboardPolicy"),
        "hostHome": line_number(sources["home"], "剪贴板同步（默认关闭）"),
        "viewerOwner": line_number(sources["pasteboard"], "final class ViewerPasteboardOwner"),
        "viewerProductWiring": line_number(sources["app"], "viewerPasteboardOwner.begin("),
        "viewerTeardown": line_number(sources["app"], "viewerPasteboardOwner.stop(sessionEpoch:"),
        "fallbackBackoff": line_number(sources["polling"], "productDelaysMilliseconds"),
    }
    remaining_gaps = [name for name, present in evidence.items() if not present]
    complete = not remaining_gaps and all(source_lines.values())
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "product-development-complete" if complete else "audit-failed",
        "coverageScope": "h6-2-clipboard-product-development-completion",
        "currentABI": {"viewer": viewer_abi, "host": host_abi},
        "requiredAudits": sorted(REQUIRED_AUDITS),
        "evidence": evidence,
        "sourceLines": source_lines,
        "claims": {
            "hostClipboardProductImplemented": host_product and directional_policy,
            "viewerClipboardProductImplemented": viewer_product,
            "smallTextRichTextAndImageImplemented": (
                evidence["smallTextProductChainImplemented"]
                and evidence["richTextProductChainImplemented"]
                and evidence["imageProductChainImplemented"]
            ),
            "clipboardProductDevelopmentComplete": complete,
            "installedCurrentBuildSingleMacSmokeComplete": False,
            "dualMacClipboardAcceptanceComplete": False,
        },
        "remainingDevelopmentGaps": remaining_gaps,
        "nonBlockingAcceptanceGaps": [
            "installedCurrentBuildSingleMacPasteboardSmoke",
            "dualMacSmallTextRoundTrip",
            "dualMacRichTextRoundTrip",
            "dualMacImageRoundTrip",
            "directionalRevokeAndReconnect",
            "crossMachinePerformanceAndInteroperability",
        ],
        "nextImplementationBoundary": "host-mode-development-completion-audit",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
