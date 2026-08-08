#!/usr/bin/env python3
"""Validate and summarize one FarPane Host live media JSONL log."""

from __future__ import annotations

import json
import math
import os
import statistics
import sys
import tempfile
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA = "farpane-host-media-live"
SUPPORTED_SCHEMA_VERSIONS = {1, 2, 3}
MAXIMUM_PERIODIC_RECORDS = 3_600
LEGACY_EVENTS = {"routeStarted", "periodic", "routeStopped", "routeStartFailed"}
EVENTS_BY_SCHEMA = {
    1: LEGACY_EVENTS,
    2: LEGACY_EVENTS,
    3: LEGACY_EVENTS | {"captureSuspended"},
}
FINAL_EVENTS_BY_SCHEMA = {
    1: {"routeStopped", "routeStartFailed"},
    2: {"routeStopped", "routeStartFailed"},
    3: {"routeStopped", "routeStartFailed", "captureSuspended"},
}
CODECS = {"h264", "h265"}
CONTENT_STATES = {"idle", "lowMotion", "interactive", "highMotion"}
PRESSURE_LEVELS = {"none", "moderate", "severe"}
PRESSURE_CAUSES = {
    "thermalState",
    "lowPowerMode",
    "encodeInFlight",
    "encodeLatency",
    "consecutiveSendDrops",
    "recentSendDropRate",
    "encodedQueue",
    "networkDelay",
    "roundTripTime",
    "responseDelayed",
}
REQUIRED_KEYS = {
    "schema",
    "schemaVersion",
    "sequence",
    "capturedAt",
    "monotonicNanoseconds",
    "event",
    "recentWindowSeconds",
    "codec",
    "requestedFPS",
    "recentCaptureFPS",
    "recentEncodedFPS",
    "recentRustAdmissionFPS",
    "captureAverageFPS",
    "captureTargetFPS",
    "captureAppliedFPS",
    "captureContentState",
    "captureDirtyMetadataTrusted",
    "captureAppliedPressureLevel",
    "captureObservedPressureLevel",
    "capturePressureCauses",
    "captureConfigurationUpdateInFlight",
    "encodeInFlight",
    "recentSendOutcomeCount",
    "recentSendDropRate",
    "consecutiveSendDrops",
    "responseDelayedSubscribers",
    "runtimeSeconds",
}
OPTIONAL_KEYS = {
    "latestDirtyAreaRatio",
    "latestEncodeLatencyMS",
    "encodedQueueDepth",
    "encodedQueueCapacity",
    "networkDelayMS",
    "roundTripTimeMS",
    "processCPUPercent",
    "residentBytes",
    "physicalFootprintBytes",
    "thermalState",
    "powerSource",
    "lowPowerModeEnabled",
}
ALLOWED_KEYS = REQUIRED_KEYS | OPTIONAL_KEYS
V2_REQUIRED_KEYS = {
    "captureCallbackCount",
    "captureFrameStatusCounts",
    "captureCompleteDirtyRectsCounts",
}
FRAME_STATUS_COUNT_KEYS = {
    "complete",
    "idle",
    "blank",
    "suspended",
    "started",
    "stopped",
    "missingOrInvalid",
    "unknown",
}
DIRTY_RECTS_COUNT_KEYS = {
    "absent",
    "unrecognized",
    "recognizedEmpty",
    "recognizedNonEmpty",
}


def usage() -> None:
    print(
        "usage: analyze-farpane-host-media-live.py INPUT.jsonl [OUTPUT.json]",
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


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def reject_nonstandard_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def load_records(path: Path, failures: list[str]) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        failures.append("live log is missing or is not valid UTF-8")
        return []
    if not lines:
        failures.append("live log is empty")
        return []
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            failures.append(f"line {line_number} is empty")
            continue
        try:
            value = json.loads(line, parse_constant=reject_nonstandard_constant)
        except (json.JSONDecodeError, ValueError):
            failures.append(f"line {line_number} is invalid JSON")
            continue
        if not isinstance(value, dict):
            failures.append(f"line {line_number} root is not an object")
            continue
        records.append(value)
    return records


def validate_record(
    record: dict[str, Any],
    index: int,
    failures: list[str],
) -> None:
    label = f"record {index + 1}"
    schema_version = record.get("schemaVersion")
    has_capture_counts = is_integer(schema_version) and schema_version in {2, 3}
    required_keys = REQUIRED_KEYS | (V2_REQUIRED_KEYS if has_capture_counts else set())
    allowed_keys = ALLOWED_KEYS | (V2_REQUIRED_KEYS if has_capture_counts else set())
    missing = required_keys - record.keys()
    unknown = record.keys() - allowed_keys
    if missing:
        failures.append(f"{label} is missing fields: {','.join(sorted(missing))}")
    if unknown:
        failures.append(f"{label} has unknown fields: {','.join(sorted(unknown))}")
    if record.get("schema") != SCHEMA:
        failures.append(f"{label} has an unexpected schema")
    if not is_integer(schema_version) or schema_version not in SUPPORTED_SCHEMA_VERSIONS:
        failures.append(f"{label} has an unsupported schema version")
    if not is_integer(record.get("sequence")) or record.get("sequence", 0) <= 0:
        failures.append(f"{label} has an invalid sequence")
    if parse_timestamp(record.get("capturedAt")) is None:
        failures.append(f"{label} has an invalid capturedAt timestamp")
    if (
        not is_integer(record.get("monotonicNanoseconds"))
        or record.get("monotonicNanoseconds", -1) < 0
    ):
        failures.append(f"{label} has an invalid monotonic timestamp")
    allowed_events = set()
    if is_integer(schema_version):
        allowed_events = EVENTS_BY_SCHEMA.get(schema_version, set())
    if record.get("event") not in allowed_events:
        failures.append(f"{label} has an invalid lifecycle event")
    if record.get("recentWindowSeconds") != 5:
        failures.append(f"{label} has an unexpected recent window")
    if record.get("codec") not in CODECS:
        failures.append(f"{label} has an invalid codec")
    if record.get("captureContentState") not in CONTENT_STATES:
        failures.append(f"{label} has an invalid content state")
    for field in ("captureAppliedPressureLevel", "captureObservedPressureLevel"):
        if record.get(field) not in PRESSURE_LEVELS:
            failures.append(f"{label} has an invalid {field}")
    causes = record.get("capturePressureCauses")
    if not isinstance(causes, list) or any(cause not in PRESSURE_CAUSES for cause in causes):
        failures.append(f"{label} has invalid pressure causes")
    elif len(causes) != len(set(causes)):
        failures.append(f"{label} repeats a pressure cause")
    elif record.get("captureObservedPressureLevel") == "none" and causes:
        failures.append(f"{label} reports pressure causes while observed pressure is none")
    elif record.get("captureObservedPressureLevel") in {"moderate", "severe"} and not causes:
        failures.append(f"{label} omits causes for current observed pressure")

    positive_integer_fields = (
        "requestedFPS",
        "captureTargetFPS",
        "captureAppliedFPS",
    )
    nonnegative_integer_fields = (
        "encodeInFlight",
        "recentSendOutcomeCount",
        "consecutiveSendDrops",
        "responseDelayedSubscribers",
        "residentBytes",
        "physicalFootprintBytes",
    )
    nonnegative_number_fields = (
        "recentCaptureFPS",
        "recentEncodedFPS",
        "recentRustAdmissionFPS",
        "captureAverageFPS",
        "latestEncodeLatencyMS",
        "processCPUPercent",
        "runtimeSeconds",
    )
    for field in positive_integer_fields:
        if not is_integer(record.get(field)) or record.get(field, 0) <= 0:
            failures.append(f"{label} has an invalid {field}")
    for field in nonnegative_integer_fields:
        if field in record and (
            not is_integer(record[field]) or record[field] < 0
        ):
            failures.append(f"{label} has an invalid {field}")
    for field in nonnegative_number_fields:
        if field in record and (
            not is_number(record[field]) or record[field] < 0
        ):
            failures.append(f"{label} has an invalid {field}")
    if (
        not is_number(record.get("recentSendDropRate"))
        or not 0 <= record.get("recentSendDropRate", -1) <= 1
    ):
        failures.append(f"{label} has an invalid recentSendDropRate")
    if "latestDirtyAreaRatio" in record and (
        not is_number(record["latestDirtyAreaRatio"])
        or not 0 <= record["latestDirtyAreaRatio"] <= 1
    ):
        failures.append(f"{label} has an invalid latestDirtyAreaRatio")
    for field in ("captureDirtyMetadataTrusted", "captureConfigurationUpdateInFlight"):
        if not isinstance(record.get(field), bool):
            failures.append(f"{label} has an invalid {field}")
    if "lowPowerModeEnabled" in record and not isinstance(
        record["lowPowerModeEnabled"], bool
    ):
        failures.append(f"{label} has an invalid lowPowerModeEnabled")
    if "encodedQueueDepth" in record and "encodedQueueCapacity" in record:
        depth = record["encodedQueueDepth"]
        capacity = record["encodedQueueCapacity"]
        if (
            not is_integer(depth)
            or not is_integer(capacity)
            or depth < 0
            or capacity <= 0
            or depth > capacity
        ):
            failures.append(f"{label} has an invalid encoded queue sample")
    if has_capture_counts:
        validate_v2_capture_counts(record, label, failures)


def validate_count_map(
    value: Any,
    expected_keys: set[str],
    label: str,
    failures: list[str],
) -> bool:
    if not isinstance(value, dict):
        failures.append(f"{label} is not an object")
        return False
    missing = expected_keys - value.keys()
    unknown = value.keys() - expected_keys
    if missing:
        failures.append(f"{label} is missing fields: {','.join(sorted(missing))}")
    if unknown:
        failures.append(f"{label} has unknown fields: {','.join(sorted(unknown))}")
    if any(not is_integer(item) or item < 0 for item in value.values()):
        failures.append(f"{label} has an invalid count")
        return False
    return not missing and not unknown


def validate_v2_capture_counts(
    record: dict[str, Any],
    label: str,
    failures: list[str],
) -> None:
    callback_count = record.get("captureCallbackCount")
    callback_count_valid = is_integer(callback_count) and callback_count >= 0
    if not callback_count_valid:
        failures.append(f"{label} has an invalid captureCallbackCount")
    frame_counts = record.get("captureFrameStatusCounts")
    frame_counts_valid = validate_count_map(
        frame_counts,
        FRAME_STATUS_COUNT_KEYS,
        f"{label} captureFrameStatusCounts",
        failures,
    )
    dirty_counts = record.get("captureCompleteDirtyRectsCounts")
    dirty_counts_valid = validate_count_map(
        dirty_counts,
        DIRTY_RECTS_COUNT_KEYS,
        f"{label} captureCompleteDirtyRectsCounts",
        failures,
    )
    if (
        callback_count_valid
        and frame_counts_valid
        and sum(frame_counts.values()) != callback_count
    ):
        failures.append(f"{label} capture frame status counts do not sum to callbacks")
    if frame_counts_valid and dirty_counts_valid and (
        sum(dirty_counts.values()) != frame_counts["complete"]
    ):
        failures.append(f"{label} dirty rect counts do not sum to complete frames")


def distribution(records: list[dict[str, Any]], field: str) -> dict[str, int]:
    return dict(sorted(Counter(str(record[field]) for record in records).items()))


def numeric_summary(records: list[dict[str, Any]], field: str) -> dict[str, float]:
    values = [float(record[field]) for record in records]
    return {
        "minimum": round(min(values), 3),
        "median": round(float(statistics.median(values)), 3),
        "maximum": round(max(values), 3),
    }


def regime_key(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        record["captureTargetFPS"],
        record["captureAppliedFPS"],
        record["captureContentState"],
        record["captureAppliedPressureLevel"],
        record["captureObservedPressureLevel"],
        tuple(record["capturePressureCauses"]),
    )


def summarize_regime(
    records: list[dict[str, Any]], first_monotonic_ns: int
) -> dict[str, Any]:
    first = records[0]
    last = records[-1]
    return {
        "startOffsetSeconds": round(
            (first["monotonicNanoseconds"] - first_monotonic_ns) / 1_000_000_000,
            3,
        ),
        "durationSeconds": round(
            (last["monotonicNanoseconds"] - first["monotonicNanoseconds"])
            / 1_000_000_000,
            3,
        ),
        "sampleCount": len(records),
        "targetFPS": first["captureTargetFPS"],
        "appliedFPS": first["captureAppliedFPS"],
        "contentState": first["captureContentState"],
        "appliedPressure": first["captureAppliedPressureLevel"],
        "observedPressure": first["captureObservedPressureLevel"],
        "pressureCauses": first["capturePressureCauses"],
        "medianCaptureFPS": numeric_summary(records, "recentCaptureFPS")["median"],
        "medianEncodedFPS": numeric_summary(records, "recentEncodedFPS")["median"],
        "medianRustAdmissionFPS": numeric_summary(
            records, "recentRustAdmissionFPS"
        )["median"],
    }


def summarize(records: list[dict[str, Any]], failures: list[str]) -> dict[str, Any]:
    for index, record in enumerate(records):
        validate_record(record, index, failures)
    if records:
        sequences = [record.get("sequence") for record in records]
        if sequences != list(range(1, len(records) + 1)):
            failures.append("record sequence is not contiguous from one")
        monotonic = [record.get("monotonicNanoseconds") for record in records]
        if all(is_integer(value) for value in monotonic) and any(
            later < earlier for earlier, later in zip(monotonic, monotonic[1:])
        ):
            failures.append("monotonic timestamps move backwards")
        captured = [parse_timestamp(record.get("capturedAt")) for record in records]
        if all(value is not None for value in captured) and any(
            later < earlier
            for earlier, later in zip(captured, captured[1:])
            if earlier is not None and later is not None
        ):
            failures.append("capturedAt timestamps move backwards")
        events = [record.get("event") for record in records]
        route_schema_version = records[0].get("schemaVersion")
        final_events = set()
        if is_integer(route_schema_version):
            final_events = FINAL_EVENTS_BY_SCHEMA.get(route_schema_version, set())
        if events[0] != "routeStarted":
            failures.append("first record is not routeStarted")
        if events[-1] not in final_events:
            failures.append("last record is not a final lifecycle event")
        if events.count("routeStarted") != 1:
            failures.append("routeStarted must occur exactly once")
        if sum(event in final_events for event in events) != 1:
            failures.append("a final lifecycle event must occur exactly once")
        if any(event != "periodic" for event in events[1:-1]):
            failures.append("non-periodic lifecycle event appears inside the route")
        schema_versions = [record.get("schemaVersion") for record in records]
        if not all(is_integer(version) for version in schema_versions):
            failures.append("schema version is not an integer throughout the route")
        elif len(set(schema_versions)) != 1:
            failures.append("schema version changes inside the route")
        elif schema_versions[0] in {2, 3}:
            cumulative_fields = (
                "captureCallbackCount",
                "captureFrameStatusCounts",
                "captureCompleteDirtyRectsCounts",
            )
            for field in cumulative_fields:
                values = [record.get(field) for record in records]
                if field == "captureCallbackCount":
                    if all(is_integer(value) for value in values) and any(
                        later < earlier
                        for earlier, later in zip(values, values[1:])
                    ):
                        failures.append(f"{field} moves backwards")
                    continue
                expected_keys = (
                    FRAME_STATUS_COUNT_KEYS
                    if field == "captureFrameStatusCounts"
                    else DIRTY_RECTS_COUNT_KEYS
                )
                if all(
                    isinstance(value, dict)
                    and value.keys() == expected_keys
                    and all(is_integer(item) for item in value.values())
                    for value in values
                ):
                    for key in expected_keys:
                        if any(
                            later[key] < earlier[key]
                            for earlier, later in zip(values, values[1:])
                        ):
                            failures.append(f"{field}.{key} moves backwards")

    periodic = [record for record in records if record.get("event") == "periodic"]
    if len(periodic) > MAXIMUM_PERIODIC_RECORDS:
        failures.append("periodic sample count exceeds the per-route bound")
    if not periodic:
        failures.append("live log has no periodic samples")

    result: dict[str, Any] = {
        "schema": "farpane-host-media-live-analysis",
        "schemaVersion": 1,
        "validationStatus": "fail" if failures else "pass",
        "performanceVerdict": "diagnostic-only",
        "failures": failures,
        "recordCount": len(records),
        "periodicSampleCount": len(periodic),
    }
    if records:
        source_versions = [record.get("schemaVersion") for record in records]
        if all(is_integer(version) for version in source_versions) and len(
            set(source_versions)
        ) == 1:
            result["sourceSchemaVersion"] = source_versions[0]
    if failures or not periodic:
        return result

    first_ns = int(periodic[0]["monotonicNanoseconds"])
    last_ns = int(periodic[-1]["monotonicNanoseconds"])
    cause_counts = Counter(
        cause for record in periodic for cause in record["capturePressureCauses"]
    )
    cadence_counts = Counter(
        f"{record['captureTargetFPS']}/{record['captureAppliedFPS']}"
        for record in periodic
    )
    capture_encode_deltas = [
        abs(float(record["recentCaptureFPS"]) - float(record["recentEncodedFPS"]))
        for record in periodic
    ]
    encode_rust_deltas = [
        abs(
            float(record["recentEncodedFPS"])
            - float(record["recentRustAdmissionFPS"])
        )
        for record in periodic
    ]
    regimes: list[dict[str, Any]] = []
    start = 0
    for index in range(1, len(periodic) + 1):
        if index == len(periodic) or regime_key(periodic[index]) != regime_key(
            periodic[start]
        ):
            regimes.append(summarize_regime(periodic[start:index], first_ns))
            start = index

    result.update(
        {
            "durationSeconds": round((last_ns - first_ns) / 1_000_000_000, 3),
            "codec": periodic[0]["codec"],
            "requestedFPS": periodic[0]["requestedFPS"],
            "captureFPS": numeric_summary(periodic, "recentCaptureFPS"),
            "encodedFPS": numeric_summary(periodic, "recentEncodedFPS"),
            "rustAdmissionFPS": numeric_summary(
                periodic, "recentRustAdmissionFPS"
            ),
            "medianAbsoluteStageDeltaFPS": {
                "captureToEncode": round(
                    float(statistics.median(capture_encode_deltas)), 3
                ),
                "encodeToRustAdmission": round(
                    float(statistics.median(encode_rust_deltas)), 3
                ),
            },
            "cadenceSamples": dict(sorted(cadence_counts.items())),
            "contentStateSamples": distribution(periodic, "captureContentState"),
            "appliedPressureSamples": distribution(
                periodic, "captureAppliedPressureLevel"
            ),
            "observedPressureSamples": distribution(
                periodic, "captureObservedPressureLevel"
            ),
            "pressureCauseSamples": dict(sorted(cause_counts.items())),
            "dirtyMetadataTrustedSamples": sum(
                record["captureDirtyMetadataTrusted"] for record in periodic
            ),
            "configurationUpdateInFlightSamples": sum(
                record["captureConfigurationUpdateInFlight"] for record in periodic
            ),
            "regimes": regimes,
        }
    )
    if records[-1]["schemaVersion"] in {2, 3}:
        result.update(
            {
                "captureCallbackCount": records[-1]["captureCallbackCount"],
                "captureFrameStatusCounts": records[-1][
                    "captureFrameStatusCounts"
                ],
                "captureCompleteDirtyRectsCounts": records[-1][
                    "captureCompleteDirtyRectsCounts"
                ],
            }
        )
    return result


def analyze(path: Path) -> dict[str, Any]:
    failures: list[str] = []
    records = load_records(path, failures)
    return summarize(records, failures)


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-host-media-analysis-", suffix=".tmp", dir=path.parent
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
    if len(sys.argv) not in (2, 3):
        usage()
        return 2
    input_path = Path(sys.argv[1])
    result = analyze(input_path)
    if len(sys.argv) == 3:
        output_path = Path(sys.argv[2])
        try:
            write_atomic_no_replace(output_path, result)
        except FileExistsError:
            print(f"refusing to overwrite existing artifact: {output_path}", file=sys.stderr)
            return 2
    else:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0 if result["validationStatus"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
