from __future__ import annotations

import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any, Iterable

from Scripts.evidence import (
    has_symlink_component,
    hash_bytes,
    is_bounded_text,
    is_finite_number as is_number,
    is_integer,
    is_sha256,
)


from Scripts.evidence_combined.contract import (
    ARTIFACTS_KEYS,
    ARTIFACT_KEYS,
    CSV_HEADER,
    MACHINE_KEYS,
    MAXIMUM_SAMPLE_GAP_SECONDS,
    RESOURCE_AUTHORITY_KEYS,
    ROLES_KEYS,
    ROLE_KEYS,
    SCENARIO_CONTRACTS,
    SUPPORTED_ARCHITECTURES,
    SYSTEM_CLAIM_KEYS,
    SYSTEM_KEYS,
    SYSTEM_SCHEMA,
    SYSTEM_WINDOW_KEYS,
    parse_utc,
    require_exact_keys,
)


def validate_role(
    role: dict[str, Any],
    expected_role: str,
    failures: list[str],
) -> None:
    require_exact_keys(role, ROLE_KEYS, f"{expected_role} role", failures)
    expected_flag_count = 1 if expected_role == "host-agent" else 0
    if not is_integer(role.get("pid")) or role.get("pid", 0) <= 1:
        failures.append(f"{expected_role} PID is invalid")
    if role.get("role") != expected_role:
        failures.append(f"{expected_role} role label is invalid")
    if role.get("processName") not in ("FarPane", "RustDeskNative"):
        failures.append(f"{expected_role} process name is invalid")
    for key in ("executableSHA256", "argumentsSHA256"):
        if not is_sha256(role.get(key)):
            failures.append(f"{expected_role} {key} is invalid")
    for key in (
        "bundleIdentifier",
        "buildIdentifier",
        "shortVersion",
        "startMarker",
    ):
        if not is_bounded_text(role.get(key), 128):
            failures.append(f"{expected_role} {key} is invalid")
    if role.get("hostAgentFlagCount") != expected_flag_count:
        failures.append(f"{expected_role} exact role flag count is invalid")


def validate_system_metadata(
    system: dict[str, Any],
    scenario: str,
    samples_path: Path,
    samples_raw: bytes,
    log_path: Path,
    log_raw: bytes,
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    if set(system) != SYSTEM_KEYS:
        failures.append("system metadata keys do not match schema v1")
    if system.get("schema") != SYSTEM_SCHEMA or system.get("schemaVersion") != 1:
        failures.append("system metadata schema is invalid")
    if system.get("scenario") != scenario:
        failures.append("system scenario does not match manifest")
    sample_mode = system.get("sampleMode")
    duration = system.get("requestedDurationSeconds")
    if sample_mode not in ("acceptance", "smoke"):
        failures.append("system sample mode is invalid")
    if not is_integer(duration) or duration <= 0:
        failures.append("system requested duration is invalid")
        duration = 0
    elif sample_mode == "acceptance" and not 600 <= duration <= 1_800:
        failures.append("acceptance duration must be between 600 and 1800 seconds")
    elif sample_mode == "smoke" and duration > 60:
        failures.append("smoke duration must be between 1 and 60 seconds")
    if system.get("sampleCadenceTargetMilliseconds") != 1_000:
        failures.append("system sample cadence target is invalid")
    if system.get("sampleCount") != duration or system.get("completed") is not True:
        failures.append("system sampler did not complete every requested sample")

    window = require_exact_keys(
        system.get("window"), SYSTEM_WINDOW_KEYS, "system window", failures
    )
    started_at = parse_utc(window.get("startedAt"))
    completed_at = parse_utc(window.get("completedAt"))
    started_mono = window.get("startedMonotonicNanoseconds")
    completed_mono = window.get("completedMonotonicNanoseconds")
    reported_mono_duration = window.get("monotonicDurationSeconds")
    if started_at is None or completed_at is None or completed_at <= started_at:
        failures.append("system UTC window is invalid")
    if (
        not is_integer(started_mono)
        or not is_integer(completed_mono)
        or started_mono < 0
        or completed_mono <= started_mono
    ):
        failures.append("system monotonic window is invalid")
        started_mono = 0
        completed_mono = 0
    monotonic_duration = (completed_mono - started_mono) / 1_000_000_000
    if (
        not is_number(reported_mono_duration)
        or abs(float(reported_mono_duration) - monotonic_duration) > 0.01
        or monotonic_duration < duration
    ):
        failures.append("system monotonic duration is inconsistent or incomplete")
    if started_at is not None and completed_at is not None:
        utc_duration = (completed_at - started_at).total_seconds()
        if utc_duration + 1 < duration or abs(utc_duration - monotonic_duration) > 2:
            failures.append("system UTC and monotonic windows are inconsistent")

    machine = require_exact_keys(
        system.get("machine"), MACHINE_KEYS, "system machine", failures
    )
    if not is_bounded_text(machine.get("machineModel"), 128):
        failures.append("system machine model is invalid")
    if machine.get("architecture") not in SUPPORTED_ARCHITECTURES:
        failures.append("system architecture is unsupported")
    if not is_bounded_text(machine.get("macOSVersion"), 64):
        failures.append("system macOS version is invalid")

    roles = require_exact_keys(
        system.get("roles"), ROLES_KEYS, "system roles", failures
    )
    host_agent = roles.get("hostAgent")
    viewer = roles.get("viewer")
    if not isinstance(host_agent, dict):
        host_agent = {}
    if not isinstance(viewer, dict):
        viewer = {}
    validate_role(host_agent, "host-agent", failures)
    validate_role(viewer, "viewer", failures)
    if host_agent.get("pid") == viewer.get("pid"):
        failures.append("system roles do not have distinct PIDs")
    if roles.get("distinctPIDs") is not True:
        failures.append("system distinct-PID authority is false")
    for key in (
        "sameExecutablePath",
        "sameExecutableSHA256",
        "sameBuildIdentifier",
    ):
        if roles.get(key) is not True:
            failures.append(f"system role authority {key} is false")
    if host_agent.get("executableSHA256") != viewer.get("executableSHA256"):
        failures.append("system role executable digests differ")
    for key in ("bundleIdentifier", "buildIdentifier", "shortVersion"):
        if host_agent.get(key) != viewer.get(key):
            failures.append(f"system role {key} differs")

    authority = require_exact_keys(
        system.get("resourceAuthority"),
        RESOURCE_AUTHORITY_KEYS,
        "system resource authority",
        failures,
    )
    if authority.get("roleProcessScope") != "exact-pid-per-second":
        failures.append("system role process scope is invalid")
    if authority.get("combinedProcessScope") != "host-agent-plus-viewer-only":
        failures.append("system combined process scope is invalid")
    if authority.get("sharedSystemScope") != [
        "WindowServer",
        "videotoolboxd",
        "VTEncoderXPCService",
    ]:
        failures.append("system shared process scope is invalid")
    if authority.get("sharedSystemScopeAssignedToRole") is not False:
        failures.append("system shared process scope was assigned to a role")
    if not isinstance(authority.get("energyImpactAvailable"), bool):
        failures.append("system relative-energy availability is invalid")
    if authority.get("energyImpactUnit") != "top-relative-not-joules":
        failures.append("system relative-energy unit is invalid")

    artifacts = require_exact_keys(
        system.get("artifacts"), ARTIFACTS_KEYS, "system artifacts", failures
    )
    for key, path, raw in (
        ("samples", samples_path, samples_raw),
        ("log", log_path, log_raw),
    ):
        artifact = require_exact_keys(
            artifacts.get(key), ARTIFACT_KEYS, f"system artifact {key}", failures
        )
        if artifact.get("path") != path.name:
            failures.append(f"system artifact {key} basename does not match")
        if artifact.get("sha256") != hash_bytes(raw):
            failures.append(f"system artifact {key} SHA-256 does not match")

    claims = require_exact_keys(
        system.get("claims"), SYSTEM_CLAIM_KEYS, "system claims", failures
    )
    if any(claims.get(key) is not False for key in SYSTEM_CLAIM_KEYS):
        failures.append("raw system sampler made a downstream completion claim")

    normalized = {
        "sampleMode": sample_mode if sample_mode in ("acceptance", "smoke") else "invalid",
        "duration": duration,
        "startedAt": window.get("startedAt"),
        "completedAt": window.get("completedAt"),
        "startedMonotonicNanoseconds": started_mono,
        "completedMonotonicNanoseconds": completed_mono,
        "machine": machine,
        "hostAgent": host_agent,
        "viewer": viewer,
        "energyImpactAvailable": authority.get("energyImpactAvailable") is True,
    }
    return normalized, failures


def parse_csv_float(row: dict[str, str], key: str) -> float:
    value = float(row[key])
    if not math.isfinite(value):
        raise ValueError(key)
    return value


def parse_csv_int(row: dict[str, str], key: str) -> int:
    value = row[key]
    if not re.fullmatch(r"-?[0-9]+", value):
        raise ValueError(key)
    return int(value)


def parse_energy(value: str) -> float | None:
    if value == "na":
        return None
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise ValueError("energy")
    return parsed


def average(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def validate_system_samples(
    raw: bytes,
    system: dict[str, Any],
    scenario: str,
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    try:
        text = raw.decode("utf-8")
        reader = csv.DictReader(text.splitlines())
        fieldnames = tuple(reader.fieldnames or ())
        rows = list(reader)
    except (UnicodeError, csv.Error):
        return {}, ["system samples are invalid CSV"]
    if fieldnames != CSV_HEADER:
        failures.append("system CSV header does not match schema v1")
    duration = system["duration"]
    if len(rows) != duration:
        failures.append("system CSV row count does not match duration")
    host_cpu: list[float] = []
    viewer_cpu: list[float] = []
    combined_cpu: list[float] = []
    host_rss: list[int] = []
    viewer_rss: list[int] = []
    host_threads: list[int] = []
    viewer_threads: list[int] = []
    monotonic_values: list[int] = []
    elapsed_values: list[float] = []
    host_user_idle_assertions: list[int] = []
    host_display_assertions: list[int] = []
    contract = SCENARIO_CONTRACTS[scenario]
    energy_available = system["energyImpactAvailable"]
    numeric_fields = (
        "windowserver_cpu_percent",
        "windowserver_rss_kb",
        "windowserver_threads",
        "videotoolboxd_cpu_percent",
        "videotoolboxd_rss_kb",
        "videotoolboxd_threads",
        "vt_encoder_xpc_cpu_percent",
        "vt_encoder_xpc_rss_kb",
        "vt_encoder_xpc_threads",
        "system_cpu_user_percent",
        "system_cpu_sys_percent",
        "system_cpu_idle_percent",
        "memory_free_percent",
    )
    assertion_fields = (
        "host_agent_sleep_assertion_count",
        "host_agent_user_idle_sleep_assertion_count",
        "host_agent_display_sleep_assertion_count",
        "viewer_sleep_assertion_count",
        "viewer_user_idle_sleep_assertion_count",
        "viewer_display_sleep_assertion_count",
    )
    energy_fields = (
        "host_agent_energy_impact",
        "viewer_energy_impact",
        "farpane_combined_energy_impact",
        "windowserver_energy_impact",
        "videotoolboxd_energy_impact",
        "vt_encoder_xpc_energy_impact",
    )
    for index, row in enumerate(rows, start=1):
        try:
            if set(row) != set(CSV_HEADER) or None in row:
                raise ValueError("columns")
            if row["scenario"] != scenario:
                raise ValueError("scenario")
            host_pid = parse_csv_int(row, "host_agent_pid")
            viewer_pid = parse_csv_int(row, "viewer_pid")
            if host_pid != system["hostAgent"].get("pid"):
                raise ValueError("host PID")
            if viewer_pid != system["viewer"].get("pid"):
                raise ValueError("viewer PID")
            elapsed = parse_csv_float(row, "elapsed_seconds")
            monotonic = parse_csv_int(row, "monotonic_nanoseconds")
            if elapsed < 0 or monotonic < 0:
                raise ValueError("time")
            expected_elapsed = (
                monotonic - system["startedMonotonicNanoseconds"]
            ) / 1_000_000_000
            if abs(elapsed - expected_elapsed) > 0.01:
                raise ValueError("elapsed authority")
            host_value = parse_csv_float(row, "host_agent_cpu_percent")
            viewer_value = parse_csv_float(row, "viewer_cpu_percent")
            combined_value = parse_csv_float(
                row, "farpane_combined_cpu_percent"
            )
            if min(host_value, viewer_value, combined_value) < 0:
                raise ValueError("CPU")
            if abs(combined_value - host_value - viewer_value) > 0.01:
                raise ValueError("combined CPU")
            host_rss_value = parse_csv_int(row, "host_agent_rss_kb")
            viewer_rss_value = parse_csv_int(row, "viewer_rss_kb")
            combined_rss = parse_csv_int(row, "farpane_combined_rss_kb")
            host_thread_value = parse_csv_int(row, "host_agent_threads")
            viewer_thread_value = parse_csv_int(row, "viewer_threads")
            combined_threads = parse_csv_int(row, "farpane_combined_threads")
            if min(host_rss_value, viewer_rss_value, host_thread_value, viewer_thread_value) <= 0:
                raise ValueError("role RSS/thread")
            if combined_rss != host_rss_value + viewer_rss_value:
                raise ValueError("combined RSS")
            if combined_threads != host_thread_value + viewer_thread_value:
                raise ValueError("combined threads")
            system_values = [parse_csv_float(row, key) for key in numeric_fields]
            if any(value < 0 for value in system_values):
                raise ValueError("system resource")
            cpu_sum = sum(
                parse_csv_float(row, key)
                for key in (
                    "system_cpu_user_percent",
                    "system_cpu_sys_percent",
                    "system_cpu_idle_percent",
                )
            )
            if not 95 <= cpu_sum <= 105:
                raise ValueError("system CPU sum")
            memory_free = parse_csv_float(row, "memory_free_percent")
            if not 0 <= memory_free <= 100:
                raise ValueError("memory free")
            if not is_bounded_text(row["thermal_pressure"], 32):
                raise ValueError("thermal")
            if row["power_source"] not in ("ac", "battery", "unknown"):
                raise ValueError("power source")
            assertions = [parse_csv_int(row, key) for key in assertion_fields]
            if any(value < 0 for value in assertions):
                raise ValueError("assertions")
            energies = {key: parse_energy(row[key]) for key in energy_fields}
            if energy_available and any(
                energies[key] is None
                for key in (
                    "host_agent_energy_impact",
                    "viewer_energy_impact",
                    "farpane_combined_energy_impact",
                )
            ):
                raise ValueError("role energy availability")
            host_energy = energies["host_agent_energy_impact"]
            viewer_energy = energies["viewer_energy_impact"]
            combined_energy = energies["farpane_combined_energy_impact"]
            if (
                host_energy is not None
                and viewer_energy is not None
                and combined_energy is not None
                and abs(combined_energy - host_energy - viewer_energy) > 0.01
            ):
                raise ValueError("combined energy")
            host_cpu.append(host_value)
            viewer_cpu.append(viewer_value)
            combined_cpu.append(combined_value)
            host_rss.append(host_rss_value)
            viewer_rss.append(viewer_rss_value)
            host_threads.append(host_thread_value)
            viewer_threads.append(viewer_thread_value)
            monotonic_values.append(monotonic)
            elapsed_values.append(elapsed)
            host_user_idle_assertions.append(
                parse_csv_int(row, "host_agent_user_idle_sleep_assertion_count")
            )
            host_display_assertions.append(
                parse_csv_int(row, "host_agent_display_sleep_assertion_count")
            )
        except (KeyError, TypeError, ValueError):
            failures.append(f"system CSV row {index} is malformed or inconsistent")

    if monotonic_values:
        if any(
            later <= earlier
            for earlier, later in zip(monotonic_values, monotonic_values[1:])
        ):
            failures.append("system sample monotonic timestamps are not increasing")
        gaps = [
            (later - earlier) / 1_000_000_000
            for earlier, later in zip(monotonic_values, monotonic_values[1:])
        ]
        if gaps and max(gaps) > MAXIMUM_SAMPLE_GAP_SECONDS:
            failures.append("system sample cadence has a gap above 2.5 seconds")
        start_gap = (
            monotonic_values[0] - system["startedMonotonicNanoseconds"]
        ) / 1_000_000_000
        end_gap = (
            system["completedMonotonicNanoseconds"] - monotonic_values[-1]
        ) / 1_000_000_000
        if not 0 <= start_gap <= MAXIMUM_SAMPLE_GAP_SECONDS:
            failures.append("system first sample does not cover the window edge")
        if not 0 <= end_gap <= MAXIMUM_SAMPLE_GAP_SECONDS:
            failures.append("system final sample does not cover the window edge")
    elif duration > 0:
        failures.append("system samples contain no valid rows")

    host_cpu_average = average(host_cpu)
    viewer_cpu_average = average(viewer_cpu)
    combined_cpu_average = average(combined_cpu)
    if host_cpu_average >= contract["hostAgentAverageCPUCeilingPercent"]:
        failures.append("HostAgent average CPU reached its scenario ceiling")
    if viewer_cpu_average >= contract["viewerAverageCPUCeilingPercent"]:
        failures.append("Viewer average CPU reached its scenario ceiling")
    if combined_cpu_average >= contract["combinedAverageCPUCeilingPercent"]:
        failures.append("combined FarPane average CPU reached its scenario ceiling")
    if any(value != 0 for value in host_display_assertions):
        failures.append("HostAgent held a forbidden display-sleep assertion")
    if contract["hostUserIdleAssertionMode"] == "zero":
        if any(value != 0 for value in host_user_idle_assertions):
            failures.append("HostAgent held a sleep assertion while only ready")
    elif not host_user_idle_assertions or any(
        value < 1 for value in host_user_idle_assertions
    ):
        failures.append("HostAgent did not hold its active user-idle assertion")

    metrics = {
        "sampleCount": len(rows),
        "maximumSampleGapSeconds": round(
            max(
                [
                    (later - earlier) / 1_000_000_000
                    for earlier, later in zip(
                        monotonic_values, monotonic_values[1:]
                    )
                ]
                or [0.0]
            ),
            3,
        ),
        "hostAgentAverageCPUPercent": round(host_cpu_average, 3),
        "viewerAverageCPUPercent": round(viewer_cpu_average, 3),
        "combinedAverageCPUPercent": round(combined_cpu_average, 3),
        "hostAgentPeakRSSKB": max(host_rss or [0]),
        "viewerPeakRSSKB": max(viewer_rss or [0]),
        "hostAgentPeakThreads": max(host_threads or [0]),
        "viewerPeakThreads": max(viewer_threads or [0]),
    }
    return metrics, failures
