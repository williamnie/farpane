#!/usr/bin/env python3
"""Validate three exact Host recoveries and their post-recovery 1080p30 runs."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MANIFEST_SCHEMA = "farpane-host-performance-recovery-manifest"
OUTPUT_SCHEMA = "farpane-host-performance-recovery"
TRANSITION_SCHEMA = "farpane-host-recovery-transition"
RUN_SCHEMA = "farpane-host-performance-run"
RECOVERY_KINDS = ("sleepWake", "networkPath", "displayReconfigure")
MAX_MANIFEST_BYTES = 65_536
MAX_TRANSITION_BYTES = 1_048_576
MAX_RUN_BYTES = 1_048_576
MAX_TRANSITION_RECORDS = 128
EXPECTED_RUN_COUNT = len(RECOVERY_KINDS)


def usage() -> None:
    print(
        "usage: validate-farpane-host-performance-recovery.py "
        "MANIFEST_JSON OUTPUT_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


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


def is_lowercase_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def is_safe_relative_path(value: Any, suffix: str) -> bool:
    if not is_bounded_text(value, 512):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and candidate.suffix.lower() == suffix
        and candidate.parts
        and all(part not in ("", ".", "..") for part in candidate.parts)
    )


def parse_utc_timestamp(value: Any) -> datetime | None:
    if not is_bounded_text(value, 32) or not value.endswith("Z"):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def load_bounded_json(path: Path, maximum_bytes: int) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if not raw or len(raw) > maximum_bytes:
        raise ValueError("JSON size is outside the accepted bound")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("JSON root is not an object")
    return value, raw


def has_symlink_component(root: Path, relative_path: Path) -> bool:
    current = root
    for component in relative_path.parts:
        current = current / component
        if current.is_symlink():
            return True
    return False


def resolve_source(
    root: Path,
    relative_value: Any,
    suffix: str,
) -> tuple[Path | None, str | None]:
    if not is_safe_relative_path(relative_value, suffix):
        return None, "path is not a safe relative source path"
    relative_path = Path(relative_value)
    if has_symlink_component(root, relative_path):
        return None, "source path contains a symlink"
    unresolved = root / relative_path
    try:
        resolved = unresolved.resolve(strict=True)
    except OSError:
        return None, "source is missing or unreadable"
    if root != resolved.parent and root not in resolved.parents:
        return None, "source escapes the manifest directory"
    if not resolved.is_file():
        return None, "source is not a regular file"
    return resolved, None


def valid_correlation(kind: str, value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    if kind == "sleepWake":
        return (
            set(value) == {"recoveryEpoch", "runningReadyConverged"}
            and is_integer(value.get("recoveryEpoch"))
            and value["recoveryEpoch"] > 0
            and value.get("runningReadyConverged") is True
        )
    if kind == "networkPath":
        return (
            set(value)
            == {"pathGeneration", "recoveryEpoch", "runningReadyConverged"}
            and is_integer(value.get("pathGeneration"))
            and value["pathGeneration"] > 0
            and is_integer(value.get("recoveryEpoch"))
            and value["recoveryEpoch"] >= 0
            and value.get("runningReadyConverged") is True
        )
    if kind == "displayReconfigure":
        expected = {
            "previousDisplayRevision",
            "replacementDisplayRevision",
            "previousConnectionEpoch",
            "replacementConnectionEpoch",
            "previousCodecEpoch",
            "replacementCodecEpoch",
            "freshRouteConverged",
        }
        if set(value) != expected or value.get("freshRouteConverged") is not True:
            return False
        fields = [
            value.get("previousDisplayRevision"),
            value.get("replacementDisplayRevision"),
            value.get("previousConnectionEpoch"),
            value.get("replacementConnectionEpoch"),
            value.get("previousCodecEpoch"),
            value.get("replacementCodecEpoch"),
        ]
        return (
            all(is_integer(field) and field > 0 for field in fields)
            and fields[1] == fields[0] + 1
            and fields[3] > fields[2]
            and fields[5] > fields[4]
        )
    return False


def validate_transition_record(
    record: dict[str, Any],
    expected_sequence: int,
) -> list[str]:
    failures: list[str] = []
    expected_keys = {
        "schema",
        "schemaVersion",
        "sequence",
        "kind",
        "acceptedAt",
        "completedAt",
        "acceptedMonotonicNanoseconds",
        "completedMonotonicNanoseconds",
        "status",
        "hostInstanceScopeSHA256",
        "buildIdentitySHA256",
        "correlation",
    }
    if set(record) != expected_keys:
        failures.append("transition keys do not match schema v1")
    if record.get("schema") != TRANSITION_SCHEMA or record.get("schemaVersion") != 1:
        failures.append("transition schema is unsupported")
    if record.get("sequence") != expected_sequence:
        failures.append("transition sequence is not contiguous")
    kind = record.get("kind")
    if kind not in RECOVERY_KINDS:
        failures.append("transition kind is unsupported")
    if record.get("status") != "completed":
        failures.append("transition status is not completed")
    accepted_at = parse_utc_timestamp(record.get("acceptedAt"))
    completed_at = parse_utc_timestamp(record.get("completedAt"))
    if accepted_at is None or completed_at is None or completed_at < accepted_at:
        failures.append("transition wall timestamps are invalid")
    accepted_monotonic = record.get("acceptedMonotonicNanoseconds")
    completed_monotonic = record.get("completedMonotonicNanoseconds")
    if (
        not is_integer(accepted_monotonic)
        or accepted_monotonic <= 0
        or not is_integer(completed_monotonic)
        or completed_monotonic <= accepted_monotonic
    ):
        failures.append("transition monotonic timestamps are invalid")
    if not is_lowercase_sha256(record.get("hostInstanceScopeSHA256")):
        failures.append("transition Host scope digest is invalid")
    if not is_lowercase_sha256(record.get("buildIdentitySHA256")):
        failures.append("transition build digest is invalid")
    if kind in RECOVERY_KINDS and not valid_correlation(kind, record.get("correlation")):
        failures.append("transition correlation is invalid")
    return failures


def load_transition_records(
    source_path: Path,
) -> tuple[list[dict[str, Any]], bytes, list[str]]:
    failures: list[str] = []
    try:
        raw = source_path.read_bytes()
    except OSError:
        return [], b"", ["transition source is missing or unreadable"]
    if not raw or len(raw) > MAX_TRANSITION_BYTES:
        return [], raw, ["transition source size is outside the accepted bound"]
    if not raw.endswith(b"\n"):
        failures.append("transition source is not newline terminated")
    lines = raw.splitlines()
    if not lines or len(lines) > MAX_TRANSITION_RECORDS:
        return [], raw, ["transition record count is outside the accepted bound"]
    records: list[dict[str, Any]] = []
    for index, raw_line in enumerate(lines, start=1):
        if not raw_line or len(raw_line) > 65_536:
            failures.append(f"transition {index} record size is invalid")
            continue
        try:
            record = json.loads(raw_line.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            failures.append(f"transition {index} is invalid JSON")
            continue
        if not isinstance(record, dict):
            failures.append(f"transition {index} root is not an object")
            continue
        record_failures = validate_transition_record(record, index)
        failures.extend(
            f"transition {index} {failure}" for failure in record_failures
        )
        records.append({
            "document": record,
            "recordSHA256": hashlib.sha256(raw_line).hexdigest(),
        })
    return records, raw, failures


def validate_run(source: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    if source.get("schema") != RUN_SCHEMA or source.get("schemaVersion") != 5:
        failures.append("run summary is not recovery schema v5")
    if source.get("scenario") != "1080p30" or source.get("performanceProfile") != "active":
        failures.append("run summary is not the active 1080p30 scenario")
    duration = source.get("requestedDurationSeconds")
    if not is_integer(duration) or duration < 600:
        failures.append("run duration is shorter than 600 seconds")
    if source.get("sampleMode") != "acceptance":
        failures.append("run summary is not acceptance evidence")
    if source.get("status") != "pass" or source.get("failures") != []:
        failures.append("run summary did not pass its source validator")

    architecture = source.get("architecture")
    machine_model = source.get("machineModel")
    macos_version = source.get("macOSVersion")
    if architecture not in ("arm64", "x86_64"):
        failures.append("run architecture is unsupported")
    if not is_bounded_text(machine_model, 128):
        failures.append("run machine model is missing or invalid")
    if not is_bounded_text(macos_version, 64):
        failures.append("run macOS version is missing or invalid")

    started_at = parse_utc_timestamp(source.get("sampleStartedAt"))
    completed_at = parse_utc_timestamp(source.get("sampleCompletedAt"))
    collected_at = parse_utc_timestamp(source.get("collectedAt"))
    if started_at is None or completed_at is None or collected_at is None:
        failures.append("run timestamps are missing or invalid")
    elif (
        completed_at <= started_at
        or collected_at < completed_at
        or not is_integer(duration)
        or (completed_at - started_at).total_seconds() < duration
    ):
        failures.append("run timestamps do not cover its complete sampling window")

    binding = source.get("recoveryTransition")
    expected_binding_keys = {
        "kind",
        "sequence",
        "recordSHA256",
        "completedAt",
        "hostInstanceScopeSHA256",
        "buildIdentitySHA256",
    }
    if not isinstance(binding, dict) or set(binding) != expected_binding_keys:
        failures.append("run recovery binding does not match schema v1")
        binding = {}
    kind = binding.get("kind")
    sequence = binding.get("sequence")
    transition_completed_at = parse_utc_timestamp(binding.get("completedAt"))
    if kind not in RECOVERY_KINDS:
        failures.append("run recovery kind is unsupported")
    if not is_integer(sequence) or sequence <= 0:
        failures.append("run recovery sequence is invalid")
    if not is_lowercase_sha256(binding.get("recordSHA256")):
        failures.append("run transition record digest is invalid")
    if not is_lowercase_sha256(binding.get("hostInstanceScopeSHA256")):
        failures.append("run Host scope digest is invalid")
    if not is_lowercase_sha256(binding.get("buildIdentitySHA256")):
        failures.append("run build digest is invalid")
    if transition_completed_at is None:
        failures.append("run transition completion timestamp is invalid")
    elif started_at is not None and transition_completed_at >= started_at:
        failures.append("run did not start after its recovery completed")

    normalized = {
        "kind": kind if kind in RECOVERY_KINDS else "unavailable",
        "sequence": sequence if is_integer(sequence) and sequence > 0 else 0,
        "recordSHA256": (
            binding.get("recordSHA256")
            if is_lowercase_sha256(binding.get("recordSHA256"))
            else "unavailable"
        ),
        "hostInstanceScopeSHA256": (
            binding.get("hostInstanceScopeSHA256")
            if is_lowercase_sha256(binding.get("hostInstanceScopeSHA256"))
            else "unavailable"
        ),
        "buildIdentitySHA256": (
            binding.get("buildIdentitySHA256")
            if is_lowercase_sha256(binding.get("buildIdentitySHA256"))
            else "unavailable"
        ),
        "transitionCompletedAt": (
            binding.get("completedAt")
            if transition_completed_at is not None
            else "unavailable"
        ),
        "sampleStartedAt": (
            source.get("sampleStartedAt") if started_at is not None else "unavailable"
        ),
        "sampleCompletedAt": (
            source.get("sampleCompletedAt") if completed_at is not None else "unavailable"
        ),
        "machineModel": (
            machine_model if is_bounded_text(machine_model, 128) else "unavailable"
        ),
        "architecture": (
            architecture if architecture in ("arm64", "x86_64") else "unavailable"
        ),
        "macOSVersion": (
            macos_version if is_bounded_text(macos_version, 64) else "unavailable"
        ),
        "requestedDurationSeconds": duration if is_integer(duration) else 0,
    }
    return normalized, failures


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-performance-recovery-", suffix=".tmp", dir=path.parent
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


def validate_manifest(manifest_path: Path) -> dict[str, Any]:
    failures: list[str] = []
    source_results: list[dict[str, Any]] = []
    root = manifest_path.parent.resolve()
    if manifest_path.is_symlink():
        failures.append("manifest path must not be a symlink")
    try:
        manifest, _ = load_bounded_json(manifest_path, MAX_MANIFEST_BYTES)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        manifest = {}
        failures.append("recovery manifest is missing or invalid JSON")

    expected_manifest_keys = {"schema", "schemaVersion", "transitionSource", "runs"}
    if manifest:
        if set(manifest) != expected_manifest_keys:
            failures.append("recovery manifest keys do not match schema v1")
        if manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("schemaVersion") != 1:
            failures.append("recovery manifest schema is invalid")

    transition_entry = manifest.get("transitionSource") if manifest else None
    transition_records: list[dict[str, Any]] = []
    transition_source_result: dict[str, Any] = {
        "path": "unavailable",
        "sha256": "unavailable",
        "recordCount": 0,
        "status": "invalid",
        "failures": [],
    }
    if not isinstance(transition_entry, dict) or set(transition_entry) != {"path", "sha256"}:
        failures.append("transitionSource does not match manifest schema v1")
    else:
        transition_path, path_failure = resolve_source(
            root, transition_entry.get("path"), ".jsonl"
        )
        transition_failures: list[str] = []
        if path_failure is not None:
            transition_failures.append(path_failure)
        expected_digest = transition_entry.get("sha256")
        if not is_lowercase_sha256(expected_digest):
            transition_failures.append("declared transition source digest is invalid")
        raw_transition = b""
        if transition_path is not None:
            transition_records, raw_transition, record_failures = load_transition_records(
                transition_path
            )
            transition_failures.extend(record_failures)
            actual_digest = hashlib.sha256(raw_transition).hexdigest()
            if is_lowercase_sha256(expected_digest) and actual_digest != expected_digest:
                transition_failures.append("transition source digest does not match manifest")
            transition_source_result.update({
                "path": transition_entry["path"],
                "sha256": actual_digest,
                "recordCount": len(transition_records),
            })
        transition_source_result["failures"] = transition_failures
        transition_source_result["status"] = (
            "valid" if not transition_failures else "invalid"
        )
        if transition_failures:
            failures.append("transition source failed recovery admission")

    runs = manifest.get("runs") if manifest else None
    if not isinstance(runs, list):
        failures.append("recovery manifest runs must be an array")
        runs = []
    elif len(runs) != EXPECTED_RUN_COUNT:
        failures.append(
            f"recovery manifest must contain exactly {EXPECTED_RUN_COUNT} run summaries"
        )

    seen_paths: set[str] = set()
    seen_declared_digests: set[str] = set()
    valid_runs: list[dict[str, Any]] = []
    for index, entry in enumerate(runs, start=1):
        source_failures: list[str] = []
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
            failures.append(f"run {index} entry does not match manifest schema v1")
            continue
        relative_path = entry.get("path")
        declared_digest = entry.get("sha256")
        if isinstance(relative_path, str) and relative_path in seen_paths:
            failures.append(f"run {index} duplicates an earlier source path")
            continue
        if isinstance(relative_path, str):
            seen_paths.add(relative_path)
        if is_lowercase_sha256(declared_digest) and declared_digest in seen_declared_digests:
            failures.append(f"run {index} duplicates an earlier source digest")
            continue
        if is_lowercase_sha256(declared_digest):
            seen_declared_digests.add(declared_digest)
        else:
            source_failures.append("declared run source digest is invalid")

        source_path, path_failure = resolve_source(root, relative_path, ".json")
        if path_failure is not None:
            source_failures.append(path_failure)
        source: dict[str, Any] = {}
        raw_source = b""
        if source_path is not None:
            try:
                source, raw_source = load_bounded_json(source_path, MAX_RUN_BYTES)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                source_failures.append("run source is invalid JSON evidence")
        actual_digest = hashlib.sha256(raw_source).hexdigest() if raw_source else "unavailable"
        if (
            raw_source
            and is_lowercase_sha256(declared_digest)
            and actual_digest != declared_digest
        ):
            source_failures.append("run source digest does not match manifest")
        normalized: dict[str, Any] = {
            "kind": "unavailable",
            "recordSHA256": "unavailable",
            "hostInstanceScopeSHA256": "unavailable",
            "buildIdentitySHA256": "unavailable",
            "machineModel": "unavailable",
            "architecture": "unavailable",
            "macOSVersion": "unavailable",
            "requestedDurationSeconds": 0,
        }
        if source:
            normalized, run_failures = validate_run(source)
            source_failures.extend(run_failures)
        source_result = {
            "path": relative_path if isinstance(relative_path, str) else "unavailable",
            "sha256": actual_digest,
            **normalized,
            "status": "valid" if not source_failures else "invalid",
            "failures": source_failures,
        }
        source_results.append(source_result)
        if source_failures:
            failures.append(f"run {index} source failed recovery admission")
        else:
            valid_runs.append(source_result)

    record_by_digest = {
        record["recordSHA256"]: record["document"]
        for record in transition_records
    }
    selected_record_digests: set[str] = set()
    kinds: set[str] = set()
    scope_digests: set[str] = set()
    build_digests: set[str] = set()
    machine_models: set[str] = set()
    architectures: set[str] = set()
    macos_versions: set[str] = set()
    for run in valid_runs:
        record_digest = run["recordSHA256"]
        record = record_by_digest.get(record_digest)
        if record is None:
            failures.append(f"{run['kind']} run references a missing transition record")
            continue
        if record_digest in selected_record_digests:
            failures.append("multiple runs reference the same transition record")
            continue
        selected_record_digests.add(record_digest)
        if (
            record.get("kind") != run["kind"]
            or record.get("sequence") != run["sequence"]
            or record.get("completedAt") != run["transitionCompletedAt"]
            or record.get("hostInstanceScopeSHA256")
            != run["hostInstanceScopeSHA256"]
            or record.get("buildIdentitySHA256") != run["buildIdentitySHA256"]
        ):
            failures.append(f"{run['kind']} run binding does not match its transition")
            continue
        kinds.add(run["kind"])
        scope_digests.add(run["hostInstanceScopeSHA256"])
        build_digests.add(run["buildIdentitySHA256"])
        machine_models.add(run["machineModel"])
        architectures.add(run["architecture"])
        macos_versions.add(run["macOSVersion"])

    if kinds != set(RECOVERY_KINDS):
        failures.append("recovery runs must cover sleepWake, networkPath, and displayReconfigure exactly once")
    if len(scope_digests) != 1:
        failures.append("recovery runs do not share one Host instance scope")
    if len(build_digests) != 1:
        failures.append("recovery runs do not share one build identity")
    if len(machine_models) != 1 or len(architectures) != 1 or len(macos_versions) != 1:
        failures.append("recovery runs do not share one machine and macOS identity")

    requirements = {
        kind: "pass" if kind in kinds else "missing" for kind in RECOVERY_KINDS
    }
    status = "pass" if not failures else "fail"
    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "section15_2Item": 7,
        "fullSection15_2Item7Complete": status == "pass",
        "requiredScenario": "1080p30",
        "minimumPostRecoveryDurationSeconds": 600,
        "requirements": requirements,
        "transitionSource": transition_source_result,
        "sources": source_results,
        "machineModel": next(iter(machine_models)) if len(machine_models) == 1 else "unavailable",
        "architecture": next(iter(architectures)) if len(architectures) == 1 else "unavailable",
        "macOSVersion": next(iter(macos_versions)) if len(macos_versions) == 1 else "unavailable",
        "hostInstanceScopeSHA256": (
            next(iter(scope_digests)) if len(scope_digests) == 1 else "unavailable"
        ),
        "buildIdentitySHA256": (
            next(iter(build_digests)) if len(build_digests) == 1 else "unavailable"
        ),
        "status": status,
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
    result = validate_manifest(manifest_path)
    try:
        write_atomic_no_replace(output_path, result)
    except (OSError, FileExistsError) as error:
        print(f"failed to publish recovery evidence: {error}", file=sys.stderr)
        return 2
    print(
        f"result={result['status']} recovery_evidence={output_path} "
        f"sources={len(result['sources'])} "
        f"section_15_2_item_7_complete={str(result['fullSection15_2Item7Complete']).lower()}"
    )
    if result["failures"]:
        print("gate failures: " + "; ".join(result["failures"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
