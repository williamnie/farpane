#!/usr/bin/env python3
"""Validate one FarPane Host ready/active/disconnected assertion lifecycle."""

from __future__ import annotations

import csv
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_PHASES = ("ready-before", "active", "ready-after")
REQUIRED_COLUMNS = {
    "elapsed_seconds",
    "phase",
    "host_sleep_assertion_count",
    "host_user_idle_sleep_assertion_count",
    "host_display_sleep_assertion_count",
    "host_system_sleep_assertion_count",
}


def usage() -> None:
    print(
        "usage: validate-farpane-host-sleep-assertion-lifecycle.py "
        "PHASE_SECONDS LIFECYCLE_JSON SAMPLES_CSV ROUTE_JSON RUN_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def nested(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


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


def parse_nonnegative_int(row: dict[str, str], field: str) -> int:
    value = int(row[field])
    if value < 0:
        raise ValueError(field)
    return value


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-sleep-lifecycle-", suffix=".tmp", dir=path.parent
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


def main() -> int:
    if len(sys.argv) != 6:
        usage()
        return 2

    try:
        phase_seconds = int(sys.argv[1])
    except ValueError:
        print("PHASE_SECONDS must be a positive integer", file=sys.stderr)
        return 2
    if phase_seconds <= 0:
        print("PHASE_SECONDS must be a positive integer", file=sys.stderr)
        return 2

    lifecycle_path = Path(sys.argv[2])
    samples_path = Path(sys.argv[3])
    route_path = Path(sys.argv[4])
    output_path = Path(sys.argv[5])
    if output_path.exists():
        print(f"refusing to overwrite existing artifact: {output_path}", file=sys.stderr)
        return 2

    failures: list[str] = []
    lifecycle = load_json(lifecycle_path, "lifecycle evidence", failures)
    route = load_json(route_path, "route evidence", failures)

    def require(condition: bool, message: str) -> None:
        if not condition and message not in failures:
            failures.append(message)

    sample_mode = lifecycle.get("sampleMode") if lifecycle else None
    if lifecycle:
        require(
            lifecycle.get("schema") == "farpane-host-sleep-assertion-lifecycle",
            "unexpected lifecycle evidence schema",
        )
        require(lifecycle.get("schemaVersion") == 1, "lifecycle schemaVersion must be 1")
        require(sample_mode in ("acceptance", "smoke"), "lifecycle sample mode is invalid")
        require(
            lifecycle.get("phaseSeconds") == phase_seconds,
            "lifecycle phase duration does not match",
        )
        require(lifecycle.get("activeObserved") is True, "active Host assertion was not observed")
        require(
            lifecycle.get("readyAfterObserved") is True,
            "Host assertions did not return to zero after disconnect",
        )
        require(
            lifecycle.get("routeEvidenceObserved") is True,
            "production route evidence was not observed after disconnect",
        )

    rows: list[dict[str, str]] = []
    fieldnames: set[str] = set()
    try:
        with samples_path.open(newline="", encoding="utf-8") as samples_file:
            reader = csv.DictReader(samples_file)
            fieldnames = set(reader.fieldnames or [])
            rows = list(reader)
    except (OSError, UnicodeError, csv.Error):
        failures.append("lifecycle samples are missing or invalid CSV")

    phase_rows: dict[str, list[dict[str, int]]] = {
        phase: [] for phase in REQUIRED_PHASES
    }
    user_idle_minimum = 0
    user_idle_peak = 0
    display_peak = 0
    system_sleep_peak = 0
    if rows:
        require(
            REQUIRED_COLUMNS.issubset(fieldnames),
            "lifecycle samples are missing required columns",
        )
        parsed_rows: list[dict[str, int | str]] = []
        try:
            previous_elapsed = -1.0
            for row in rows:
                elapsed = float(row["elapsed_seconds"])
                if elapsed < previous_elapsed:
                    raise ValueError("elapsed_seconds")
                previous_elapsed = elapsed
                parsed = {
                    "phase": row["phase"],
                    "total": parse_nonnegative_int(row, "host_sleep_assertion_count"),
                    "user": parse_nonnegative_int(
                        row, "host_user_idle_sleep_assertion_count"
                    ),
                    "display": parse_nonnegative_int(
                        row, "host_display_sleep_assertion_count"
                    ),
                    "system": parse_nonnegative_int(
                        row, "host_system_sleep_assertion_count"
                    ),
                }
                parsed_rows.append(parsed)
                require(
                    parsed["total"]
                    >= parsed["user"] + parsed["display"] + parsed["system"],
                    "typed assertion counts exceed the Host total",
                )
                require(
                    parsed["display"] == 0,
                    "native Host held a display-sleep assertion",
                )
                require(
                    parsed["system"] == 0,
                    "native Host held an explicit system-sleep assertion",
                )
                if parsed["phase"] in phase_rows:
                    phase_rows[parsed["phase"]].append(parsed)  # type: ignore[arg-type]
        except (KeyError, TypeError, ValueError):
            failures.append("lifecycle samples contain malformed fields")
            parsed_rows = []

        if parsed_rows:
            for phase in REQUIRED_PHASES:
                require(
                    len(phase_rows[phase]) == phase_seconds,
                    f"{phase} phase does not contain one sample per requested second",
                )
            ready_before = phase_rows["ready-before"]
            active = phase_rows["active"]
            ready_after = phase_rows["ready-after"]
            require(
                all(row["user"] == 0 for row in ready_before),
                "Host-ready before connection held a user-idle assertion",
            )
            require(
                all(row["user"] >= 1 for row in active),
                "active remote screen phase lost the user-idle assertion",
            )
            require(
                all(row["user"] == 0 for row in ready_after),
                "Host-ready after disconnect leaked a user-idle assertion",
            )
            if active:
                user_idle_minimum = min(row["user"] for row in active)
                user_idle_peak = max(row["user"] for row in active)
            display_peak = max(row["display"] for row in parsed_rows)
            system_sleep_peak = max(row["system"] for row in parsed_rows)
    else:
        failures.append("lifecycle samples contain no data rows")

    route_runtime_seconds = 0.0
    if route:
        route_runtime = nested(route, "runtimeSeconds")
        route_runtime_seconds = float(route_runtime) if is_number(route_runtime) else 0.0
        require(nested(route, "schema") == "farpane-media-telemetry", "unexpected route evidence schema")
        require(
            is_integer(nested(route, "schemaVersion"))
            and nested(route, "schemaVersion") >= 7,
            "route evidence schemaVersion must be at least 7",
        )
        require(
            is_integer(nested(route, "capture.validFrames"))
            and nested(route, "capture.validFrames") > 0,
            "route evidence contains no captured frames",
        )
        require(
            is_integer(nested(route, "send.accepted"))
            and nested(route, "send.accepted") > 0,
            "route evidence contains no accepted encoded packets",
        )
        require(
            is_integer(nested(route, "writer.cycles"))
            and nested(route, "writer.cycles") > 0
            and nested(route, "writer.finalized") is True,
            "route writer evidence is missing or not finalized",
        )
        require(
            is_integer(nested(route, "transport.subscriberCount"))
            and nested(route, "transport.subscriberCount") > 0
            and nested(route, "transport.finalized") is True,
            "route transport evidence is missing or not finalized",
        )
        require(
            is_number(route_runtime) and route_runtime >= phase_seconds,
            "route runtime does not cover the active assertion phase",
        )

    result = {
        "schema": "farpane-host-sleep-assertion-lifecycle-run",
        "schemaVersion": 1,
        "sampleMode": sample_mode or "unknown",
        "phaseSeconds": phase_seconds,
        "readyBeforeSamples": len(phase_rows["ready-before"]),
        "activeSamples": len(phase_rows["active"]),
        "readyAfterSamples": len(phase_rows["ready-after"]),
        "activeUserIdleAssertionMinimumCount": user_idle_minimum,
        "activeUserIdleAssertionPeakCount": user_idle_peak,
        "displaySleepAssertionPeakCount": display_peak,
        "systemSleepAssertionPeakCount": system_sleep_peak,
        "routeRuntimeSeconds": route_runtime_seconds,
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "collectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        write_atomic_no_replace(output_path, result)
    except (OSError, FileExistsError) as error:
        print(f"failed to publish lifecycle run evidence: {error}", file=sys.stderr)
        return 2

    print(f"result={result['status']} run_evidence={output_path}")
    if failures:
        print("gate failures: " + "; ".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
