#!/usr/bin/env python3
"""Audit H6.3f2b2t3 Host Home receive-root opt-in lifecycle."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-host-home-receive-root-opt-in-lifecycle-audit"
NEXT_BOUNDARY = "host-file-transfer-product-development-completion-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def ordered(source: str, *markers: str) -> bool:
    cursor = 0
    for marker in markers:
        offset = source.find(marker, cursor)
        if offset < 0:
            return False
        cursor = offset + len(marker)
    return True


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "configuration": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfiguration.swift",
        "provisioner": repository / "Sources/CoreBridge/HostFileTransferReceiveRootProvisioner.swift",
        "routing": repository / "Sources/CoreBridge/HostAgentBackgroundHomeRoutingPolicy.swift",
        "dialogs": repository / "Sources/RustDeskNative/HostFileTransferDialogs.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "provisioner_tests": repository / "Tests/CoreBridgeTests/HostFileTransferReceiveRootProvisionerTests.swift",
        "routing_tests": repository / "Tests/CoreBridgeTests/HostAgentBackgroundHomeRoutingPolicyTests.swift",
        "configuration_tests": repository / "Tests/ConnectionCatalogTests/HostAgentBootstrapConfigurationTests.swift",
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

    app = sources["app"]
    home = sources["home"]
    provisioner = sources["provisioner"]
    disable = app[
        app.find("    private func handleHostFileTransferPolicyToggle"):
        app.find("    private func beginHostFileTransferReceiveRootSelection")
    ]
    selection = app[
        app.find("    private func beginHostFileTransferReceiveRootSelection"):
        app.find("    @MainActor\n    private func hostFileTransferPolicyChangeAllowed")
    ]
    evidence = {
        "designRecordsBoundedHomeOptIn": (
            "H6.3f2b2t3 Host Home receive-root opt-in lifecycle"
            in sources["design"]
        ),
        "preferenceIsAbsentMeansOffAndPathValidated": all(
            marker in app
            for marker in (
                "farpane.host.fileTransfer.enabled",
                "farpane.host.fileTransfer.receiveRoot",
                "private func currentHostFileTransferPolicy()",
                "HostAgentFileTransferPolicy.validatedEnabled(",
                "return .disabled",
            )
        ),
        "pickerIsDirectoryOnlyExplicitAndAliasClosed": all(
            marker in sources["dialogs"]
            for marker in (
                "panel.canChooseFiles = false",
                "panel.canChooseDirectories = true",
                "panel.allowsMultipleSelection = false",
                "panel.resolvesAliases = false",
                "FarPane Receive",
            )
        ),
        "fixedChildProvisioningIsDescriptorRelativePrivate": all(
            marker in provisioner
            for marker in (
                'receiveDirectoryName = "FarPane Receive"',
                "O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC",
                "Darwin.mkdirat(parentDescriptor, name, mode_t(0o700))",
                "Darwin.openat(",
                "parentStatus.st_mode & mode_t(0o022) == 0",
                "childStatus.st_mode & mode_t(0o777) == mode_t(0o700)",
            )
        ),
        "cancelRejectAndDisableRemainFailClosed": (
            "case .cancelled:" in selection
            and "case .rejected:" in selection
            and ordered(
                disable,
                "Self.hostFileTransferEnabledDefaultsKey",
                "Self.hostFileTransferReceiveRootDefaultsKey",
                "reconcileHostAgentBootstrap()",
            )
        ),
        "enablePublishesRootBeforePermission": ordered(
            selection,
            "Self.hostFileTransferReceiveRootDefaultsKey",
            "Self.hostFileTransferEnabledDefaultsKey",
            "reconcileHostAgentBootstrap()",
        ),
        "policyChangesRequireHostOffAndNoViewerStart": (
            "allowsFileTransferPolicyChange(" in sources["routing"]
            and "allowsClipboardPolicyChange(" in sources["routing"]
            and "testFileTransferPolicyChangesUseTheSameHostOffGate"
                in sources["routing_tests"]
        ),
        "homeShowsExplicitDefaultOffControlWithoutFullPath": all(
            marker in home
            for marker in (
                "文件接收（默认关闭）",
                "onHostFileTransferToggle",
                "onChooseHostFileTransferReceiveRoot",
                "fileTransferReceiveRootName",
                "snapshot.host.allowsFileTransferPolicyChange",
            )
        ) and "fileTransferReceiveRoot: String" not in home,
        "backgroundAndLegacyOwnersUseSamePolicy": all(
            marker in app + sources["agent"]
            for marker in (
                "fileTransferPolicy: currentHostFileTransferPolicy()",
                "fileTransferEnabled: fileTransferPolicy.enabled",
                "fileTransferReceiveRoot: fileTransferPolicy.receiveRoot",
                "configuration.fileTransferPolicy.enabled",
                "configuration.fileTransferPolicy.receiveRoot",
            )
        ),
        "regressionsCoverPolicyProvisioningAndProductRoutes": all(
            marker in (
                sources["configuration_tests"]
                + sources["provisioner_tests"]
                + sources["routing_tests"]
            )
            for marker in (
                "testBuildsOnlyCanonicalEnabledFileTransferPolicy",
                "testCreatesPrivateFixedChildAndIsIdempotent",
                "testRejectsUnsafeParentAndExistingChildWithoutChangingThem",
                "testFileTransferHomeOptInUsesOnePolicyForBothHostOwners",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            sources["design"],
            "H6.3f2b2t3 Host Home receive-root opt-in lifecycle",
        ),
        "preference": line_number(app, "farpane.host.fileTransfer.enabled"),
        "picker": line_number(
            sources["dialogs"], "final class HostFileTransferReceiveRootPickerController"
        ),
        "provisioner": line_number(
            provisioner, "package enum HostFileTransferReceiveRootProvisioner"
        ),
        "homeControl": line_number(home, "文件接收（默认关闭）"),
        "policyGate": line_number(
            sources["routing"], "allowsFileTransferPolicyChange("
        ),
        "bootstrapProjection": line_number(
            app, "fileTransferPolicy: currentHostFileTransferPolicy()"
        ),
        "legacyProjection": line_number(
            app, "fileTransferEnabled: fileTransferPolicy.enabled"
        ),
        "agentProjection": line_number(
            sources["agent"], "configuration.fileTransferPolicy.enabled"
        ),
    }
    missing_evidence = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, line in source_lines.items() if line == 0]
    passed = not missing_evidence and not missing_lines
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": (
            "host-home-receive-root-opt-in-implemented"
            if passed else "audit-failed"
        ),
        "coverageScope": "h6-host-file-transfer-host-home-receive-root-opt-in-lifecycle",
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing_evidence,
        "missingSourceLines": missing_lines,
        "claims": {
            "hostFileTransferEnabledByDefault": False,
            "explicitHomeOptInImplemented": passed,
            "privateReceiveRootProvisioningImplemented": passed,
            "backgroundHostProjectionImplemented": passed,
            "legacyHostProjectionImplemented": passed,
            "installedSingleMacSmokeComplete": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": NEXT_BOUNDARY,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
