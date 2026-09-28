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
