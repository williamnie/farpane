#!/usr/bin/env python3
"""Validate the dual-architecture base of the Host performance matrix."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MATRIX_SCHEMA = "farpane-host-base-performance-matrix-manifest"
OUTPUT_SCHEMA = "farpane-host-base-performance-matrix"
ARCHITECTURES = ("arm64", "x86_64")
REQUIREMENT_GROUPS = (
    "host-idle",
    "connected-static",
    "active-1080p30",
    "active-4k30-normal",
    "active-4k30-video",
    "stability-30-minute",
)
EXPECTED_SOURCE_COUNT = len(ARCHITECTURES) * len(REQUIREMENT_GROUPS)
MAX_SOURCE_BYTES = 1_048_576
MAX_MANIFEST_BYTES = 65_536

SCENARIO_CONTRACTS = {
    "host-ready-no-screen-route": {
        "group": "host-idle",
        "schema": "farpane-host-idle-run",
        "schemaVersion": 1,
        "profile": None,
        "minimumDurationSeconds": 600,
    },
    "static-1080p30": {
        "group": "connected-static",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "connected-static",
        "minimumDurationSeconds": 600,
    },
    "static-4k30": {
        "group": "connected-static",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "connected-static",
        "minimumDurationSeconds": 600,
    },
    "1080p30": {
        "group": "active-1080p30",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "active",
        "minimumDurationSeconds": 600,
    },
    "4k30-normal": {
        "group": "active-4k30-normal",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "active",
        "minimumDurationSeconds": 600,
    },
    "4k30-video": {
        "group": "active-4k30-video",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "active",
        "minimumDurationSeconds": 600,
    },
    "stability-1080p30": {
        "group": "stability-30-minute",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "stability",
        "minimumDurationSeconds": 1_800,
    },
    "stability-4k30": {
        "group": "stability-30-minute",
        "schema": "farpane-host-performance-run",
        "schemaVersion": 4,
        "profile": "stability",
        "minimumDurationSeconds": 1_800,
    },
}


def usage() -> None:
    print(
        "usage: validate-farpane-host-performance-matrix.py "
        "MANIFEST_JSON OUTPUT_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


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


def is_safe_relative_json_path(value: Any) -> bool:
    if not is_bounded_text(value, 512):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and candidate.suffix.lower() == ".json"
        and candidate.parts
        and all(part not in ("", ".", "..") for part in candidate.parts)
    )


def is_utc_timestamp(value: Any) -> bool:
    if not is_bounded_text(value, 32) or not value.endswith("Z"):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def load_bounded_json(path: Path, maximum_bytes: int) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if not raw or len(raw) > maximum_bytes:
        raise ValueError("JSON size is outside the accepted bound")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("JSON root is not an object")
    return value, raw


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-performance-matrix-", suffix=".tmp", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def validate_matrix(manifest_path: Path) -> dict[str, Any]:
    failures: list[str] = []
    source_results: list[dict[str, Any]] = []
    coverage: dict[str, dict[str, list[dict[str, Any]]]] = {
        architecture: {group: [] for group in REQUIREMENT_GROUPS}
        for architecture in ARCHITECTURES
    }
    machine_models: dict[str, set[str]] = {
        architecture: set() for architecture in ARCHITECTURES
    }
    macos_versions: dict[str, set[str]] = {
        architecture: set() for architecture in ARCHITECTURES
    }

    try:
        manifest, _ = load_bounded_json(manifest_path, MAX_MANIFEST_BYTES)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        manifest = {}
        failures.append("matrix manifest is missing or invalid JSON")

    if manifest:
        if set(manifest) != {"schema", "schemaVersion", "runs"}:
            failures.append("matrix manifest keys do not match schema v1")
        if manifest.get("schema") != MATRIX_SCHEMA or manifest.get("schemaVersion") != 1:
            failures.append("matrix manifest schema is invalid")

    runs = manifest.get("runs") if manifest else None
    if not isinstance(runs, list):
        failures.append("matrix manifest runs must be an array")
        runs = []
    elif len(runs) != EXPECTED_SOURCE_COUNT:
        failures.append(
            f"matrix manifest must contain exactly {EXPECTED_SOURCE_COUNT} run summaries"
        )

    manifest_root = manifest_path.parent.resolve()
    seen_paths: set[str] = set()
    for index, relative_path in enumerate(runs, start=1):
        source_failures: list[str] = []
        if not is_safe_relative_json_path(relative_path):
            failures.append(f"run {index} path is not a safe relative JSON path")
            continue
        if relative_path in seen_paths:
            failures.append(f"run {index} duplicates an earlier source path")
            continue
        seen_paths.add(relative_path)
        unresolved_path = manifest_root / relative_path
        try:
            source_path = unresolved_path.resolve(strict=True)
        except OSError:
            failures.append(f"run {index} source is missing or unreadable")
            continue
        if (
            source_path.parent != manifest_root
            and manifest_root not in source_path.parents
        ) or unresolved_path.is_symlink():
            failures.append(f"run {index} source escapes the manifest directory")
            continue
        try:
            source, raw_source = load_bounded_json(source_path, MAX_SOURCE_BYTES)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            failures.append(f"run {index} source is invalid JSON evidence")
            continue

        scenario = source.get("scenario")
        contract = (
            SCENARIO_CONTRACTS.get(scenario)
            if isinstance(scenario, str)
            else None
        )
        architecture = source.get("architecture")
        machine_model = source.get("machineModel")
        macos_version = source.get("macOSVersion")
        duration = source.get("requestedDurationSeconds")
        collected_at = source.get("collectedAt")

        if contract is None:
            source_failures.append("scenario is not part of the base matrix")
        else:
            if source.get("schema") != contract["schema"]:
                source_failures.append("run summary schema does not match its scenario")
            if source.get("schemaVersion") != contract["schemaVersion"]:
                source_failures.append("run summary schema version is unsupported")
            expected_profile = contract["profile"]
            if (
                expected_profile is not None
                and source.get("performanceProfile") != expected_profile
            ):
                source_failures.append("performance profile does not match its scenario")
            if (
                scenario == "host-ready-no-screen-route"
                and source.get("allAuthenticatedConnectionsProvenAbsent") is not True
            ):
                source_failures.append(
                    "idle evidence does not prove all authenticated connections absent"
                )
            if (
                not is_integer(duration)
                or duration < contract["minimumDurationSeconds"]
            ):
                source_failures.append("run duration is shorter than its matrix requirement")

        if source.get("sampleMode") != "acceptance":
            source_failures.append("run summary is not acceptance evidence")
        if source.get("status") != "pass" or source.get("failures") != []:
            source_failures.append("run summary did not pass its source validator")
        if architecture not in ARCHITECTURES:
            source_failures.append("run architecture is not arm64 or x86_64")
        if not is_bounded_text(machine_model, 128):
            source_failures.append("run machine model is missing or invalid")
        if not is_bounded_text(macos_version, 64):
            source_failures.append("run macOS version is missing or invalid")
        if not is_utc_timestamp(collected_at):
            source_failures.append("run collection timestamp is missing or invalid")

        source_result = {
            "path": relative_path,
            "sha256": hashlib.sha256(raw_source).hexdigest(),
            "scenario": scenario if is_bounded_text(scenario, 64) else "unavailable",
            "requirementGroup": (
                contract["group"] if contract is not None else "unavailable"
            ),
            "architecture": (
                architecture if architecture in ARCHITECTURES else "unavailable"
            ),
            "machineModel": (
                machine_model if is_bounded_text(machine_model, 128) else "unavailable"
            ),
            "macOSVersion": (
                macos_version if is_bounded_text(macos_version, 64) else "unavailable"
            ),
            "collectedAt": collected_at if is_utc_timestamp(collected_at) else "unavailable",
            "requestedDurationSeconds": duration if is_integer(duration) else 0,
            "status": "valid" if not source_failures else "invalid",
            "failures": source_failures,
        }
        source_results.append(source_result)
        if source_failures:
            failures.append(f"run {index} source failed matrix admission")
            continue

        assert contract is not None
        assert architecture in ARCHITECTURES
        coverage[architecture][contract["group"]].append(source_result)
        machine_models[architecture].add(machine_model)
        macos_versions[architecture].add(macos_version)

    requirement_results: dict[str, dict[str, str]] = {}
    for architecture in ARCHITECTURES:
        requirement_results[architecture] = {}
        for group in REQUIREMENT_GROUPS:
            count = len(coverage[architecture][group])
            if count == 1:
                requirement_results[architecture][group] = "pass"
            elif count == 0:
                requirement_results[architecture][group] = "missing"
                failures.append(f"{architecture} matrix requirement {group} is missing")
            else:
                requirement_results[architecture][group] = "duplicate"
                failures.append(f"{architecture} matrix requirement {group} is duplicated")
        if len(machine_models[architecture]) > 1:
            failures.append(f"{architecture} matrix mixes multiple machine models")
        if len(macos_versions[architecture]) > 1:
            failures.append(f"{architecture} matrix mixes multiple macOS versions")

    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "section-15.2-items-1-through-6-and-8",
        "fullSection15_2Complete": False,
        "coveredSection15_2Items": [1, 2, 3, 4, 5, 6, 8],
        "uncoveredSection15_2Items": [7, 9, 10],
        "architecturesRequired": list(ARCHITECTURES),
        "requirementGroups": list(REQUIREMENT_GROUPS),
        "requirements": requirement_results,
        "sources": source_results,
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "collectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def main() -> int:
    if len(sys.argv) != 3:
        usage()
        return 2
    manifest_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    if output_path.exists():
        print(f"refusing to overwrite existing artifact: {output_path}", file=sys.stderr)
        return 2
    result = validate_matrix(manifest_path)
    try:
        write_atomic_no_replace(output_path, result)
    except (OSError, FileExistsError) as error:
        print(f"failed to publish matrix evidence: {error}", file=sys.stderr)
        return 2
    print(
        f"result={result['status']} matrix_evidence={output_path} "
        f"sources={len(result['sources'])} full_section_15_2_complete=false"
    )
    if result["failures"]:
        print("gate failures: " + "; ".join(result["failures"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
