#!/usr/bin/env python3
"""Validate one bounded §15.2 item 10 combined HostAgent/Viewer run."""

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


MANIFEST_SCHEMA = "farpane-host-combined-role-manifest"
OUTPUT_SCHEMA = "farpane-host-combined-role-run"
SYSTEM_SCHEMA = "farpane-host-combined-role-system-sample"
VIEWER_SCHEMA = "farpane-viewer-pipeline-report"
HOST_STATE_SCHEMA = "farpane-host-runtime-state"
SCENARIOS = ("host-ready-viewer", "host-viewer-dual")
SOURCE_NAMES = (
    "systemMetadata",
    "systemSamples",
    "systemLog",
    "hostRuntimeState",
    "viewerReport",
)
SOURCE_SUFFIXES = {
    "systemMetadata": ".json",
    "systemSamples": ".csv",
    "systemLog": ".log",
    "hostRuntimeState": ".jsonl",
    "viewerReport": ".json",
}
SOURCE_MAXIMUM_BYTES = {
    "systemMetadata": 1_048_576,
    "systemSamples": 32 * 1024 * 1024,
    "systemLog": 1_048_576,
    "hostRuntimeState": 16 * 1024 * 1024,
    "viewerReport": 2 * 1024 * 1024,
}
MAXIMUM_MANIFEST_BYTES = 65_536
MAXIMUM_STATE_RECORDS = 10_000
MAXIMUM_STATE_GAP_SECONDS = 2.5
MAXIMUM_SAMPLE_GAP_SECONDS = 2.5
MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS = 2.5
MAXIMUM_VIEWER_PRESENTATION_GAP_MILLISECONDS = 2_500.0
MAXIMUM_SNAPSHOT_AGE_MILLISECONDS = 3_000
CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS = 1_500
SUPPORTED_ARCHITECTURES = ("arm64", "x86_64")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

SCENARIO_CONTRACTS = {
    "host-ready-viewer": {
        "hostAgentAverageCPUCeilingPercent": 2.0,
        "viewerAverageCPUCeilingPercent": 60.0,
        "combinedAverageCPUCeilingPercent": 62.0,
        "authenticatedConnectionMode": "zero",
        "mediaActive": False,
        "hostUserIdleAssertionMode": "zero",
    },
    "host-viewer-dual": {
        "hostAgentAverageCPUCeilingPercent": 25.0,
        "viewerAverageCPUCeilingPercent": 60.0,
        "combinedAverageCPUCeilingPercent": 85.0,
        "authenticatedConnectionMode": "positive",
        "mediaActive": True,
        "hostUserIdleAssertionMode": "positive",
    },
}

MANIFEST_KEYS = {"schema", "schemaVersion", "scenario", "sources"}
SOURCE_KEYS = {"path", "sha256"}
SYSTEM_KEYS = {
    "schema",
    "schemaVersion",
    "scenario",
    "sampleMode",
    "requestedDurationSeconds",
    "sampleCadenceTargetMilliseconds",
    "sampleCount",
    "completed",
    "window",
    "machine",
    "roles",
    "resourceAuthority",
    "artifacts",
    "claims",
}
SYSTEM_WINDOW_KEYS = {
    "startedAt",
    "completedAt",
    "startedMonotonicNanoseconds",
    "completedMonotonicNanoseconds",
    "monotonicDurationSeconds",
}
MACHINE_KEYS = {"machineModel", "architecture", "macOSVersion"}
ROLES_KEYS = {
    "hostAgent",
    "viewer",
    "distinctPIDs",
    "sameExecutablePath",
    "sameExecutableSHA256",
    "sameBuildIdentifier",
}
ROLE_KEYS = {
    "pid",
    "role",
    "processName",
    "executableSHA256",
    "bundleIdentifier",
    "buildIdentifier",
    "shortVersion",
    "startMarker",
    "argumentsSHA256",
    "hostAgentFlagCount",
}
RESOURCE_AUTHORITY_KEYS = {
    "roleProcessScope",
    "combinedProcessScope",
    "sharedSystemScope",
    "sharedSystemScopeAssignedToRole",
    "energyImpactAvailable",
    "energyImpactUnit",
}
ARTIFACTS_KEYS = {"samples", "log"}
ARTIFACT_KEYS = {"path", "sha256"}
SYSTEM_CLAIM_KEYS = {
    "hostRuntimeStateBound",
    "viewerStreamingReportBound",
    "combinedBudgetThresholdEvaluated",
    "section15_2Item10Complete",
}
HOST_STATE_KEYS = {
    "schema",
    "schemaVersion",
    "sequence",
    "capturedAt",
    "monotonicNanoseconds",
    "hostRuntimeActive",
    "hostState",
    "registrationStatus",
    "hostSnapshotObservedAtUnixMilliseconds",
    "authenticatedConnectionCount",
    "mediaRouteActive",
    "mediaPipelineActive",
}
VIEWER_REQUIRED_KEYS = {
    "schema",
    "schemaVersion",
    "processID",
    "bundleIdentifier",
    "buildIdentifier",
    "measurementStartedAt",
    "measurementStartedMonotonicNanoseconds",
    "measurementCompletedMonotonicNanoseconds",
    "firstPresentationMonotonicNanoseconds",
    "lastPresentationMonotonicNanoseconds",
    "timestamp",
    "source",
    "durationSeconds",
    "processCPUPercent",
    "initialResidentMB",
    "finalResidentMB",
    "peakResidentMB",
    "decodedFrames",
    "presentedFrames",
    "encodedFrames",
    "hardwareDecodeActive",
    "coreStateTransitions",
    "maxPresentationGapMS",
    "finalPresentationStalenessMS",
}
CSV_HEADER = (
    "elapsed_seconds",
    "monotonic_nanoseconds",
    "scenario",
    "host_agent_pid",
    "host_agent_cpu_percent",
    "host_agent_rss_kb",
    "host_agent_threads",
    "host_agent_energy_impact",
    "viewer_pid",
    "viewer_cpu_percent",
    "viewer_rss_kb",
    "viewer_threads",
    "viewer_energy_impact",
    "farpane_combined_cpu_percent",
    "farpane_combined_rss_kb",
    "farpane_combined_threads",
    "farpane_combined_energy_impact",
    "windowserver_cpu_percent",
    "windowserver_rss_kb",
    "windowserver_threads",
    "windowserver_energy_impact",
    "videotoolboxd_cpu_percent",
    "videotoolboxd_rss_kb",
    "videotoolboxd_threads",
    "videotoolboxd_energy_impact",
    "vt_encoder_xpc_cpu_percent",
    "vt_encoder_xpc_rss_kb",
    "vt_encoder_xpc_threads",
    "vt_encoder_xpc_energy_impact",
    "system_cpu_user_percent",
    "system_cpu_sys_percent",
    "system_cpu_idle_percent",
    "memory_free_percent",
    "thermal_pressure",
    "power_source",
    "host_agent_sleep_assertion_count",
    "host_agent_user_idle_sleep_assertion_count",
    "host_agent_display_sleep_assertion_count",
    "viewer_sleep_assertion_count",
    "viewer_user_idle_sleep_assertion_count",
    "viewer_display_sleep_assertion_count",
)


class ValidationError(RuntimeError):
    pass


def usage() -> None:
    print(
        "usage: validate-farpane-host-combined-role.py "
        "MANIFEST_JSON OUTPUT_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def is_bounded_text(value: Any, maximum_length: int) -> bool:
    return (
        isinstance(value, str)
        and value == value.strip()
        and 0 < len(value) <= maximum_length
        and all(
            ord(character) >= 0x20 and ord(character) != 0x7F
            for character in value
        )
    )


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def parse_utc(value: Any) -> datetime | None:
    if not is_bounded_text(value, 40) or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def datetime_nanoseconds(value: datetime) -> int:
    return int(value.timestamp() * 1_000_000_000)


def strict_json(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"non-finite {token}")
            ),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValidationError(f"{label} is invalid strict JSON") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{label} root is not an object")
    return value


def hash_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def safe_relative_source_path(value: Any, suffix: str) -> bool:
    if not is_bounded_text(value, 512):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and candidate.suffix.lower() == suffix
        and candidate.parts
        and all(part not in ("", ".", "..") for part in candidate.parts)
    )


def has_symlink_component(path: Path) -> bool:
    if not path.is_absolute():
        return True
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            return True
    return False


def read_bounded_regular(path: Path, maximum_bytes: int, label: str) -> bytes:
    if path.is_symlink():
        raise ValidationError(f"{label} must not be a symlink")
    try:
        metadata = path.stat()
    except OSError as error:
        raise ValidationError(f"{label} is missing or unreadable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > maximum_bytes
    ):
        raise ValidationError(f"{label} file identity or size is invalid")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ValidationError(f"{label} is unreadable") from error


def resolve_sources(
    manifest_path: Path,
    manifest: dict[str, Any],
) -> tuple[dict[str, Path], dict[str, bytes]]:
    sources = manifest.get("sources")
    if not isinstance(sources, dict) or set(sources) != set(SOURCE_NAMES):
        raise ValidationError("manifest sources do not match schema v1")
    resolved: dict[str, Path] = {}
    raw_sources: dict[str, bytes] = {}
    seen_paths: set[Path] = set()
    seen_file_identities: set[tuple[int, int]] = set()
    root = manifest_path.parent.resolve()
    for name in SOURCE_NAMES:
        source = sources.get(name)
        if not isinstance(source, dict) or set(source) != SOURCE_KEYS:
            raise ValidationError(f"manifest source {name} does not match schema v1")
        relative = source.get("path")
        if not safe_relative_source_path(relative, SOURCE_SUFFIXES[name]):
            raise ValidationError(f"manifest source {name} path is unsafe")
        path = manifest_path.parent / relative
        try:
            canonical = path.resolve(strict=True)
        except OSError as error:
            raise ValidationError(f"manifest source {name} is missing") from error
        if canonical.parent != root and root not in canonical.parents:
            raise ValidationError(f"manifest source {name} escapes its root")
        if path.is_symlink() or canonical != path.absolute():
            raise ValidationError(f"manifest source {name} uses a symlink")
        raw = read_bounded_regular(
            canonical, SOURCE_MAXIMUM_BYTES[name], f"manifest source {name}"
        )
        metadata = canonical.stat()
        file_identity = (metadata.st_dev, metadata.st_ino)
        if canonical in seen_paths or file_identity in seen_file_identities:
            raise ValidationError("manifest sources contain a duplicate file")
        seen_paths.add(canonical)
        seen_file_identities.add(file_identity)
        expected_digest = source.get("sha256")
        if not is_sha256(expected_digest) or hash_bytes(raw) != expected_digest:
            raise ValidationError(f"manifest source {name} SHA-256 does not match")
        resolved[name] = canonical
        raw_sources[name] = raw
    return resolved, raw_sources


def validate_manifest_document(manifest: dict[str, Any]) -> str:
    if set(manifest) != MANIFEST_KEYS:
        raise ValidationError("manifest keys do not match schema v1")
    if (
        manifest.get("schema") != MANIFEST_SCHEMA
        or manifest.get("schemaVersion") != 1
    ):
        raise ValidationError("manifest schema is invalid")
    scenario = manifest.get("scenario")
    if scenario not in SCENARIOS:
        raise ValidationError("manifest scenario is unsupported")
    return scenario


def require_exact_keys(
    value: Any,
    expected: set[str],
    label: str,
    failures: list[str],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        failures.append(f"{label} is not an object")
        return {}
    if set(value) != expected:
        failures.append(f"{label} keys do not match schema v1")
    return value


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


def load_host_state(raw: bytes) -> tuple[list[dict[str, Any]], list[str]]:
    failures: list[str] = []
    if not raw.endswith(b"\n"):
        failures.append("Host runtime-state source is not newline terminated")
    lines = raw.splitlines()
    if not lines or len(lines) > MAXIMUM_STATE_RECORDS:
        return [], ["Host runtime-state record count is outside the bound"]
    records: list[dict[str, Any]] = []
    for index, line in enumerate(lines, start=1):
        if not line or len(line) > 65_536:
            failures.append(f"Host runtime-state record {index} size is invalid")
            continue
        try:
            record = strict_json(line, f"Host runtime-state record {index}")
        except ValidationError as error:
            failures.append(str(error))
            continue
        if set(record) != HOST_STATE_KEYS:
            failures.append(f"Host runtime-state record {index} keys are invalid")
        records.append(record)
    return records, failures


def validate_host_state(
    raw: bytes,
    system: dict[str, Any],
    scenario: str,
) -> tuple[dict[str, Any], list[str]]:
    records, failures = load_host_state(raw)
    valid: list[tuple[dict[str, Any], datetime]] = []
    previous_sequence: int | None = None
    previous_monotonic: int | None = None
    previous_captured: datetime | None = None
    system_started_at = parse_utc(system["startedAt"])
    if system_started_at is None:
        return {}, failures + ["system start timestamp is unavailable"]
    system_clock_offset = (
        datetime_nanoseconds(system_started_at)
        - system["startedMonotonicNanoseconds"]
    )
    for index, record in enumerate(records, start=1):
        sequence = record.get("sequence")
        monotonic = record.get("monotonicNanoseconds")
        captured = parse_utc(record.get("capturedAt"))
        if record.get("schema") != HOST_STATE_SCHEMA or record.get("schemaVersion") != 2:
            failures.append(f"Host runtime-state record {index} schema is invalid")
        if not is_integer(sequence) or sequence <= 0:
            failures.append(f"Host runtime-state record {index} sequence is invalid")
        if not is_integer(monotonic) or monotonic < 0:
            failures.append(f"Host runtime-state record {index} monotonic time is invalid")
        if captured is None:
            failures.append(f"Host runtime-state record {index} UTC time is invalid")
        if (
            previous_sequence is not None
            and is_integer(sequence)
            and sequence != previous_sequence + 1
        ):
            failures.append("Host runtime-state sequence has a gap or duplicate")
        if (
            previous_monotonic is not None
            and is_integer(monotonic)
            and monotonic <= previous_monotonic
        ):
            failures.append("Host runtime-state monotonic time is not increasing")
        if previous_captured is not None and captured is not None and captured < previous_captured:
            failures.append("Host runtime-state UTC time moved backwards")
        if is_integer(sequence):
            previous_sequence = sequence
        if is_integer(monotonic):
            previous_monotonic = monotonic
        if captured is not None:
            previous_captured = captured
        snapshot_observed = record.get("hostSnapshotObservedAtUnixMilliseconds")
        authenticated = record.get("authenticatedConnectionCount")
        if snapshot_observed is not None and (
            not is_integer(snapshot_observed) or snapshot_observed <= 0
        ):
            failures.append(
                f"Host runtime-state record {index} snapshot authority is invalid"
            )
        if authenticated is not None and (
            not is_integer(authenticated) or authenticated < 0
        ):
            failures.append(
                f"Host runtime-state record {index} connection count is invalid"
            )
        if record.get("hostState") not in {
            "created",
            "starting",
            "ready",
            "stopping",
            "stopped",
            "error",
            "unavailable",
        }:
            failures.append(f"Host runtime-state record {index} Host state is invalid")
        if record.get("registrationStatus") not in {
            "notStarted",
            "pending",
            "ready",
            "degraded",
            "unavailable",
        }:
            failures.append(
                f"Host runtime-state record {index} registration is invalid"
            )
        for key in (
            "hostRuntimeActive",
            "mediaRouteActive",
            "mediaPipelineActive",
        ):
            if not isinstance(record.get(key), bool):
                failures.append(f"Host runtime-state record {index} {key} is invalid")
        if captured is not None and is_integer(monotonic):
            valid.append((record, captured))

    start_mono = system["startedMonotonicNanoseconds"]
    end_mono = system["completedMonotonicNanoseconds"]
    before = [item for item in valid if item[0]["monotonicNanoseconds"] <= start_mono]
    after = [item for item in valid if item[0]["monotonicNanoseconds"] >= end_mono]
    if not before or not after:
        failures.append("Host runtime-state does not bracket the system window")
        selected: list[tuple[dict[str, Any], datetime]] = []
    else:
        first = before[-1]
        last = after[0]
        first_index = valid.index(first)
        last_index = valid.index(last)
        selected = valid[first_index : last_index + 1]
        start_gap = (start_mono - first[0]["monotonicNanoseconds"]) / 1_000_000_000
        end_gap = (last[0]["monotonicNanoseconds"] - end_mono) / 1_000_000_000
        if start_gap > MAXIMUM_STATE_GAP_SECONDS or end_gap > MAXIMUM_STATE_GAP_SECONDS:
            failures.append("Host runtime-state window edge gap exceeds 2.5 seconds")
        gaps = [
            (later[0]["monotonicNanoseconds"] - earlier[0]["monotonicNanoseconds"])
            / 1_000_000_000
            for earlier, later in zip(selected, selected[1:])
        ]
        if gaps and max(gaps) > MAXIMUM_STATE_GAP_SECONDS:
            failures.append("Host runtime-state cadence gap exceeds 2.5 seconds")

    contract = SCENARIO_CONTRACTS[scenario]
    for index, (record, captured) in enumerate(selected, start=1):
        monotonic = record["monotonicNanoseconds"]
        clock_offset = datetime_nanoseconds(captured) - monotonic
        if (
            abs(clock_offset - system_clock_offset)
            > MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS * 1_000_000_000
        ):
            failures.append(f"covered Host state {index} clock does not match sampler")
        snapshot_observed = record.get("hostSnapshotObservedAtUnixMilliseconds")
        if (
            not is_integer(snapshot_observed)
            or snapshot_observed <= 0
            or not -CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS
            <= int(captured.timestamp() * 1_000) - snapshot_observed
            <= MAXIMUM_SNAPSHOT_AGE_MILLISECONDS
        ):
            failures.append(f"covered Host state {index} snapshot age is invalid")
        if (
            record.get("hostRuntimeActive") is not True
            or record.get("hostState") != "ready"
            or record.get("registrationStatus") != "ready"
        ):
            failures.append(f"covered Host state {index} is not coherently ready")
        authenticated = record.get("authenticatedConnectionCount")
        if contract["authenticatedConnectionMode"] == "zero":
            if authenticated != 0:
                failures.append(f"covered Host state {index} has an inbound connection")
        elif not is_integer(authenticated) or authenticated < 1:
            failures.append(f"covered Host state {index} has no inbound connection")
        expected_media = contract["mediaActive"]
        if (
            record.get("mediaRouteActive") is not expected_media
            or record.get("mediaPipelineActive") is not expected_media
        ):
            failures.append(f"covered Host state {index} media activity is invalid")

    metrics = {
        "sourceRecordCount": len(records),
        "coveredRecordCount": len(selected),
        "maximumCoveredGapSeconds": round(
            max(
                [
                    (
                        later[0]["monotonicNanoseconds"]
                        - earlier[0]["monotonicNanoseconds"]
                    )
                    / 1_000_000_000
                    for earlier, later in zip(selected, selected[1:])
                ]
                or [0.0]
            ),
            3,
        ),
    }
    return metrics, failures


def validate_viewer_report(
    viewer: dict[str, Any],
    system: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    missing = VIEWER_REQUIRED_KEYS - set(viewer)
    if missing:
        failures.append("Viewer report is missing schema-v1 evidence fields")
    if viewer.get("schema") != VIEWER_SCHEMA or viewer.get("schemaVersion") != 1:
        failures.append("Viewer report schema is invalid")
    process_id = viewer.get("processID")
    if not is_integer(process_id) or process_id != system["viewer"].get("pid"):
        failures.append("Viewer report PID does not match system evidence")
    for key in ("bundleIdentifier", "buildIdentifier"):
        if not is_bounded_text(viewer.get(key), 128):
            failures.append(f"Viewer report {key} is invalid")
        elif viewer.get(key) != system["viewer"].get(key):
            failures.append(f"Viewer report {key} does not match system evidence")

    started_at = parse_utc(viewer.get("measurementStartedAt"))
    completed_at = parse_utc(viewer.get("timestamp"))
    started_mono = viewer.get("measurementStartedMonotonicNanoseconds")
    completed_mono = viewer.get("measurementCompletedMonotonicNanoseconds")
    first_presentation = viewer.get("firstPresentationMonotonicNanoseconds")
    last_presentation = viewer.get("lastPresentationMonotonicNanoseconds")
    duration = viewer.get("durationSeconds")
    if started_at is None or completed_at is None or completed_at <= started_at:
        failures.append("Viewer UTC measurement window is invalid")
    if (
        not is_integer(started_mono)
        or not is_integer(completed_mono)
        or started_mono < 0
        or completed_mono <= started_mono
    ):
        failures.append("Viewer monotonic measurement window is invalid")
        started_mono = 0
        completed_mono = 0
    monotonic_duration = (completed_mono - started_mono) / 1_000_000_000
    if not is_number(duration) or duration <= 0 or abs(float(duration) - monotonic_duration) > 2:
        failures.append("Viewer duration does not match its monotonic window")
    if started_at is not None and completed_at is not None:
        utc_duration = (completed_at - started_at).total_seconds()
        if abs(utc_duration - monotonic_duration) > 2:
            failures.append("Viewer UTC and monotonic windows are inconsistent")
        system_started_at = parse_utc(system["startedAt"])
        if system_started_at is not None:
            viewer_clock_offset = datetime_nanoseconds(started_at) - started_mono
            system_clock_offset = (
                datetime_nanoseconds(system_started_at)
                - system["startedMonotonicNanoseconds"]
            )
            if (
                abs(viewer_clock_offset - system_clock_offset)
                > MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS * 1_000_000_000
            ):
                failures.append("Viewer and system monotonic clocks do not match")
    if (
        started_mono > system["startedMonotonicNanoseconds"]
        or completed_mono < system["completedMonotonicNanoseconds"]
    ):
        failures.append("Viewer measurement does not contain the system window")
    if (
        not is_integer(first_presentation)
        or not is_integer(last_presentation)
        or first_presentation < started_mono
        or last_presentation <= first_presentation
        or last_presentation > completed_mono
    ):
        failures.append("Viewer first/last presentation authority is invalid")
        first_presentation = 0
        last_presentation = 0
    start_edge_gap = (
        first_presentation - system["startedMonotonicNanoseconds"]
    ) / 1_000_000_000
    end_edge_gap = (
        system["completedMonotonicNanoseconds"] - last_presentation
    ) / 1_000_000_000
    if start_edge_gap > MAXIMUM_STATE_GAP_SECONDS:
        failures.append("Viewer presentation began too late for the system window")
    if end_edge_gap > MAXIMUM_STATE_GAP_SECONDS:
        failures.append("Viewer presentation ended too early for the system window")
    max_gap = viewer.get("maxPresentationGapMS")
    final_staleness = viewer.get("finalPresentationStalenessMS")
    if (
        not is_number(max_gap)
        or max_gap < 0
        or max_gap > MAXIMUM_VIEWER_PRESENTATION_GAP_MILLISECONDS
    ):
        failures.append("Viewer presentation gap exceeds 2.5 seconds")
    expected_staleness = (completed_mono - last_presentation) / 1_000_000
    if (
        not is_number(final_staleness)
        or final_staleness < 0
        or abs(float(final_staleness) - expected_staleness) > 100
    ):
        failures.append("Viewer final presentation staleness is inconsistent")

    if viewer.get("source") != "rustdesk-live":
        failures.append("Viewer report source is not rustdesk-live")
    states = viewer.get("coreStateTransitions")
    if (
        not isinstance(states, list)
        or not states
        or len(states) > 128
        or any(not is_bounded_text(value, 256) for value in states)
    ):
        failures.append("Viewer core state transitions are invalid")
        states = []
    authenticated_indexes = [
        index
        for index, value in enumerate(states)
        if value.split(":", 1)[0] == "authenticated"
    ]
    streaming_indexes = [
        index
        for index, value in enumerate(states)
        if value.split(":", 1)[0] == "streaming"
    ]
    if (
        not authenticated_indexes
        or not streaming_indexes
        or min(authenticated_indexes) >= min(streaming_indexes)
    ):
        failures.append("Viewer did not authenticate before streaming")
    encoded = viewer.get("encodedFrames")
    decoded = viewer.get("decodedFrames")
    presented = viewer.get("presentedFrames")
    if (
        not is_integer(encoded)
        or not is_integer(decoded)
        or not is_integer(presented)
        or encoded <= 0
        or not 0 < decoded <= encoded
        or not 0 < presented <= decoded
    ):
        failures.append("Viewer encoded/decoded/presented frame counts are invalid")
    if viewer.get("hardwareDecodeActive") is not True:
        failures.append("Viewer hardware decode was not active")
    for key in (
        "processCPUPercent",
        "initialResidentMB",
        "finalResidentMB",
        "peakResidentMB",
    ):
        if not is_number(viewer.get(key)) or viewer.get(key) < 0:
            failures.append(f"Viewer report {key} is invalid")

    metrics = {
        "processID": process_id if is_integer(process_id) else 0,
        "durationSeconds": round(float(duration), 3) if is_number(duration) else 0,
        "encodedFrames": encoded if is_integer(encoded) else 0,
        "decodedFrames": decoded if is_integer(decoded) else 0,
        "presentedFrames": presented if is_integer(presented) else 0,
        "maximumPresentationGapMilliseconds": (
            round(float(max_gap), 3) if is_number(max_gap) else 0
        ),
    }
    return metrics, failures


def source_summary(
    manifest: dict[str, Any],
    raw_sources: dict[str, bytes],
) -> dict[str, dict[str, Any]]:
    return {
        name: {
            "path": manifest["sources"][name]["path"],
            "sha256": hash_bytes(raw_sources[name]),
            "byteCount": len(raw_sources[name]),
        }
        for name in SOURCE_NAMES
    }


def validate(manifest_path: Path) -> dict[str, Any]:
    if not manifest_path.is_absolute() or manifest_path.is_symlink():
        raise ValidationError("manifest path must be absolute and non-symlink")
    manifest_raw = read_bounded_regular(
        manifest_path, MAXIMUM_MANIFEST_BYTES, "manifest"
    )
    manifest = strict_json(manifest_raw, "manifest")
    scenario = validate_manifest_document(manifest)
    resolved, raw_sources = resolve_sources(manifest_path, manifest)
    system_document = strict_json(raw_sources["systemMetadata"], "system metadata")
    viewer_document = strict_json(raw_sources["viewerReport"], "Viewer report")
    system, system_failures = validate_system_metadata(
        system_document,
        scenario,
        resolved["systemSamples"],
        raw_sources["systemSamples"],
        resolved["systemLog"],
        raw_sources["systemLog"],
    )
    failures = list(system_failures)
    if system:
        sample_metrics, sample_failures = validate_system_samples(
            raw_sources["systemSamples"], system, scenario
        )
        host_metrics, host_failures = validate_host_state(
            raw_sources["hostRuntimeState"], system, scenario
        )
        viewer_metrics, viewer_failures = validate_viewer_report(
            viewer_document, system
        )
        failures.extend(sample_failures)
        failures.extend(host_failures)
        failures.extend(viewer_failures)
    else:
        sample_metrics = {}
        host_metrics = {}
        viewer_metrics = {}
        failures.append("system evidence could not establish a validation scope")
    status = "pass" if not failures else "fail"
    acceptance = system.get("sampleMode") == "acceptance" if system else False
    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "scenario": scenario,
        "sampleMode": system.get("sampleMode", "invalid") if system else "invalid",
        "requestedDurationSeconds": system.get("duration", 0) if system else 0,
        "status": status,
        "failures": failures,
        "sources": source_summary(manifest, raw_sources),
        "thresholds": SCENARIO_CONTRACTS[scenario],
        "metrics": {
            "system": sample_metrics,
            "hostRuntimeState": host_metrics,
            "viewer": viewer_metrics,
        },
        "claims": {
            "exactRoleAndBuildIdentityBound": status == "pass",
            "hostRuntimeStateBound": status == "pass",
            "viewerContinuousPresentationBound": status == "pass",
            "individualAndCombinedCPUThresholdEvaluated": status == "pass",
            "scenarioEvidenceComplete": status == "pass" and acceptance,
            "section15_2Item10Complete": False,
        },
    }


def validate_output_path(output_path: Path, manifest_path: Path) -> None:
    if not output_path.is_absolute() or output_path.suffix.lower() != ".json":
        raise ValidationError("output path must be an absolute JSON path")
    if output_path.is_symlink() or output_path.exists():
        raise ValidationError("refusing to overwrite existing output")
    if output_path == manifest_path:
        raise ValidationError("output path must differ from manifest")
    parent = output_path.parent
    if not parent.is_dir() or has_symlink_component(parent):
        raise ValidationError("output parent must be an existing non-symlink directory")
    metadata = parent.stat()
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise ValidationError("output parent ownership or permissions are unsafe")


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-combined-role-run-", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.link(temporary, path)
    except OSError as error:
        raise ValidationError("failed to publish combined-role result") from error
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 3:
        usage()
        return 2
    manifest_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    try:
        validate_output_path(output_path, manifest_path)
        result = validate(manifest_path)
        write_atomic_no_replace(output_path, result)
    except ValidationError as error:
        print(f"combined-role validation refused: {error}", file=sys.stderr)
        return 2
    print(
        f"status={result['status']} scenario={result['scenario']} "
        f"output={output_path} section_15_2_item_10_complete=false"
    )
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
