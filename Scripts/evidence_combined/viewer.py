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
    MAXIMUM_CLOCK_OFFSET_DRIFT_SECONDS,
    MAXIMUM_STATE_GAP_SECONDS,
    MAXIMUM_VIEWER_PRESENTATION_GAP_MILLISECONDS,
    VIEWER_REQUIRED_KEYS,
    VIEWER_SCHEMA,
    datetime_nanoseconds,
    parse_utc,
)


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
