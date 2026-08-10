#!/usr/bin/env python3
"""Audit the H6.2d2 clipboard directional XPC and Home contract."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-clipboard-directional-xpc-ui-contract-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "wire": repository / "Sources/CoreBridge/HostAgentXPCWireCommand.swift",
        "adapter": repository
        / "Sources/CoreBridge/HostAgentXPCCommandExecutionAdapter.swift",
        "route": repository
        / "Sources/CoreBridge/HostAgentBackgroundCommandRoute.swift",
        "policy": repository
        / "Sources/CoreBridge/HostAgentBackgroundHomeCommandPolicy.swift",
        "routing": repository
        / "Sources/CoreBridge/HostAgentHomeCommandRoutingPolicy.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "wire_tests": repository
        / "Tests/CoreBridgeTests/HostAgentXPCWireCommandTests.swift",
        "adapter_tests": repository
        / "Tests/CoreBridgeTests/HostAgentXPCCommandExecutionAdapterTests.swift",
        "policy_tests": repository
        / "Tests/CoreBridgeTests/HostAgentBackgroundHomeCommandPolicyTests.swift",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
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
    wire = sources["wire"]
    adapter = sources["adapter"]
    route = sources["route"]
    policy = sources["policy"]
    routing = sources["routing"]
    home = sources["home"]
    app = sources["app"]
    wire_tests = sources["wire_tests"]
    adapter_tests = sources["adapter_tests"]
    policy_tests = sources["policy_tests"]
    bridge = sources["bridge"]

    evidence = {
        "designRecordsBoundedH6Step": all(
            marker in design
            for marker in (
                "H6.2d2 directional revoke XPC and Home contract",
                "event-first/dynamic-backoff",
            )
        ),
        "commandSchemaTwoFreezesDirectionalNames": all(
            marker in wire
            for marker in (
                "currentSchemaVersion: UInt64 = 2",
                "case disableClipboardReadForActiveSession",
                "case disableClipboardWriteForActiveSession",
            )
        ),
        "olderAndFutureCommandSchemasFailClosed": all(
            marker in wire_tests
            for marker in (
                'merging(valid, ["schemaVersion": 1])',
                'merging(valid, ["schemaVersion": 3])',
            )
        ),
        "xpcExecutionMapsDirectionsExactly": all(
            marker in adapter + adapter_tests
            for marker in (
                "case .disableClipboardReadForActiveSession:",
                "return .disable(.clipboardRead)",
                "case .disableClipboardWriteForActiveSession:",
                "return .disable(.clipboardWrite)",
            )
        ),
        "backgroundRoutingTargetsActiveSession": all(
            marker in route + routing
            for marker in (
                ".disableClipboardReadForActiveSession",
                ".disableClipboardWriteForActiveSession",
                ".disableClipboardRead,",
                ".disableClipboardWrite,",
            )
        ),
        "presentationDerivesDirectionsIndependently": all(
            marker in policy
            for marker in (
                'capabilities.contains("readClipboard")',
                "action: .disableClipboardRead",
                'capabilities.contains("writeClipboard")',
                "action: .disableClipboardWrite",
            )
        ),
        "currentPresentationDoesNotOfferLegacyDualAction": (
            "action: .disableClipboard," not in policy.split(
                "private static func connectionID", 1
            )[0]
        ),
        "homeExposesDistinctButtonsAndAccessibilityLabels": all(
            marker in home
            for marker in (
                "hostDisableClipboardReadButton",
                "hostDisableClipboardWriteButton",
                "#selector(disableHostSessionClipboardRead)",
                "#selector(disableHostSessionClipboardWrite)",
                "停止当前会话读取本机剪贴板",
                "停止当前会话写入本机剪贴板",
            )
        ),
        "productOwnerMapsDirectionsWithoutCollapsing": all(
            marker in app
            for marker in (
                "case .disable(.clipboardRead): pendingAction = .disableClipboardRead",
                "case .disable(.clipboardWrite): pendingAction = .disableClipboardWrite",
                "case .disableClipboardRead: return .disableClipboardRead",
                "case .disableClipboardWrite: return .disableClipboardWrite",
                "重试停止远端读取剪贴板",
                "重试停止远端写入剪贴板",
            )
        ),
        "readOnlyAndWriteOnlyRegressionExists": all(
            marker in policy_tests
            for marker in (
                "testClipboardDirectionsExposeAndSubmitIndependently",
                "activeCapabilities: [\"viewDisplay\", \"readClipboard\"]",
                "activeCapabilities: [\"viewDisplay\", \"writeClipboard\"]",
                ".disableClipboardReadForActiveSession",
                ".disableClipboardWriteForActiveSession",
            )
        ),
        "legacyBidirectionalWireRemainsAccepted": all(
            marker in wire + adapter + policy
            for marker in (
                "case disableClipboardForActiveSession",
                "case .disableClipboardForActiveSession:",
                "return .disable(.clipboard)",
                "case .disableClipboard:",
                "return .disableClipboardForActiveSession",
            )
        ),
        "clipboardProductDefaultRemainsOff": all(
            marker in bridge
            for marker in (
                "native_host_clipboard_option(NativeClipboardPolicy::default())",
                "config::keys::OPTION_ENABLE_CLIPBOARD",
                'config::Config::set_option(key.to_owned(), "N".to_owned())',
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.2d2 directional revoke XPC and Home contract"
        ),
        "commandSchema": line_number(
            wire, "currentSchemaVersion: UInt64 = 2"
        ),
        "readWireCommand": line_number(
            wire, "case disableClipboardReadForActiveSession"
        ),
        "writeWireCommand": line_number(
            wire, "case disableClipboardWriteForActiveSession"
        ),
        "readCoreMapping": line_number(
            adapter, "case .disableClipboardReadForActiveSession:"
        ),
        "writeCoreMapping": line_number(
            adapter, "case .disableClipboardWriteForActiveSession:"
        ),
        "readHomeTarget": line_number(
            policy, "action: .disableClipboardRead"
        ),
        "writeHomeTarget": line_number(
            policy, "action: .disableClipboardWrite"
        ),
        "readHomeButton": line_number(
            home, "#selector(disableHostSessionClipboardRead)"
        ),
        "writeHomeButton": line_number(
            home, "#selector(disableHostSessionClipboardWrite)"
        ),
        "directionalRegression": line_number(
            policy_tests, "testClipboardDirectionsExposeAndSubmitIndependently"
        ),
        "defaultOffGate": line_number(
            bridge, "native_host_clipboard_option(NativeClipboardPolicy::default())"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "directional-revoke-xpc-home-contract"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-directional-revoke-xpc-home",
        "status": status,
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_lines,
        "claims": {
            "commandSchemaTwoImplemented": True,
            "directionalXPCImplemented": True,
            "directionalHomeControlsImplemented": True,
            "legacyBidirectionalAliasPreserved": True,
            "clipboardEnabledByDefault": False,
        },
        "remainingBoundary": {
            "eventDrivenDynamicBackoffRequired": False,
            "temporaryObjectCleanupRequired": False,
            "viewerSmallTextClipboardAPIRequired": False,
            "explicitProductEnablementRequired": True,
            "physicalUIAcceptanceRequired": True,
        },
        "nextImplementationBoundary": "viewer-pasteboard-owner-and-explicit-enablement-contract",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "directional-revoke-xpc-home-contract" else 1


if __name__ == "__main__":
    raise SystemExit(main())
