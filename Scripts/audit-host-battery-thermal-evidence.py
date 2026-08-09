#!/usr/bin/env python3
"""Audit and freeze the section 15.2 item 9 battery evidence boundary."""

from __future__ import annotations

import json
import sys
from pathlib import Path


SCHEMA = "farpane-host-battery-thermal-evidence-audit"


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
        "design": repository / "docs/host-mode-design.md",
        "sampler": repository / "Scripts/sample-farpane-host-performance.sh",
        "idle_validator": repository / "Scripts/validate-farpane-host-idle.py",
        "active_validator": repository / "Scripts/validate-farpane-host-performance.py",
        "matrix": repository / "Scripts/validate-farpane-host-performance-matrix.py",
        "process_sampler": repository / "Sources/VideoPipeline/HostProcessSampler.swift",
        "live_log": repository / "Sources/VideoPipeline/HostMediaTelemetryLiveLog.swift",
        "cadence": repository / "Sources/VideoPipeline/HostCaptureCadence.swift",
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

    design = sources["design"]
    sampler = sources["sampler"]
    idle_validator = sources["idle_validator"]
    active_validator = sources["active_validator"]
    matrix = sources["matrix"]
    process_sampler = sources["process_sampler"]
    live_log = sources["live_log"]
    cadence = sources["cadence"]

    evidence = {
        "sectionSpecRequiresBatteryIdleActiveThermalAndIdleAssertion": (
            "电池供电下 Host idle 与 active session 的能耗/热状态" in design
            and "验证无会话时不持有 sleep assertion" in design
        ),
        "systemSamplerAdmitsBatteryLabelsAndSamplesPowerThermalAssertions": (
            "|battery-idle|battery-active|" in sampler
            and "thermal_pressure,power_source,host_sleep_assertion_count"
            in sampler
            and "'Battery Power') latest_power_source=battery" in sampler
            and '"sleepAssertionAuthority": "pmset-pid-and-type"' in sampler
        ),
        "systemSamplerEnergyImpactIsExplicitlyRelativeNotPhysical": (
            '"energyImpactUnit": "top-relative-not-joules"' in sampler
            and "top POWER relative metric; not joules" in sampler
        ),
        "idleValidatorProvesNoConnectionRouteOrSleepAssertion": all(
            marker in idle_validator
            for marker in (
                'record["authenticatedConnectionCount"] == 0',
                'record["mediaRouteActive"] is False',
                'record["mediaPipelineActive"] is False',
                "all(value == 0 for value in assertions)",
                "all(value == 0 for value in user_idle_assertions)",
                "all(value == 0 for value in display_assertions)",
            )
        ),
        "activeValidatorProvesRouteAndAssertionLifecycle": all(
            marker in active_validator
            for marker in (
                'nested(route, "schema") == "farpane-media-telemetry"',
                "send_accepted > 0",
                "runtime_seconds >= duration",
                "all(count >= 1 for count in host_user_idle_assertions)",
                "all(count == 0 for count in host_display_assertions)",
            )
        ),
        "currentValidatorsDoNotAdmitBatteryEnergyOrThermalSemantics": (
            '"battery-idle"' not in idle_validator
            and '"battery-active"' not in active_validator
            and "energyImpactUnit" not in idle_validator
            and "energyImpactUnit" not in active_validator
            and 'row, "power_source"' not in idle_validator
            and 'row, "power_source"' not in active_validator
            and 'row, "thermal_pressure"' not in idle_validator
            and 'row, "thermal_pressure"' not in active_validator
        ),
        "productTelemetryRecordsBatteryThermalLowPowerAndPressureCauses": (
            "IOPSGetProvidingPowerSourceType" in process_sampler
            and 'case kIOPSBatteryPowerValue: return "battery"' in process_sampler
            and "ProcessInfo.processInfo.thermalState" in process_sampler
            and "ProcessInfo.processInfo.isLowPowerModeEnabled" in process_sampler
            and "let capturePressureCauses: [String]" in live_log
            and "thermalState = snapshot.thermalState" in live_log
            and "powerSource = snapshot.powerSource" in live_log
            and "lowPowerModeEnabled = snapshot.lowPowerModeEnabled" in live_log
        ),
        "thermalPolicyCapsCadenceAtFifteenOrFiveFPS": all(
            marker in cadence
            for marker in (
                'normalizedThermalState == "critical"',
                'normalizedThermalState == "fair" || normalizedThermalState == "serious"',
                "case .moderate: return min(maximumFramesPerSecond, 15)",
                "case .severe: return min(maximumFramesPerSecond, 5)",
            )
        ),
        "baseMatrixExplicitlyLeavesItemNineOpen": (
            '"coveredSection15_2Items": [1, 2, 3, 4, 5, 6, 8]' in matrix
            and '"uncoveredSection15_2Items": [7, 9, 10]' in matrix
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "itemNineSpec": line_number(
            design,
            "电池供电下 Host idle 与 active session 的能耗/热状态",
        ),
        "samplerBatteryAdmission": line_number(
            sampler, "|battery-idle|battery-active|"
        ),
        "samplerPowerThermalColumns": line_number(
            sampler, "thermal_pressure,power_source,host_sleep_assertion_count"
        ),
        "samplerRelativeEnergyUnit": line_number(
            sampler, '"energyImpactUnit": "top-relative-not-joules"'
        ),
        "idleConnectionAuthority": line_number(
            idle_validator, 'record["authenticatedConnectionCount"] == 0'
        ),
        "idleAssertionGate": line_number(
            idle_validator, "all(value == 0 for value in assertions)"
        ),
        "activeRouteGate": line_number(
            active_validator,
            'nested(route, "schema") == "farpane-media-telemetry"',
        ),
        "activeAssertionGate": line_number(
            active_validator,
            "all(count >= 1 for count in host_user_idle_assertions)",
        ),
        "liveLogPressureCauses": line_number(
            live_log, "let capturePressureCauses: [String]"
        ),
        "liveLogThermal": line_number(
            live_log, "thermalState = snapshot.thermalState"
        ),
        "thermalCriticalPolicy": line_number(
            cadence, 'normalizedThermalState == "critical"'
        ),
        "thermalCadenceCeiling": line_number(
            cadence, "case .severe: return min(maximumFramesPerSecond, 5)"
        ),
        "matrixUncoveredItems": line_number(
            matrix, '"uncoveredSection15_2Items": [7, 9, 10]'
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
            "checkpoint-required"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "targetContract": {
            "requiredRuns": {
                "batteryIdle": {
                    "scenario": "host-ready-no-screen-route",
                    "minimumDurationSeconds": 600,
                    "requiresBatteryForEverySystemSample": True,
                    "requiresZeroAuthenticatedConnections": True,
                    "requiresNoMediaRouteOrPipeline": True,
                    "requiresZeroHostSleepAssertions": True,
                },
                "batteryActive": {
                    "scenario": "1080p30",
                    "minimumDurationSeconds": 600,
                    "requiresBatteryForEverySystemAndMediaSample": True,
                    "requiresPassedProductionRoute": True,
                    "requiresUserIdleAssertionThroughoutRoute": True,
                    "requiresNoDisplaySleepAssertion": True,
                },
            },
            "sharedScope": {
                "requiresSamePortableMachineBuildAndMacOS": True,
                "requiresSHA256SourceBinding": True,
                "rejectsPathEscapeSymlinkDuplicateAndOverwrite": True,
            },
            "energyEvidence": {
                "requiresNamedPhysicalAuthorityAndUnit": True,
                "requiresCompleteIdleAndActiveWindowCoverage": True,
                "requiresBaselineAndAcceptanceThresholdBeforePass": True,
            },
            "thermalEvidence": {
                "requiresBoundedPerSampleThermalSeries": True,
                "requiresLiveMediaCorrelationWhenPressureOccurs": True,
                "requiresSeriousCriticalCadenceDegradation": True,
            },
            "forbiddenInference": [
                "top-relative-power-as-joules-or-watt-hours",
                "battery-label-without-complete-sample-coverage",
                "route-stop-final-state-as-thermal-response-series",
                "single-battery-percentage-or-activity-monitor-screenshot",
            ],
        },
        "remainingBoundary": {
            "physicalEnergyAuthorityAndThresholdRequireSeparateCheckpoint": True,
            "batteryIdleAndActiveValidatorStillRequiresImplementation": True,
            "thermalLiveLogBindingStillRequiresImplementation": True,
            "installedPortableMacRunsStillRequireExecution": True,
            "noSection15_2ItemNinePassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "checkpoint-required" else 1


if __name__ == "__main__":
    raise SystemExit(main())
