#!/usr/bin/env python3
"""Validate one bounded FarPane Host-ready/no-screen-route idle window."""

from __future__ import annotations

import csv
import json
import math
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCENARIO = "host-ready-no-screen-route"
HOST_CPU_CEILING_PERCENT = 2.0
MAX_STATE_GAP_SECONDS = 2.5
MAX_SNAPSHOT_AGE_MILLISECONDS = 3_000
CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS = 1_500
SUPPORTED_MACHINE_ARCHITECTURES = ("arm64", "x86_64")
STATE_KEYS = {
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


def usage() -> None:
    print(
        "usage: validate-farpane-host-idle.py DURATION STATE_JSONL SYSTEM_JSON "
        "SYSTEM_CSV WINDOW_START_UNIX_MS WINDOW_END_UNIX_MS RUN_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_bounded_identity_text(value: Any, maximum_length: int) -> bool:
    return (
        isinstance(value, str)
        and value == value.strip()
        and 0 < len(value) <= maximum_length
        and all(
            ord(character) >= 0x20 and ord(character) != 0x7F
            for character in value
        )
    )


def parse_iso8601_milliseconds(value: Any) -> int:
    if not isinstance(value, str):
        raise ValueError("capturedAt is not a string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError("capturedAt has no timezone")
    return int(parsed.timestamp() * 1_000)


def load_json(path: Path, label: str, failures: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        failures.append(f"{label} is missing or invalid JSON")
        return {}
    if not isinstance(value, dict):
        failures.append(f"{label} root must be an object")
        return {}
    return value


def load_state_records(path: Path, failures: list[str]) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        failures.append("runtime-state evidence is missing or unreadable")
        return []
    if not lines:
        failures.append("runtime-state evidence contains no records")
        return []
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            failures.append(
                f"runtime-state record {line_number} is invalid JSON"
            )
            continue
        if not isinstance(value, dict):
            failures.append(
                f"runtime-state record {line_number} root must be an object"
            )
            continue
        records.append(value)
    return records


def parse_float(row: dict[str, str], field: str) -> float:
    return float(row[field])


def parse_int(row: dict[str, str], field: str) -> int:
    return int(row[field])


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-idle-", suffix=".tmp", dir=path.parent
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


def validate_idle_run(
    *,
    duration: int,
    state_path: Path,
    system_path: Path,
    samples_path: Path,
    window_start_unix_ms: int,
    window_end_unix_ms: int,
) -> dict[str, Any]:
    failures: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    require(duration > 0, "duration must be positive")
    window_duration_ms = window_end_unix_ms - window_start_unix_ms
    require(
        duration > 0
        and duration * 1_000 <= window_duration_ms <= (duration + 30) * 1_000,
        "runner wall-clock window does not match the requested duration",
    )

    system = load_json(system_path, "system evidence", failures)
    sample_mode = system.get("sampleMode") if system else None
    system_actual_duration = 0.0
    machine_model = "unavailable"
    machine_architecture = "unavailable"
    macos_version = "unavailable"
    if system:
        require(
            is_integer(system.get("schemaVersion"))
            and system["schemaVersion"] >= 3,
            "system evidence schemaVersion must be at least 3",
        )
        require(system.get("scenario") == SCENARIO, "system scenario does not match")
        require(
            sample_mode in ("acceptance", "smoke"),
            "system evidence sample mode is invalid",
        )
        require(
            sample_mode != "acceptance" or duration >= 600,
            "idle acceptance evidence is shorter than 600 seconds",
        )
        require(
            system.get("requestedDurationSeconds") == duration,
            "system evidence duration does not match",
        )
        require(
            system.get("sampleCount") == duration,
            "system sampler did not produce one sample per requested second",
        )
        require(
            system.get("completed") is True,
            "system sampler did not complete the requested window",
        )
        require(
            system.get("samplerExitStatus") == 0,
            "system sampler recorded a nonzero exit status",
        )
        actual_duration = system.get("actualDurationSeconds")
        if is_number(actual_duration):
            system_actual_duration = float(actual_duration)
        require(
            is_number(actual_duration) and float(actual_duration) >= duration - 0.25,
            "system sampler wall-clock duration did not cover the requested window",
        )
        candidate_machine_model = system.get("machineModel")
        candidate_architecture = system.get("architecture")
        candidate_macos_version = system.get("macOSVersion")
        machine_model_valid = is_bounded_identity_text(candidate_machine_model, 128)
        architecture_valid = candidate_architecture in SUPPORTED_MACHINE_ARCHITECTURES
        macos_version_valid = is_bounded_identity_text(candidate_macos_version, 64)
        require(
            machine_model_valid,
            "system evidence machine model is missing or invalid",
        )
        require(
            architecture_valid,
            "system evidence architecture must be arm64 or x86_64",
        )
        require(
            macos_version_valid,
            "system evidence macOS version is missing or invalid",
        )
        if machine_model_valid:
            machine_model = candidate_machine_model
        if architecture_valid:
            machine_architecture = candidate_architecture
        if macos_version_valid:
            macos_version = candidate_macos_version

    rows: list[dict[str, str]] = []
    try:
        with samples_path.open(newline="", encoding="utf-8") as samples_file:
            rows = list(csv.DictReader(samples_file))
    except (OSError, UnicodeError, csv.Error):
        failures.append("system samples are missing or invalid CSV")

    host_cpu_average = 0.0
    host_cpu_peak = 0.0
    window_server_cpu_average = 0.0
    media_services_cpu_average = 0.0
    host_assertion_peak = 0
    host_user_idle_assertion_peak = 0
    host_display_assertion_peak = 0
    if rows:
        try:
            require(
                len(rows) == duration,
                "system CSV row count does not match the requested duration",
            )
            require(
                all(row.get("scenario") == SCENARIO for row in rows),
                "system CSV contains another scenario",
            )
            elapsed = [parse_float(row, "elapsed_seconds") for row in rows]
            host_cpu = [parse_float(row, "host_cpu_percent") for row in rows]
            host_rss = [parse_int(row, "host_rss_kb") for row in rows]
            host_threads = [parse_int(row, "host_threads") for row in rows]
            window_cpu = [
                parse_float(row, "windowserver_cpu_percent") for row in rows
            ]
            media_cpu = [
                parse_float(row, "videotoolboxd_cpu_percent")
                + parse_float(row, "vt_encoder_xpc_cpu_percent")
                for row in rows
            ]
            assertions = [
                parse_int(row, "host_sleep_assertion_count") for row in rows
            ]
            user_idle_assertions = [
                parse_int(row, "host_user_idle_sleep_assertion_count")
                for row in rows
            ]
            display_assertions = [
                parse_int(row, "host_display_sleep_assertion_count")
                for row in rows
            ]
            series_valid = (
                all(math.isfinite(value) and value >= 0 for value in elapsed)
                and all(
                    later > earlier
                    for earlier, later in zip(elapsed, elapsed[1:])
                )
                and all(
                    math.isfinite(value) and value >= 0
                    for value in host_cpu + window_cpu + media_cpu
                )
                and all(value > 0 for value in host_rss)
                and all(value > 0 for value in host_threads)
                and all(value >= 0 for value in assertions)
                and all(value >= 0 for value in user_idle_assertions)
                and all(value >= 0 for value in display_assertions)
            )
            require(series_valid, "system samples contain malformed or invalid values")
            if not series_valid:
                raise ValueError("invalid system sample series")
            host_cpu_average = sum(host_cpu) / len(host_cpu)
            host_cpu_peak = max(host_cpu)
            window_server_cpu_average = sum(window_cpu) / len(window_cpu)
            media_services_cpu_average = sum(media_cpu) / len(media_cpu)
            host_assertion_peak = max(assertions)
            host_user_idle_assertion_peak = max(user_idle_assertions)
            host_display_assertion_peak = max(display_assertions)
            require(
                host_cpu_average < HOST_CPU_CEILING_PERCENT,
                "Host average CPU did not remain below 2 percent",
            )
            require(
                all(value == 0 for value in assertions),
                "Host held a sleep assertion during the no-screen-route window",
            )
            require(
                all(value == 0 for value in user_idle_assertions),
                "Host held a user-idle sleep assertion without a screen route",
            )
            require(
                all(value == 0 for value in display_assertions),
                "Host held a display-sleep assertion without a screen route",
            )
            require(
                all(
                    total >= user_idle + display
                    for total, user_idle, display in zip(
                        assertions, user_idle_assertions, display_assertions
                    )
                ),
                "Host sleep assertion totals are inconsistent with typed counts",
            )
        except (KeyError, TypeError, ValueError):
            failures.append("system samples contain malformed numeric fields")
    else:
        failures.append("system samples contain no data rows")

    records = load_state_records(state_path, failures)
    captured_ms: list[int] = []
    snapshot_ages_ms: list[int] = []
    sequences: list[int] = []
    monotonic_ns: list[int] = []
    valid_records: list[dict[str, Any]] = []
    for index, record in enumerate(records, start=1):
        keys_valid = set(record) == STATE_KEYS
        require(keys_valid, f"runtime-state record {index} keys do not match schema v2")
        schema_valid = (
            record.get("schema") == "farpane-host-runtime-state"
            and record.get("schemaVersion") == 2
        )
        require(schema_valid, f"runtime-state record {index} schema is invalid")
        sequence = record.get("sequence")
        monotonic = record.get("monotonicNanoseconds")
        snapshot_observed = record.get(
            "hostSnapshotObservedAtUnixMilliseconds"
        )
        authenticated_connection_count = record.get(
            "authenticatedConnectionCount"
        )
        types_valid = (
            is_integer(sequence)
            and sequence > 0
            and is_integer(monotonic)
            and monotonic > 0
            and is_integer(snapshot_observed)
            and snapshot_observed > 0
            and (
                authenticated_connection_count is None
                or (
                    is_integer(authenticated_connection_count)
                    and authenticated_connection_count >= 0
                )
            )
            and isinstance(record.get("hostRuntimeActive"), bool)
            and isinstance(record.get("hostState"), str)
            and isinstance(record.get("registrationStatus"), str)
            and isinstance(record.get("mediaRouteActive"), bool)
            and isinstance(record.get("mediaPipelineActive"), bool)
        )
        require(types_valid, f"runtime-state record {index} contains invalid types")
        try:
            captured = parse_iso8601_milliseconds(record.get("capturedAt"))
        except (TypeError, ValueError, OverflowError):
            require(False, f"runtime-state record {index} capturedAt is invalid")
            continue
        if not (keys_valid and schema_valid and types_valid):
            continue
        sequences.append(int(sequence))
        monotonic_ns.append(int(monotonic))
        captured_ms.append(captured)
        snapshot_ages_ms.append(captured - int(snapshot_observed))
        valid_records.append(record)

    maximum_state_gap_seconds = 0.0
    maximum_snapshot_age_ms = 0
    if valid_records:
        require(
            all(later == earlier + 1 for earlier, later in zip(sequences, sequences[1:])),
            "runtime-state sequence is not contiguous",
        )
        require(
            all(later > earlier for earlier, later in zip(monotonic_ns, monotonic_ns[1:])),
            "runtime-state monotonic timestamps are not strictly increasing",
        )
        require(
            all(later >= earlier for earlier, later in zip(captured_ms, captured_ms[1:])),
            "runtime-state wall-clock timestamps moved backwards",
        )
        state_gaps = [
            (later - earlier) / 1_000
            for earlier, later in zip(captured_ms, captured_ms[1:])
        ]
        maximum_state_gap_seconds = max(state_gaps, default=0.0)
        require(
            maximum_state_gap_seconds <= MAX_STATE_GAP_SECONDS,
            "runtime-state evidence contains a gap longer than 2.5 seconds",
        )
        require(
            captured_ms[0] <= window_start_unix_ms + 2_000,
            "runtime-state evidence did not cover the beginning of the window",
        )
        require(
            captured_ms[-1] >= window_end_unix_ms - 2_000,
            "runtime-state evidence did not cover the end of the window",
        )
        require(
            all(
                window_start_unix_ms - 1_500
                <= captured
                <= window_end_unix_ms + 1_500
                for captured in captured_ms
            ),
            "runtime-state slice contains records outside the runner window",
        )
        require(
            len(valid_records) >= max(1, duration - 2),
            "runtime-state evidence contains too few periodic records",
        )
        require(
            all(record["hostRuntimeActive"] is True for record in valid_records),
            "Host runtime was not active throughout the idle window",
        )
        require(
            all(record["hostState"] == "ready" for record in valid_records),
            "Host state was not ready throughout the idle window",
        )
        require(
            all(
                is_integer(record["authenticatedConnectionCount"])
                for record in valid_records
            ),
            "authenticated connection count was unavailable during the idle window",
        )
        require(
            all(
                record["authenticatedConnectionCount"] == 0
                for record in valid_records
            ),
            "an authenticated connection existed during the idle window",
        )
        require(
            all(
                record["registrationStatus"] == "ready"
                for record in valid_records
            ),
            "rendezvous registration was not ready throughout the idle window",
        )
        require(
            all(record["mediaRouteActive"] is False for record in valid_records),
            "a screen media route became active during the idle window",
        )
        require(
            all(
                record["mediaPipelineActive"] is False
                for record in valid_records
            ),
            "a screen capture pipeline became active during the idle window",
        )
        maximum_snapshot_age_ms = max(snapshot_ages_ms)
        require(
            all(
                -CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS
                <= age
                <= MAX_SNAPSHOT_AGE_MILLISECONDS
                for age in snapshot_ages_ms
            ),
            "Host snapshot timestamps were stale or implausibly in the future",
        )

    result = {
        "schema": "farpane-host-idle-run",
        "schemaVersion": 1,
        "scenario": SCENARIO,
        "sampleMode": sample_mode or "unknown",
        "requestedDurationSeconds": duration,
        "machineModel": machine_model,
        "architecture": machine_architecture,
        "macOSVersion": macos_version,
        "runnerWindowDurationSeconds": round(window_duration_ms / 1_000, 3),
        "systemActualDurationSeconds": round(system_actual_duration, 3),
        "hostCPUUpperTargetPercent": HOST_CPU_CEILING_PERCENT,
        "hostCPUAveragePercent": round(host_cpu_average, 3),
        "hostCPUPeakPercent": round(host_cpu_peak, 3),
        "windowServerCPUAveragePercent": round(window_server_cpu_average, 3),
        "mediaServicesCPUAveragePercent": round(media_services_cpu_average, 3),
        "hostSleepAssertionPeakCount": host_assertion_peak,
        "hostUserIdleSleepAssertionPeakCount": host_user_idle_assertion_peak,
        "hostDisplaySleepAssertionPeakCount": host_display_assertion_peak,
        "runtimeStateRecordCount": len(valid_records),
        "runtimeStateMaximumGapSeconds": round(maximum_state_gap_seconds, 3),
        "runtimeStateMaximumSnapshotAgeMilliseconds": maximum_snapshot_age_ms,
        "hostReadyThroughout": bool(valid_records)
        and all(record["hostState"] == "ready" for record in valid_records),
        "registrationReadyThroughout": bool(valid_records)
        and all(
            record["registrationStatus"] == "ready" for record in valid_records
        ),
        "screenMediaRouteAbsentThroughout": bool(valid_records)
        and all(
            record["mediaRouteActive"] is False
            and record["mediaPipelineActive"] is False
            for record in valid_records
        ),
        "authenticatedConnectionCoverage": "all-rustdesk-authenticated-types",
        "allAuthenticatedConnectionsProvenAbsent": bool(valid_records)
        and all(
            is_integer(record["authenticatedConnectionCount"])
            and record["authenticatedConnectionCount"] == 0
            for record in valid_records
        ),
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "collectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    return result


def main() -> int:
    if len(sys.argv) != 8:
        usage()
        return 2
    try:
        duration = int(sys.argv[1])
        window_start_unix_ms = int(sys.argv[5])
        window_end_unix_ms = int(sys.argv[6])
    except ValueError:
        print("duration and window timestamps must be integers", file=sys.stderr)
        return 2
    output_path = Path(sys.argv[7])
    if output_path.exists():
        print(
            f"refusing to overwrite existing artifact: {output_path}",
            file=sys.stderr,
        )
        return 2
    result = validate_idle_run(
        duration=duration,
        state_path=Path(sys.argv[2]),
        system_path=Path(sys.argv[3]),
        samples_path=Path(sys.argv[4]),
        window_start_unix_ms=window_start_unix_ms,
        window_end_unix_ms=window_end_unix_ms,
    )
    try:
        write_atomic_no_replace(output_path, result)
    except (OSError, FileExistsError) as error:
        print(f"failed to publish idle run evidence: {error}", file=sys.stderr)
        return 2
    print(
        f"result={result['status']} run_evidence={output_path} "
        f"host_cpu_average={result['hostCPUAveragePercent']:.3f} "
        f"state_records={result['runtimeStateRecordCount']}"
    )
    if result["failures"]:
        print("gate failures: " + "; ".join(result["failures"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
