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

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
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
    CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS,
    CSV_HEADER,
    HOST_STATE_KEYS,
    HOST_STATE_SCHEMA,
    MACHINE_KEYS,
    MANIFEST_KEYS,
    MANIFEST_SCHEMA,
    MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS,
    MAXIMUM_MANIFEST_BYTES,
    MAXIMUM_SAMPLE_GAP_SECONDS,
    MAXIMUM_SNAPSHOT_AGE_MILLISECONDS,
    MAXIMUM_STATE_GAP_SECONDS,
    MAXIMUM_STATE_RECORDS,
    MAXIMUM_VIEWER_PRESENTATION_GAP_MILLISECONDS,
    OUTPUT_SCHEMA,
    RESOURCE_AUTHORITY_KEYS,
    ROLES_KEYS,
    ROLE_KEYS,
    SCENARIOS,
    SCENARIO_CONTRACTS,
    SHA256_PATTERN,
    SOURCE_KEYS,
    SOURCE_MAXIMUM_BYTES,
    SOURCE_NAMES,
    SOURCE_SUFFIXES,
    SUPPORTED_ARCHITECTURES,
    SYSTEM_CLAIM_KEYS,
    SYSTEM_KEYS,
    SYSTEM_SCHEMA,
    SYSTEM_WINDOW_KEYS,
    VIEWER_REQUIRED_KEYS,
    VIEWER_SCHEMA,
    ValidationError,
    datetime_nanoseconds,
    parse_utc,
    read_bounded_regular,
    require_exact_keys,
    resolve_sources,
    safe_relative_source_path,
    strict_json,
    usage,
    validate_manifest_document,
)
from Scripts.evidence_combined.system import (
    average,
    parse_csv_float,
    parse_csv_int,
    parse_energy,
    validate_role,
    validate_system_metadata,
    validate_system_samples,
)
from Scripts.evidence_combined.host import (
    load_host_state,
    validate_host_state,
)
from Scripts.evidence_combined.viewer import (
    validate_viewer_report,
)


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
    machine = system.get("machine", {}) if system else {}
    viewer_scope = system.get("viewer", {}) if system else {}
    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "scenario": scenario,
        "sampleMode": system.get("sampleMode", "invalid") if system else "invalid",
        "requestedDurationSeconds": system.get("duration", 0) if system else 0,
        "status": status,
        "failures": failures,
        "scope": {
            "machineModel": machine.get("machineModel", "unavailable"),
            "architecture": machine.get("architecture", "unavailable"),
            "macOSVersion": machine.get("macOSVersion", "unavailable"),
            "bundleIdentifier": viewer_scope.get(
                "bundleIdentifier", "unavailable"
            ),
            "buildIdentifier": viewer_scope.get(
                "buildIdentifier", "unavailable"
            ),
            "shortVersion": viewer_scope.get("shortVersion", "unavailable"),
            "executableSHA256": viewer_scope.get(
                "executableSHA256", "unavailable"
            ),
        },
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
