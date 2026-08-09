#!/usr/bin/env python3
"""Audit the privileged physical-energy authority for section 15.2 item 9."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-physical-energy-authority-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "h2": repository / "docs/host-mode-h2.md",
        "design": repository / "docs/host-mode-design.md",
        "battery_audit": (
            repository / "Scripts/audit-host-battery-thermal-evidence.py"
        ),
        "sampler": repository / "Scripts/sample-farpane-host-performance.sh",
        "capture_runner": (
            repository / "Scripts/sample-farpane-host-powermetrics.py"
        ),
        "matrix": repository / "Scripts/validate-farpane-host-performance-matrix.py",
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    h2 = sources["h2"]
    design = sources["design"]
    battery_audit = sources["battery_audit"]
    sampler = sources["sampler"]
    capture_runner = sources["capture_runner"]
    matrix = sources["matrix"]

    product_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted((repository / "Sources").rglob("*.swift"))
    )
    battery_validator = repository / "Scripts/validate-farpane-host-battery.py"

    evidence = {
        "h2AlreadyRequiresInstrumentsOrPrivilegedPowermetrics": (
            "真实能耗仍需 Instruments Energy Log 或有权限的 `powermetrics` 证据"
            in h2
        ),
        "authorityIsOperatorPrivilegedRawPowermetricsOnly": (
            "`/usr/bin/powermetrics` 的原始 plist stream" in h2
            and "只能由操作者在验收终端中显式提权运行" in h2
            and "FarPane 产品进程、HostAgent 与普通 runner 不请求 root" in h2
        ),
        "comparisonIsSameMachineOnlyAndProcessProxyIsForbidden": (
            "仅允许同一 portable Mac、同一 macOS 与同一构建的 baseline 对比"
            in h2
            and "per-process energy impact 仍是粗略 proxy" in h2
        ),
        "currentSamplerExplicitlyRejectsPhysicalEnergyInference": (
            '"energyImpactUnit": "top-relative-not-joules"' in sampler
            and "not joules or whole-system physical energy" in sampler
        ),
        "itemNineAuditRequiresPhysicalAuthorityUnitAndThreshold": all(
            marker in battery_audit
            for marker in (
                '"requiresNamedPhysicalAuthorityAndUnit": True',
                '"requiresBaselineAndAcceptanceThresholdBeforePass": True',
                '"top-relative-power-as-joules-or-watt-hours"',
            )
        ),
        "baseMatrixStillLeavesItemNineOpen": (
            '"uncoveredSection15_2Items": [7, 9, 10]' in matrix
        ),
        "productDoesNotInvokePrivilegeOrPowermetrics": (
            "powermetrics" not in product_sources
            and "/usr/bin/sudo" not in product_sources
            and "AuthorizationExecuteWithPrivileges" not in product_sources
        ),
        "boundedRawCaptureImplementedWithoutParserOrPassClaim": all(
            marker in capture_runner
            for marker in (
                'SCENARIOS = ("battery-idle", "battery-active")',
                "MINIMUM_ACCEPTANCE_SECONDS = 600",
                "MAXIMUM_RAW_BYTES = 256 * 1024 * 1024",
                'POWERMETRICS_PATH = Path("/usr/bin/powermetrics")',
                'SAMPLERS = ("battery", "cpu_power", "thermal")',
                "require_superuser(os.geteuid())",
                "this wrapper never invokes sudo",
                "battery_power_is_active()",
                "hash_open_executable(executable_path)",
                "resource.setrlimit(resource.RLIMIT_FSIZE",
                "publish_pair_no_replace(",
                '"rawSourceParsed": False',
                '"batterySourceThroughoutProven": False',
                '"physicalEnergyThresholdEvaluated": False',
                '"thermalResponseEvaluated": False',
                '"section15_2Item9Complete": False',
            )
        ) and "/usr/bin/sudo" not in capture_runner,
        "batteryValidatorIsNotYetImplemented": (
            not battery_validator.exists()
        ),
        "designDoesNotClaimItemNinePass": (
            "不宣称 item 9 pass" in design
            and "portable-Mac battery/heat-soak" in design
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "h2EnergyBoundary": line_number(
            h2,
            "真实能耗仍需 Instruments Energy Log 或有权限的 `powermetrics` 证据",
        ),
        "h2RawAuthority": line_number(
            h2, "`/usr/bin/powermetrics` 的原始 plist stream"
        ),
        "h2PrivilegeBoundary": line_number(
            h2, "只能由操作者在验收终端中显式提权运行"
        ),
        "h2SameMachineBoundary": line_number(
            h2, "仅允许同一 portable Mac、同一 macOS 与同一构建的 baseline 对比"
        ),
        "samplerRelativeUnit": line_number(
            sampler, '"energyImpactUnit": "top-relative-not-joules"'
        ),
        "captureRootBoundary": line_number(
            capture_runner, "require_superuser(os.geteuid())"
        ),
        "captureSamplerSet": line_number(
            capture_runner, 'SAMPLERS = ("battery", "cpu_power", "thermal")'
        ),
        "captureRawBound": line_number(
            capture_runner, "MAXIMUM_RAW_BYTES = 256 * 1024 * 1024"
        ),
        "captureHostDigest": line_number(
            capture_runner, "hash_open_executable(executable_path)"
        ),
        "captureBatteryPreflight": line_number(
            capture_runner, "battery_power_is_active()"
        ),
        "captureAtomicPublication": line_number(
            capture_runner, "publish_pair_no_replace("
        ),
        "captureRawOnlyClaim": line_number(
            capture_runner, '"rawSourceParsed": False'
        ),
        "captureItemNineOpenClaim": line_number(
            capture_runner, '"section15_2Item9Complete": False'
        ),
        "batteryAuditAuthorityRequirement": line_number(
            battery_audit, '"requiresNamedPhysicalAuthorityAndUnit": True'
        ),
        "batteryAuditThresholdRequirement": line_number(
            battery_audit,
            '"requiresBaselineAndAcceptanceThresholdBeforePass": True',
        ),
        "matrixUncoveredItems": line_number(
            matrix, '"uncoveredSection15_2Items": [7, 9, 10]'
        ),
        "designOpenBoundary": line_number(
            design, "不宣称 item 9 pass"
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "section15_2Item": 9,
        "status": (
            "raw-capture-implemented"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "selectedAuthority": {
            "executable": "/usr/bin/powermetrics",
            "format": "nul-separated-plist",
            "minimumSamplers": ["battery", "cpu_power", "thermal"],
            "measurementScope": "estimated-whole-system-and-soc-power",
            "comparisonScope": "same-portable-machine-only",
            "privilege": "operator-explicit-superuser-acceptance-only",
            "perProcessEnergyImpactAcceptedAsPhysicalEnergy": False,
            "instrumentsEnergyLogRole": "manual-corroboration-only",
        },
        "captureContract": {
            "minimumDurationSeconds": 600,
            "sampleIntervalMilliseconds": 1000,
            "requiresBatterySourceThroughout": True,
            "requiresExactScenarioAndHostPID": True,
            "requiresMachineMacOSAndExecutableDigest": True,
            "requiresRawSourceSHA256": True,
            "requiresBoundedSampleCountAndSourceSize": True,
            "requiresNoReplaceAtomicPublication": True,
            "productMayRequestOrEscalatePrivileges": False,
            "captureToolMayEmbedOrInvokeSudo": False,
            "rawCaptureWrapperImplemented": True,
            "rawCaptureMayClaimBatteryCoverageOrItemNinePass": False,
        },
        "forbiddenInference": [
            "cross-machine-power-comparison",
            "per-process-energy-impact-as-physical-energy",
            "top-power-as-joules-or-watt-hours",
            "product-or-host-agent-privilege-escalation",
            "guessed-plist-schema-without-real-portable-mac-fixture",
        ],
        "remainingBoundary": {
            "portableMacRawPlistFixtureStillRequiredBeforeParser": True,
            "rawPlistParserStillRequiresImplementation": True,
            "pairedBaselineAndAcceptanceThresholdStillRequireDefinition": True,
            "batteryManifestValidatorStillRequiresImplementation": True,
            "installedPortableMacRunsStillRequireExecution": True,
            "noSection15_2ItemNinePassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "raw-capture-implemented" else 1


if __name__ == "__main__":
    raise SystemExit(main())
