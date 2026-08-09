#!/usr/bin/env python3
"""Pair the two passing §15.2 item 10 combined-role acceptance runs."""

from __future__ import annotations

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
from typing import Any


MANIFEST_SCHEMA = "farpane-host-combined-role-pair-manifest"
RUN_SCHEMA = "farpane-host-combined-role-run"
OUTPUT_SCHEMA = "farpane-host-combined-role-pair"
RUN_NAMES = ("hostReadyViewer", "hostViewerDual")
RUN_SCENARIOS = {
    "hostReadyViewer": "host-ready-viewer",
    "hostViewerDual": "host-viewer-dual",
}
SCENARIO_THRESHOLDS = {
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
SOURCE_NAMES = {
    "systemMetadata",
    "systemSamples",
    "systemLog",
    "hostRuntimeState",
    "viewerReport",
}
MAXIMUM_MANIFEST_BYTES = 65_536
MAXIMUM_RUN_BYTES = 2 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

MANIFEST_KEYS = {"schema", "schemaVersion", "runs"}
RUN_REFERENCE_KEYS = {"path", "sha256"}
RUN_KEYS = {
    "schema",
    "schemaVersion",
    "scenario",
    "sampleMode",
    "requestedDurationSeconds",
    "status",
    "failures",
    "scope",
    "sources",
    "thresholds",
    "metrics",
    "claims",
}
SCOPE_KEYS = {
    "machineModel",
    "architecture",
    "macOSVersion",
    "bundleIdentifier",
    "buildIdentifier",
    "shortVersion",
    "executableSHA256",
}
SOURCE_SUMMARY_KEYS = {"path", "sha256", "byteCount"}
METRICS_KEYS = {"system", "hostRuntimeState", "viewer"}
SYSTEM_METRIC_KEYS = {
    "sampleCount",
    "maximumSampleGapSeconds",
    "hostAgentAverageCPUPercent",
    "viewerAverageCPUPercent",
    "combinedAverageCPUPercent",
    "hostAgentPeakRSSKB",
    "viewerPeakRSSKB",
    "hostAgentPeakThreads",
    "viewerPeakThreads",
}
HOST_METRIC_KEYS = {
    "sourceRecordCount",
    "coveredRecordCount",
    "maximumCoveredGapSeconds",
}
VIEWER_METRIC_KEYS = {
    "processID",
    "durationSeconds",
    "encodedFrames",
    "decodedFrames",
    "presentedFrames",
    "maximumPresentationGapMilliseconds",
}
CLAIM_KEYS = {
    "exactRoleAndBuildIdentityBound",
    "hostRuntimeStateBound",
    "viewerContinuousPresentationBound",
    "individualAndCombinedCPUThresholdEvaluated",
    "scenarioEvidenceComplete",
    "section15_2Item10Complete",
}


class PairValidationError(RuntimeError):
    pass


def usage() -> None:
    print(
        "usage: validate-farpane-host-combined-role-pair.py "
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


def strict_json(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"non-finite {token}")
            ),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise PairValidationError(f"{label} is invalid strict JSON") from error
    if not isinstance(value, dict):
        raise PairValidationError(f"{label} root is not an object")
    return value


def hash_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def has_symlink_component(path: Path) -> bool:
    if not path.is_absolute():
        return True
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            return True
    return False


def safe_relative_json_path(value: Any) -> bool:
    if not is_bounded_text(value, 512):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and candidate.suffix.lower() == ".json"
        and candidate.parts
        and all(part not in ("", ".", "..") for part in candidate.parts)
    )


def read_bounded_regular(path: Path, maximum_bytes: int, label: str) -> bytes:
    if path.is_symlink():
        raise PairValidationError(f"{label} must not be a symlink")
    try:
        metadata = path.stat()
    except OSError as error:
        raise PairValidationError(f"{label} is missing or unreadable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > maximum_bytes
    ):
        raise PairValidationError(f"{label} identity or size is invalid")
    try:
        return path.read_bytes()
    except OSError as error:
        raise PairValidationError(f"{label} is unreadable") from error


def resolve_run_sources(
    manifest_path: Path,
    manifest: dict[str, Any],
) -> tuple[dict[str, Path], dict[str, bytes]]:
    runs = manifest.get("runs")
    if not isinstance(runs, dict) or set(runs) != set(RUN_NAMES):
        raise PairValidationError("pair manifest runs do not match schema v1")
    root = manifest_path.parent.resolve()
    paths: dict[str, Path] = {}
    raw_runs: dict[str, bytes] = {}
    seen_paths: set[Path] = set()
    seen_file_identities: set[tuple[int, int]] = set()
    for name in RUN_NAMES:
        reference = runs.get(name)
        if not isinstance(reference, dict) or set(reference) != RUN_REFERENCE_KEYS:
            raise PairValidationError(f"pair run {name} reference is invalid")
        relative = reference.get("path")
        if not safe_relative_json_path(relative):
            raise PairValidationError(f"pair run {name} path is unsafe")
        path = manifest_path.parent / relative
        try:
            canonical = path.resolve(strict=True)
        except OSError as error:
            raise PairValidationError(f"pair run {name} is missing") from error
        if canonical.parent != root and root not in canonical.parents:
            raise PairValidationError(f"pair run {name} escapes its root")
        if path.is_symlink() or canonical != path.absolute():
            raise PairValidationError(f"pair run {name} uses a symlink")
        raw = read_bounded_regular(canonical, MAXIMUM_RUN_BYTES, f"pair run {name}")
        metadata = canonical.stat()
        file_identity = (metadata.st_dev, metadata.st_ino)
        if canonical in seen_paths or file_identity in seen_file_identities:
            raise PairValidationError("pair runs contain a duplicate file")
        seen_paths.add(canonical)
        seen_file_identities.add(file_identity)
        expected_digest = reference.get("sha256")
        if not is_sha256(expected_digest) or hash_bytes(raw) != expected_digest:
            raise PairValidationError(f"pair run {name} SHA-256 does not match")
        paths[name] = canonical
        raw_runs[name] = raw
    return paths, raw_runs


def validate_manifest(manifest: dict[str, Any]) -> None:
    if set(manifest) != MANIFEST_KEYS:
        raise PairValidationError("pair manifest keys do not match schema v1")
    if (
        manifest.get("schema") != MANIFEST_SCHEMA
        or manifest.get("schemaVersion") != 1
    ):
        raise PairValidationError("pair manifest schema is invalid")


def validate_scope(scope: Any, failures: list[str], label: str) -> dict[str, Any]:
    if not isinstance(scope, dict) or set(scope) != SCOPE_KEYS:
        failures.append(f"{label} scope keys do not match schema v1")
        return {}
    for key in (
        "machineModel",
        "macOSVersion",
        "bundleIdentifier",
        "buildIdentifier",
        "shortVersion",
    ):
        if not is_bounded_text(scope.get(key), 128):
            failures.append(f"{label} scope {key} is invalid")
    if scope.get("architecture") not in ("arm64", "x86_64"):
        failures.append(f"{label} scope architecture is unsupported")
    if not is_sha256(scope.get("executableSHA256")):
        failures.append(f"{label} executable SHA-256 is invalid")
    return scope


def validate_source_summaries(
    sources: Any,
    failures: list[str],
    label: str,
) -> None:
    if not isinstance(sources, dict) or set(sources) != SOURCE_NAMES:
        failures.append(f"{label} source summaries do not match schema v1")
        return
    seen_paths: set[str] = set()
    seen_digests: set[str] = set()
    for name in SOURCE_NAMES:
        source = sources.get(name)
        if not isinstance(source, dict) or set(source) != SOURCE_SUMMARY_KEYS:
            failures.append(f"{label} source summary {name} is invalid")
            continue
        path = source.get("path")
        digest = source.get("sha256")
        byte_count = source.get("byteCount")
        if not is_bounded_text(path, 512):
            failures.append(f"{label} source summary {name} path is invalid")
        elif path in seen_paths:
            failures.append(f"{label} source summary path is duplicated")
        else:
            seen_paths.add(path)
        if not is_sha256(digest):
            failures.append(f"{label} source summary {name} digest is invalid")
        elif digest in seen_digests:
            failures.append(f"{label} source summary digest is duplicated")
        else:
            seen_digests.add(digest)
        if not is_integer(byte_count) or byte_count <= 0:
            failures.append(f"{label} source summary {name} size is invalid")


def validate_metrics(
    metrics: Any,
    scenario: str,
    duration: int,
    failures: list[str],
    label: str,
) -> None:
    if not isinstance(metrics, dict) or set(metrics) != METRICS_KEYS:
        failures.append(f"{label} metrics do not match schema v1")
        return
    system = metrics.get("system")
    host = metrics.get("hostRuntimeState")
    viewer = metrics.get("viewer")
    if not isinstance(system, dict) or set(system) != SYSTEM_METRIC_KEYS:
        failures.append(f"{label} system metrics are invalid")
        system = {}
    if not isinstance(host, dict) or set(host) != HOST_METRIC_KEYS:
        failures.append(f"{label} Host metrics are invalid")
        host = {}
    if not isinstance(viewer, dict) or set(viewer) != VIEWER_METRIC_KEYS:
        failures.append(f"{label} Viewer metrics are invalid")
        viewer = {}
    thresholds = SCENARIO_THRESHOLDS[scenario]
    if system:
        if system.get("sampleCount") != duration:
            failures.append(f"{label} system sample count does not match duration")
        if (
            not is_number(system.get("maximumSampleGapSeconds"))
            or not 0 <= system["maximumSampleGapSeconds"] <= 2.5
        ):
            failures.append(f"{label} system cadence gap is invalid")
        for key, threshold_key in (
            ("hostAgentAverageCPUPercent", "hostAgentAverageCPUCeilingPercent"),
            ("viewerAverageCPUPercent", "viewerAverageCPUCeilingPercent"),
            ("combinedAverageCPUPercent", "combinedAverageCPUCeilingPercent"),
        ):
            value = system.get(key)
            if not is_number(value) or not 0 <= value < thresholds[threshold_key]:
                failures.append(f"{label} {key} does not pass its threshold")
        for key in (
            "hostAgentPeakRSSKB",
            "viewerPeakRSSKB",
            "hostAgentPeakThreads",
            "viewerPeakThreads",
        ):
            if not is_integer(system.get(key)) or system[key] <= 0:
                failures.append(f"{label} {key} is invalid")
    if host:
        if (
            not is_integer(host.get("sourceRecordCount"))
            or not is_integer(host.get("coveredRecordCount"))
            or host.get("sourceRecordCount", 0) < host.get("coveredRecordCount", 0)
            or host.get("coveredRecordCount", 0) <= 0
        ):
            failures.append(f"{label} Host record coverage is invalid")
        if (
            not is_number(host.get("maximumCoveredGapSeconds"))
            or not 0 <= host["maximumCoveredGapSeconds"] <= 2.5
        ):
            failures.append(f"{label} Host state gap is invalid")
    if viewer:
        for key in ("processID", "encodedFrames", "decodedFrames", "presentedFrames"):
            if not is_integer(viewer.get(key)) or viewer[key] <= 0:
                failures.append(f"{label} Viewer {key} is invalid")
        if (
            not is_number(viewer.get("durationSeconds"))
            or viewer["durationSeconds"] < duration
        ):
            failures.append(f"{label} Viewer duration is incomplete")
        if (
            not is_number(viewer.get("maximumPresentationGapMilliseconds"))
            or not 0 <= viewer["maximumPresentationGapMilliseconds"] <= 2_500
        ):
            failures.append(f"{label} Viewer presentation gap is invalid")


def validate_run(
    run: dict[str, Any],
    name: str,
) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    label = f"pair run {name}"
    if set(run) != RUN_KEYS:
        failures.append(f"{label} keys do not match schema v1")
    if run.get("schema") != RUN_SCHEMA or run.get("schemaVersion") != 1:
        failures.append(f"{label} schema is invalid")
    scenario = RUN_SCENARIOS[name]
    if run.get("scenario") != scenario:
        failures.append(f"{label} scenario is invalid")
    if run.get("sampleMode") != "acceptance":
        failures.append(f"{label} is not acceptance evidence")
    duration = run.get("requestedDurationSeconds")
    if not is_integer(duration) or not 600 <= duration <= 1_800:
        failures.append(f"{label} duration is outside the acceptance bound")
        duration = 0
    if run.get("status") != "pass" or run.get("failures") != []:
        failures.append(f"{label} did not pass its source validator")
    scope = validate_scope(run.get("scope"), failures, label)
    validate_source_summaries(run.get("sources"), failures, label)
    if run.get("thresholds") != SCENARIO_THRESHOLDS[scenario]:
        failures.append(f"{label} thresholds do not match the item-10 contract")
    validate_metrics(run.get("metrics"), scenario, duration, failures, label)
    claims = run.get("claims")
    if not isinstance(claims, dict) or set(claims) != CLAIM_KEYS:
        failures.append(f"{label} claims do not match schema v1")
    else:
        for key in CLAIM_KEYS - {"section15_2Item10Complete"}:
            if claims.get(key) is not True:
                failures.append(f"{label} claim {key} is not proven")
        if claims.get("section15_2Item10Complete") is not False:
            failures.append(f"{label} made a premature item-10 completion claim")
    return {
        "scenario": scenario,
        "requestedDurationSeconds": duration,
        "scope": scope,
    }, failures


def validate(manifest_path: Path) -> dict[str, Any]:
    if not manifest_path.is_absolute() or has_symlink_component(manifest_path):
        raise PairValidationError("manifest path must be absolute and non-symlink")
    manifest_raw = read_bounded_regular(
        manifest_path, MAXIMUM_MANIFEST_BYTES, "pair manifest"
    )
    manifest = strict_json(manifest_raw, "pair manifest")
    validate_manifest(manifest)
    paths, raw_runs = resolve_run_sources(manifest_path, manifest)
    failures: list[str] = []
    normalized: dict[str, dict[str, Any]] = {}
    for name in RUN_NAMES:
        run = strict_json(raw_runs[name], f"pair run {name}")
        summary, run_failures = validate_run(run, name)
        summary.update({
            "path": manifest["runs"][name]["path"],
            "sha256": hash_bytes(raw_runs[name]),
            "byteCount": len(raw_runs[name]),
        })
        normalized[name] = summary
        failures.extend(run_failures)
    scopes = [normalized[name]["scope"] for name in RUN_NAMES]
    same_scope = bool(scopes[0]) and scopes[0] == scopes[1]
    if not same_scope:
        failures.append("pair runs do not share one machine/build/macOS scope")
    status = "pass" if not failures else "fail"
    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "section-15.2-item-10",
        "status": status,
        "failures": failures,
        "scope": scopes[0] if same_scope else {},
        "requirements": {
            "host-ready-viewer": (
                "pass" if not any("hostReadyViewer" in value for value in failures) else "fail"
            ),
            "host-viewer-dual": (
                "pass" if not any("hostViewerDual" in value for value in failures) else "fail"
            ),
        },
        "runs": normalized,
        "claims": {
            "bothAcceptanceScenariosComplete": status == "pass",
            "sameMachineBuildMacOSScope": status == "pass" and same_scope,
            "section15_2Item10Complete": status == "pass",
            "v1ConcurrencyRecoveryMatrixComplete": False,
        },
        "collectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def validate_output_path(output: Path, manifest: Path) -> None:
    if not output.is_absolute() or output.suffix.lower() != ".json":
        raise PairValidationError("output path must be an absolute JSON path")
    if output.exists() or output.is_symlink():
        raise PairValidationError("refusing to overwrite existing output")
    if output == manifest:
        raise PairValidationError("output path must differ from manifest")
    parent = output.parent
    if not parent.is_dir() or has_symlink_component(parent):
        raise PairValidationError("output parent must be existing and non-symlink")
    metadata = parent.stat()
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise PairValidationError("output parent ownership or permissions are unsafe")


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-combined-role-pair-", suffix=".tmp", dir=path.parent
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
        raise PairValidationError("failed to publish item-10 pair result") from error
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
    except PairValidationError as error:
        print(f"combined-role pair validation refused: {error}", file=sys.stderr)
        return 2
    print(
        f"status={result['status']} output={output_path} "
        f"section_15_2_item_10_complete="
        f"{str(result['claims']['section15_2Item10Complete']).lower()}"
    )
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
