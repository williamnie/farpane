#!/usr/bin/env python3
"""Audit H6.4 development completion without claiming installed/two-Mac acceptance."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-multi-display-product-development-completion-audit"
OWNERSHIP_SCHEMA = "farpane-host-multi-display-selection-ownership-audit"


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


def run_ownership_audit(repository: Path) -> dict[str, object]:
    completed = subprocess.run(
        ["python3", "Scripts/audit-host-multi-display-selection-ownership.py"],
        cwd=repository,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    document = json.loads(completed.stdout)
    if completed.returncode != 0 or not isinstance(document, dict):
        raise ValueError("multi-display ownership audit failed")
    return document


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "viewer_bridge": repository / "CoreBridge/RustDeskPatch/rdn_bridge.rs",
        "host_connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "swift_bridge": repository / "Sources/CoreBridge/CoreBridge.swift",
        "input_owner": repository / "Sources/CoreBridge/ViewerDisplaySelectionInputOwner.swift",
        "presentation": repository / "Sources/CoreBridge/ViewerDisplaySelectionPresentation.swift",
        "viewer_view": repository / "Sources/RustDeskNative/ViewerMetalView.swift",
        "keyboard": repository / "Sources/RustDeskNative/ExclusiveKeyboardController.swift",
        "viewer_ui": repository / "Sources/RustDeskNative/ViewerUI.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "catalog_tests": repository / "Tests/CoreBridgeTests/ViewerDisplayCatalogTests.swift",
        "selection_tests": repository / "Tests/CoreBridgeTests/ViewerDisplaySelectionTests.swift",
        "input_tests": repository / "Tests/CoreBridgeTests/ViewerDisplaySelectionInputOwnerTests.swift",
    }
    evidence_paths = tuple(
        repository / "Evidence/HostMode/2026-08-11" / name
        for name in (
            "h6-multi-display-selection-ownership-audit.md",
            "h6-viewer-display-catalog-abi-contract.md",
            "h6-viewer-display-selection-command-lifecycle.md",
            "h6-host-display-switch-validation-lifecycle.md",
            "h6-viewer-display-selection-input-quiescence-lifecycle.md",
            "h6-viewer-display-selector-product-lifecycle.md",
        )
    )
    try:
        sources = {name: read(path) for name, path in paths.items()}
        ownership = run_ownership_audit(repository)
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

    ownership_evidence = ownership.get("evidence", {})
    ownership_source_lines = ownership.get("sourceLines", {})
    ownership_passes = (
        ownership.get("schema") == OWNERSHIP_SCHEMA
        and ownership.get("status") == "selector-implemented-development-audit-pending"
        and isinstance(ownership_evidence, dict)
        and bool(ownership_evidence)
        and all(ownership_evidence.values())
        and isinstance(ownership_source_lines, dict)
        and bool(ownership_source_lines)
        and all(ownership_source_lines.values())
        and ownership.get("gaps") == {}
        and ownership.get("missingEvidence") == []
        and ownership.get("missingGaps") == []
    )

    catalog = all(marker in sources["viewer_bridge"] + sources["swift_bridge"] for marker in (
        "fn publish_display_catalog(&self, displays: &[DisplayInfo]",
        "public struct CoreDisplayCatalogEvent",
        "display_catalog_revision",
        "connection_epoch",
    ))
    selection = all(marker in sources["viewer_bridge"] + sources["swift_bridge"] for marker in (
        "pending_selection: Option<NativeViewerDisplaySelectionPending>",
        "pub unsafe extern \"C\" fn rdn_client_select_display(",
        "public struct CoreDisplaySelectionRequest",
        "public func selectDisplay(_ request: CoreDisplaySelectionRequest)",
    ))
    host_validation = all(marker in sources["host_connection"] for marker in (
        "fn validate_monitor_display_switch_target(",
        "self.send_current_display_changed().await;",
        "self.switch_display_to(display_idx, server.clone())",
    ))
    input_quiescence = all(marker in (
        sources["input_owner"] + sources["viewer_view"] + sources["keyboard"] + sources["app"]
    ) for marker in (
        "package final class ViewerDisplaySelectionInputOwner",
        "pendingSuccessMatchesCurrentCatalogLocked()",
        "releaseAllInputForDisplaySelection()",
        "setDisplaySelectionInputQuiesced(true)",
        "setDisplaySelectionInputQuiesced(false)",
    ))
    selector = all(marker in sources["presentation"] + sources["viewer_ui"] + sources["app"] for marker in (
        "package enum ViewerDisplaySelectionPresentationPolicy",
        "snapshot.pendingRequest != nil",
        "snapshot.inputQuiesced",
        "private let displaySelector = NSPopUpButton",
        "menuItem.tag = Int(item.displayIndex)",
        "onSelectDisplay?(displayIndex)",
        "chrome.onSelectDisplay =",
    ))
    tests = all(marker in sources["catalog_tests"] + sources["selection_tests"] + sources["input_tests"] for marker in (
        "testAvailableCatalogRequiresContiguousEntriesAndSelectableSelection",
        "testProjectionAcceptsOnlyExactCurrentCatalogFrameTuple",
        "testOnlyExactSuccessfulTerminalUnderCurrentCatalogResumesInput",
        "testPresentationProjectsReadyPendingAndFailureWithoutUsingNameAsIdentity",
        "testReplacementCarriesFailClosedPauseAndPromptsExplicitRetry",
    ))
    evidence = {
        "designRequiresSelectDisplayAndRevisionedMapping": all(marker in sources["design"] for marker in (
            "H6.4 多显示器切换：`selectDisplay` 命令与 revisioned display mapping",
            "所有 command 均带 `commandId`",
            "最终结果通过 event 回传",
        )),
        "ownershipAuditPassesWithoutDevelopmentGaps": ownership_passes,
        "viewerCatalogAndFrameTupleImplemented": catalog,
        "viewerSelectionCommandTerminalLifecycleImplemented": selection,
        "hostValidatesSwitchBeforeMutation": host_validation,
        "viewerQuiescesAllInputUntilExactSuccess": input_quiescence,
        "viewerSelectorUsesCanonicalIndexAndStableStates": selector,
        "recoveryAndTeardownDoNotReuseOldAuthority": all(marker in sources["input_owner"] + sources["app"] for marker in (
            "setControlAvailable(false)",
            "viewerDisplaySelectionInputOwner?.stop()",
            "let selectionWasQuiesced = viewerDisplaySelectionInputOwner?",
            "initiallyQuiesced: selectionWasQuiesced",
            "guard coreGeneration == viewerCoreGeneration else { return }",
        )),
        "focusedTestsCoverCatalogCommandInputAndPresentation": tests,
        "abiVersionsMatchImplementedContract": viewer_abi == 16 and host_abi == 18,
        "stagedEvidenceChainExists": all(path.is_file() for path in evidence_paths),
    }
    claims = {
        "viewerCatalogImplemented": catalog,
        "viewerSelectionLifecycleImplemented": selection,
        "hostSwitchValidationImplemented": host_validation,
        "viewerInputQuiescenceImplemented": input_quiescence,
        "viewerDisplaySelectorImplemented": selector,
        "multiDisplayProductDevelopmentComplete": all(evidence.values()),
        "installedCurrentBuildSmokeComplete": False,
        "twoMacMultiDisplayAcceptanceComplete": False,
    }
    remaining_gaps = [name for name, present in evidence.items() if not present]
    source_lines = {
        "designRequirement": line_number(sources["design"], "H6.4 多显示器切换：`selectDisplay`"),
        "viewerCatalogABI": line_number(sources["header"], "typedef struct RDNDisplayCatalogEvent"),
        "viewerSelectionABI": line_number(sources["header"], "typedef struct RDNDisplaySelectionRequest"),
        "viewerCatalogOwner": line_number(sources["viewer_bridge"], "fn publish_display_catalog(&self, displays: &[DisplayInfo]"),
        "viewerSelectionOwner": line_number(sources["viewer_bridge"], "pub unsafe extern \"C\" fn rdn_client_select_display("),
        "hostSwitchValidation": line_number(sources["host_connection"], "fn validate_monitor_display_switch_target("),
        "viewerInputOwner": line_number(sources["input_owner"], "package final class ViewerDisplaySelectionInputOwner"),
        "viewerPresentation": line_number(sources["presentation"], "package enum ViewerDisplaySelectionPresentationPolicy"),
        "viewerSelector": line_number(sources["viewer_ui"], "private let displaySelector = NSPopUpButton"),
        "productWiring": line_number(sources["app"], "chrome.onSelectDisplay ="),
        "catalogTests": line_number(sources["catalog_tests"], "testAvailableCatalogRequiresContiguousEntriesAndSelectableSelection"),
        "selectionTests": line_number(
            sources["selection_tests"],
            "testRequestRequiresPositiveExactIdentity",
        ),
        "productTests": line_number(sources["input_tests"], "testPresentationProjectsReadyPendingAndFailureWithoutUsingNameAsIdentity"),
    }
    complete = claims["multiDisplayProductDevelopmentComplete"] and all(source_lines.values())
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "product-development-complete" if complete else "audit-failed",
        "coverageScope": "h6-4-multi-display-product-development-completion",
        "currentABI": {"viewer": viewer_abi, "host": host_abi},
        "evidence": evidence,
        "sourceLines": source_lines,
        "claims": claims,
        "remainingDevelopmentGaps": remaining_gaps,
        "nonBlockingAcceptanceGaps": [
            "installedCurrentBuildSingleMacSmoke",
            "twoMacDisplayInventoryAndSelection",
            "crossDisplayPictureRecovery",
            "scaleRotationAndHotPlug",
            "postSwitchPointerAndKeyboardMapping",
            "crossMachinePerformanceAndInteroperability",
        ],
        "nextImplementationBoundary": "host-audio-product-ownership-audit",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
