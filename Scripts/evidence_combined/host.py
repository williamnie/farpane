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
    CAPTURED_AT_FUTURE_TOLERANCE_MILLISECONDS,
    HOST_STATE_KEYS,
    HOST_STATE_SCHEMA,
    MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS,
    MAXIMUM_SNAPSHOT_AGE_MILLISECONDS,
    MAXIMUM_STATE_GAP_SECONDS,
    MAXIMUM_STATE_RECORDS,
    SCENARIO_CONTRACTS,
    ValidationError,
    datetime_nanoseconds,
    parse_utc,
    strict_json,
)


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
