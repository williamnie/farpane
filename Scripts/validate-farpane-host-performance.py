#!/usr/bin/env python3
"""Validate and summarize one real FarPane Host performance scenario."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import statistics
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCENARIOS = {
    "static-1080p30": {
        "width": 1920,
        "height": 1080,
        "cpu_ceiling": 10.0,
        "profile": "connected-static",
    },
    "static-4k30": {
        "width": 3840,
        "height": 2160,
        "cpu_ceiling": 10.0,
        "profile": "connected-static",
    },
    "1080p30": {
        "width": 1920,
        "height": 1080,
        "cpu_ceiling": 25.0,
        "profile": "active",
    },
    "4k30-normal": {
        "width": 3840,
        "height": 2160,
        "cpu_ceiling": 40.0,
        "profile": "active",
    },
    "4k30-video": {
        "width": 3840,
        "height": 2160,
        "cpu_ceiling": 40.0,
        "profile": "active",
    },
    "stability-1080p30": {
        "width": 1920,
        "height": 1080,
        "cpu_ceiling": 25.0,
        "profile": "stability",
    },
    "stability-4k30": {
        "width": 3840,
        "height": 2160,
        "cpu_ceiling": 40.0,
        "profile": "stability",
    },
}

DROP_REASONS = (
    "captureSuperseded",
    "encoderBackpressure",
    "networkBackpressure",
    "reconfigure",
    "invalidFrame",
    "shutdown",
)
STABILITY_WINDOW_COUNT = 6
SUPPORTED_MACHINE_ARCHITECTURES = ("arm64", "x86_64")
MAX_RECOVERY_SOURCE_BYTES = 1_048_576
MAX_RECOVERY_RECORDS = 128
RECOVERY_KINDS = ("sleepWake", "networkPath", "displayReconfigure")


def usage() -> None:
    print(
        "usage: validate-farpane-host-performance.py "
        "SCENARIO DURATION ROUTE_JSON SYSTEM_JSON SYSTEM_CSV RUN_JSON "
        "[RECOVERY_JSONL RECOVERY_SEQUENCE]",
        file=sys.stderr,
    )


def nested(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


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


def is_lowercase_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def parse_utc_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def valid_recovery_correlation(kind: str, value: Any) -> bool:
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
        numeric = [
            value.get("previousDisplayRevision"),
            value.get("replacementDisplayRevision"),
            value.get("previousConnectionEpoch"),
            value.get("replacementConnectionEpoch"),
            value.get("previousCodecEpoch"),
            value.get("replacementCodecEpoch"),
        ]
        return (
            all(is_integer(item) and item > 0 for item in numeric)
            and numeric[1] == numeric[0] + 1
            and numeric[3] > numeric[2]
            and numeric[5] > numeric[4]
        )
    return False


def load_recovery_binding(
    path: Path, sequence: int, sample_started_at: datetime | None
) -> tuple[dict[str, Any] | None, str | None]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        return None, "recovery transition source must be an absolute regular non-symlink file"
    try:
        raw = path.read_bytes()
    except OSError:
        return None, "recovery transition source is missing or unreadable"
    if not raw or len(raw) > MAX_RECOVERY_SOURCE_BYTES:
        return None, "recovery transition source size is outside the accepted bound"
    lines = raw.splitlines()
    if not lines or len(lines) > MAX_RECOVERY_RECORDS:
        return None, "recovery transition record count is outside the accepted bound"
    selected: tuple[dict[str, Any], bytes] | None = None
    for line in lines:
        if not line or len(line) > 65_536:
            return None, "recovery transition source contains an invalid record"
        try:
            record = json.loads(line.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            return None, "recovery transition source contains invalid JSON"
        if not isinstance(record, dict):
            return None, "recovery transition record root must be an object"
        if record.get("sequence") == sequence:
            if selected is not None:
                return None, "recovery transition sequence is duplicated"
            selected = (record, line)
    if selected is None:
        return None, "recovery transition sequence is missing"

    record, raw_record = selected
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
    kind = record.get("kind")
    accepted_at = parse_utc_timestamp(record.get("acceptedAt"))
    completed_at = parse_utc_timestamp(record.get("completedAt"))
    accepted_monotonic = record.get("acceptedMonotonicNanoseconds")
    completed_monotonic = record.get("completedMonotonicNanoseconds")
    valid = (
        set(record) == expected_keys
        and record.get("schema") == "farpane-host-recovery-transition"
        and record.get("schemaVersion") == 1
        and record.get("sequence") == sequence
        and kind in RECOVERY_KINDS
        and record.get("status") == "completed"
        and accepted_at is not None
        and completed_at is not None
        and completed_at >= accepted_at
        and is_integer(accepted_monotonic)
        and accepted_monotonic > 0
        and is_integer(completed_monotonic)
        and completed_monotonic > accepted_monotonic
        and is_lowercase_sha256(record.get("hostInstanceScopeSHA256"))
        and is_lowercase_sha256(record.get("buildIdentitySHA256"))
        and valid_recovery_correlation(kind, record.get("correlation"))
    )
    if not valid:
        return None, "recovery transition record does not match schema v1"
    if sample_started_at is None or completed_at >= sample_started_at:
        return None, "recovery transition did not complete before performance sampling"
    return {
        "kind": kind,
        "sequence": sequence,
        "recordSHA256": hashlib.sha256(raw_record).hexdigest(),
        "completedAt": record["completedAt"],
        "hostInstanceScopeSHA256": record["hostInstanceScopeSHA256"],
        "buildIdentitySHA256": record["buildIdentitySHA256"],
    }, None


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


def parse_float(row: dict[str, str], field: str) -> float:
    return float(row[field])


def parse_int(row: dict[str, str], field: str) -> int:
    return int(row[field])


def window_medians(values: list[float], window_count: int) -> list[float]:
    if window_count <= 0 or len(values) < window_count:
        return []
    medians: list[float] = []
    for index in range(window_count):
        start = len(values) * index // window_count
        end = len(values) * (index + 1) // window_count
        medians.append(float(statistics.median(values[start:end])))
    return medians


def material_sustained_rise(
    medians: list[float], absolute_delta: float, relative_delta: float
) -> bool:
    if len(medians) < 2:
        return False
    threshold = max(absolute_delta, abs(medians[0]) * relative_delta)
    return (
        all(later >= earlier for earlier, later in zip(medians, medians[1:]))
        and medians[-1] - medians[0] > threshold
    )


def excessive_growth(
    medians: list[float], absolute_delta: float, relative_delta: float
) -> bool:
    if len(medians) < 2:
        return False
    threshold = max(absolute_delta, abs(medians[0]) * relative_delta)
    return medians[-1] - medians[0] > threshold


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-performance-", suffix=".tmp", dir=path.parent
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
    if len(sys.argv) not in (7, 9):
        usage()
        return 2

    scenario = sys.argv[1]
    if scenario not in SCENARIOS:
        print(f"unknown scenario: {scenario}", file=sys.stderr)
        return 2
    try:
        duration = int(sys.argv[2])
    except ValueError:
        print("duration must be a positive integer", file=sys.stderr)
        return 2
    if duration <= 0:
        print("duration must be a positive integer", file=sys.stderr)
        return 2

    route_path = Path(sys.argv[3])
    system_path = Path(sys.argv[4])
    samples_path = Path(sys.argv[5])
    output_path = Path(sys.argv[6])
    recovery_source_path: Path | None = None
    recovery_sequence: int | None = None
    if len(sys.argv) == 9:
        recovery_source_path = Path(sys.argv[7])
        try:
            recovery_sequence = int(sys.argv[8])
        except ValueError:
            print("recovery sequence must be a positive integer", file=sys.stderr)
            return 2
        if recovery_sequence <= 0:
            print("recovery sequence must be a positive integer", file=sys.stderr)
            return 2
    if output_path.exists():
        print(f"refusing to overwrite existing artifact: {output_path}", file=sys.stderr)
        return 2

    scenario_contract = SCENARIOS[scenario]
    expected_width = int(scenario_contract["width"])
    expected_height = int(scenario_contract["height"])
    cpu_ceiling = float(scenario_contract["cpu_ceiling"])
    performance_profile = str(scenario_contract["profile"])
    failures: list[str] = []
    route = load_json(route_path, "route evidence", failures)
    system = load_json(system_path, "system evidence", failures)

    def require(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    if route:
        schema_version = nested(route, "schemaVersion")
        requested_fps = nested(route, "media.requestedFramesPerSecond")
        valid_frames = nested(route, "capture.validFrames")
        logical_copies = nested(route, "capture.maximumLogicalRawFrameCopyCount")
        maximum_raw_depth = nested(route, "capture.maximumRawFrameQueueDepth")
        encoded_packets = nested(route, "encode.packets")
        send_accepted = nested(route, "send.accepted")
        encoded_queue_samples = nested(route, "send.encodedQueueSamples")
        encoded_queue_depth = nested(route, "send.encodedQueueDepth")
        maximum_encoded_queue_depth = nested(route, "send.maximumEncodedQueueDepth")
        encoded_queue_capacity = nested(route, "send.encodedQueueCapacity")
        writer_metric_samples = nested(route, "writer.metricSamples")
        writer_cycles = nested(route, "writer.cycles")
        subscriber_dispatches = nested(route, "writer.subscriberDispatches")
        dispatch_wall_total = nested(route, "writer.dispatchWallTotalMicroseconds")
        maximum_dispatch_wall = nested(route, "writer.maximumDispatchWallMicroseconds")
        confirmation_wait_total = nested(route, "writer.confirmationWaitTotalMicroseconds")
        maximum_confirmation_wait = nested(route, "writer.maximumConfirmationWaitMicroseconds")
        completed_confirmations = nested(route, "writer.completedConfirmations")
        timed_out_confirmations = nested(route, "writer.timedOutConfirmations")
        network_metric_samples = nested(route, "network.metricSamples")
        network_subscribers = nested(route, "network.subscriberCount")
        qos_subscribers = nested(route, "network.qosSubscriberCount")
        delay_sampled_subscribers = nested(route, "network.delaySampledSubscribers")
        rtt_sampled_subscribers = nested(route, "network.rttSampledSubscribers")
        response_delayed_subscribers = nested(route, "network.responseDelayedSubscribers")
        latest_network_delay = nested(route, "network.latestNetworkDelayMilliseconds")
        maximum_network_delay = nested(route, "network.maximumNetworkDelayMilliseconds")
        latest_rtt = nested(route, "network.latestRoundTripTimeMilliseconds")
        maximum_rtt = nested(route, "network.maximumRoundTripTimeMilliseconds")
        transport_metric_samples = nested(route, "transport.metricSamples")
        transport_subscribers = nested(route, "transport.subscriberCount")
        direct_subscribers = nested(route, "transport.directSubscribers")
        relay_subscribers = nested(route, "transport.relaySubscribers")
        unknown_subscribers = nested(route, "transport.unknownSubscribers")
        classified_drops = nested(route, "drops.classified")
        unclassified_drops = nested(route, "drops.unclassified")
        total_drops = nested(route, "drops.total")
        runtime_seconds = nested(route, "runtimeSeconds")
        actual_fps = nested(route, "capture.actualFramesPerSecond")
        cadence_content_state = nested(route, "cadence.contentState")
        cadence_target_fps = nested(route, "cadence.targetFramesPerSecond")
        cadence_applied_fps = nested(route, "cadence.appliedFramesPerSecond")
        cadence_dirty_trusted = nested(route, "cadence.dirtyMetadataTrusted")
        cadence_updates_applied = nested(route, "cadence.configurationUpdatesApplied")
        cadence_update_failures = nested(route, "cadence.configurationUpdateFailures")
        cadence_update_cancellations = nested(route, "cadence.configurationUpdateCancellations")
        cadence_update_in_flight = nested(route, "cadence.configurationUpdateInFlight")
        process_samples = nested(route, "process.samples")

        require(nested(route, "schema") == "farpane-media-telemetry", "unexpected route evidence schema")
        require(is_integer(schema_version) and schema_version >= 7, "route evidence schemaVersion must be at least 7")
        require(nested(route, "media.requestedWidth") == expected_width, "requested width does not match the scenario")
        require(nested(route, "media.requestedHeight") == expected_height, "requested height does not match the scenario")
        require(nested(route, "media.captureWidth") == expected_width, "capture width does not match the scenario")
        require(nested(route, "media.captureHeight") == expected_height, "capture height does not match the scenario")
        require(is_integer(requested_fps) and requested_fps >= 30, "requested FPS is below 30")
        require(nested(route, "media.hardwareAccelerated") is True, "hardware encoder was not confirmed")
        require(nested(route, "media.softwareFallback") is False, "software encoder fallback was active")
        require(is_integer(valid_frames) and valid_frames > 0, "no valid captured frames were recorded")
        require(is_integer(encoded_packets) and encoded_packets > 0, "no encoded packets were recorded")
        require(is_integer(send_accepted) and send_accepted > 0, "no encoded packets reached the Rust writer queue")
        require(nested(route, "send.dropped") == 0, "the Rust writer queue dropped encoded packets")
        require(is_integer(encoded_queue_samples) and encoded_queue_samples > 1, "Rust encoded queue was not sampled during the route")
        require(encoded_queue_capacity == 3, "Rust encoded queue capacity does not match the production bound")
        require(
            is_integer(encoded_queue_depth)
            and is_integer(maximum_encoded_queue_depth)
            and is_integer(encoded_queue_capacity)
            and 0 <= encoded_queue_depth <= maximum_encoded_queue_depth <= encoded_queue_capacity,
            "Rust encoded queue depth is missing or outside its capacity",
        )
        require(nested(route, "send.encodedQueueFinalized") is True, "Rust encoded queue final route sample is missing")
        require(is_integer(writer_metric_samples) and writer_metric_samples > 1, "Rust writer timing was not sampled during the route")
        require(is_integer(writer_cycles) and writer_cycles > 0, "Rust writer timing contains no subscriber cycles")
        require(
            is_integer(subscriber_dispatches) and subscriber_dispatches >= writer_cycles,
            "Rust writer subscriber dispatch count is inconsistent",
        )
        require(
            is_integer(completed_confirmations)
            and is_integer(timed_out_confirmations)
            and completed_confirmations + timed_out_confirmations == writer_cycles,
            "Rust writer confirmation totals are inconsistent",
        )
        require(
            is_integer(dispatch_wall_total)
            and is_integer(maximum_dispatch_wall)
            and 0 <= maximum_dispatch_wall <= dispatch_wall_total,
            "Rust subscriber dispatch wall timing is inconsistent",
        )
        require(
            is_integer(confirmation_wait_total)
            and is_integer(maximum_confirmation_wait)
            and 0 <= maximum_confirmation_wait <= confirmation_wait_total,
            "Rust frame-controller wait timing is inconsistent",
        )
        require(nested(route, "writer.finalized") is True, "Rust writer final route sample is missing")
        require(is_integer(network_metric_samples) and network_metric_samples > 1, "Rust route network metrics were not sampled during the route")
        require(
            is_integer(network_subscribers)
            and is_integer(qos_subscribers)
            and 0 < qos_subscribers <= network_subscribers,
            "Rust route subscriber/QoS counts are missing or inconsistent",
        )
        require(
            is_integer(delay_sampled_subscribers)
            and is_integer(rtt_sampled_subscribers)
            and 0 < rtt_sampled_subscribers <= delay_sampled_subscribers <= qos_subscribers,
            "Rust route delay/RTT sample counts are missing or inconsistent",
        )
        require(
            is_integer(response_delayed_subscribers)
            and 0 <= response_delayed_subscribers <= qos_subscribers,
            "Rust route response-delayed count is inconsistent",
        )
        require(
            is_integer(latest_network_delay)
            and is_integer(maximum_network_delay)
            and 0 <= latest_network_delay <= maximum_network_delay,
            "Rust route network-delay estimates are missing or inconsistent",
        )
        require(
            is_integer(latest_rtt)
            and is_integer(maximum_rtt)
            and 0 <= latest_rtt <= maximum_rtt,
            "Rust route RTT estimates are missing or inconsistent",
        )
        require(nested(route, "network.finalized") is True, "Rust route network final sample is missing")
        require(
            is_integer(transport_metric_samples) and transport_metric_samples > 1,
            "Rust route transport was not sampled during the route",
        )
        require(
            is_integer(transport_subscribers)
            and is_integer(direct_subscribers)
            and is_integer(relay_subscribers)
            and is_integer(unknown_subscribers)
            and transport_subscribers > 0
            and direct_subscribers >= 0
            and relay_subscribers >= 0
            and unknown_subscribers >= 0
            and direct_subscribers + relay_subscribers + unknown_subscribers
            == transport_subscribers,
            "Rust route transport counts are missing or inconsistent",
        )
        require(
            unknown_subscribers == 0,
            "Rust route transport contains subscribers without authoritative classification",
        )
        require(nested(route, "transport.finalized") is True, "Rust route transport final sample is missing")
        require(unclassified_drops == 0, "unclassified drops were recorded")
        require(
            is_integer(classified_drops)
            and is_integer(unclassified_drops)
            and is_integer(total_drops)
            and classified_drops + unclassified_drops == total_drops,
            "drop ledger totals are inconsistent",
        )
        require(is_integer(logical_copies) and logical_copies <= 1, "raw-frame logical copy count exceeded one")
        require(nested(route, "capture.rawFrameQueueDepth") == 0, "raw-frame queue was not drained at route stop")
        require(is_integer(maximum_raw_depth) and maximum_raw_depth <= 2, "raw-frame queue exceeded capacity two")
        require(nested(route, "encode.inFlight") == 0, "encoder in-flight frames were not drained at route stop")
        require(is_number(runtime_seconds) and runtime_seconds >= duration, "route runtime did not cover the complete sampling window")
        if performance_profile == "connected-static":
            require(
                cadence_content_state == "idle",
                "static route did not finish in the idle cadence state",
            )
            require(
                cadence_dirty_trusted is True,
                "static route cadence was not based on trusted dirty metadata",
            )
            require(
                cadence_target_fps == 3 and cadence_applied_fps == 3,
                "static route did not converge to the 3 FPS idle cadence",
            )
            require(
                is_number(actual_fps) and 0 < actual_fps <= 5,
                "static route average capture FPS did not converge to the 1-5 FPS idle target",
            )
            require(
                is_integer(cadence_updates_applied) and cadence_updates_applied > 0,
                "static route contains no applied cadence update",
            )
            require(
                is_integer(cadence_update_failures) and cadence_update_failures == 0,
                "static route recorded a cadence configuration failure",
            )
            require(
                is_integer(cadence_update_cancellations)
                and cadence_update_cancellations == 0,
                "static route recorded a cadence configuration cancellation",
            )
            require(
                cadence_update_in_flight is False,
                "static route stopped with a cadence configuration update in flight",
            )
        if performance_profile == "stability":
            drop_counts: list[int] = []
            for reason in DROP_REASONS:
                metric = nested(route, f"drops.{reason}")
                count = metric.get("count") if isinstance(metric, dict) else None
                require(
                    isinstance(metric, dict)
                    and metric.get("instrumented") is True
                    and is_integer(count)
                    and count >= 0,
                    f"stability route drop reason {reason} is not fully instrumented",
                )
                if is_integer(count) and count >= 0:
                    drop_counts.append(count)
            require(
                len(drop_counts) == len(DROP_REASONS)
                and is_integer(classified_drops)
                and sum(drop_counts) == classified_drops,
                "stability route classified drop total does not match its six reasons",
            )
            require(
                encoded_queue_depth == 0,
                "stability route encoded queue was not drained at route stop",
            )
            require(
                timed_out_confirmations == 0,
                "stability route recorded writer confirmation timeouts",
            )
            require(
                response_delayed_subscribers == 0,
                "stability route ended with response-delayed subscribers",
            )
            require(
                is_integer(cadence_update_failures) and cadence_update_failures == 0,
                "stability route recorded a cadence configuration failure",
            )
            require(
                is_integer(cadence_update_cancellations)
                and cadence_update_cancellations == 0,
                "stability route recorded a cadence configuration cancellation",
            )
            require(
                cadence_update_in_flight is False,
                "stability route stopped with a cadence configuration update in flight",
            )
            require(
                is_integer(process_samples) and process_samples > 1,
                "stability route process metrics were not sampled during the route",
            )

    sample_mode = system.get("sampleMode") if system else None
    machine_model = "unavailable"
    machine_architecture = "unavailable"
    macos_version = "unavailable"
    sample_started_at_text = "unavailable"
    sample_completed_at_text = "unavailable"
    sample_started_at: datetime | None = None
    if system:
        system_schema_version = system.get("schemaVersion")
        require(
            is_integer(system_schema_version) and system_schema_version >= 2,
            "system evidence schemaVersion must be at least 2",
        )
        if is_integer(system_schema_version) and system_schema_version >= 3:
            require(
                system.get("completed") is True,
                "system sampler did not complete the requested window",
            )
            require(
                system.get("samplerExitStatus") == 0,
                "system sampler recorded a nonzero exit status",
            )
        if is_integer(system_schema_version) and system_schema_version >= 4:
            sample_started_at = parse_utc_timestamp(system.get("sampleStartedAt"))
            sample_completed_at = parse_utc_timestamp(system.get("collectedAt"))
            require(
                sample_started_at is not None,
                "system evidence sampling start timestamp is missing or invalid",
            )
            require(
                sample_completed_at is not None,
                "system evidence sampling completion timestamp is missing or invalid",
            )
            require(
                sample_started_at is not None
                and sample_completed_at is not None
                and sample_completed_at > sample_started_at,
                "system evidence sampling timestamps are out of order",
            )
            if sample_started_at is not None:
                sample_started_at_text = system["sampleStartedAt"]
            if sample_completed_at is not None:
                sample_completed_at_text = system["collectedAt"]
        require(system.get("scenario") == scenario, "system evidence scenario does not match")
        require(sample_mode in ("acceptance", "smoke"), "system evidence sample mode is invalid")
        minimum_duration = 1800 if performance_profile == "stability" else 600
        require(
            sample_mode != "acceptance" or duration >= minimum_duration,
            f"{performance_profile} acceptance evidence is shorter than {minimum_duration} seconds",
        )
        require(system.get("requestedDurationSeconds") == duration, "system evidence duration does not match")
        require(system.get("sampleCount") == duration, "system sampler did not produce one sample per requested second")
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
    window_cpu_average = 0.0
    media_cpu_average = 0.0
    host_rss_first_kb = 0
    host_rss_last_kb = 0
    stability_cpu_window_medians: list[float] = []
    stability_rss_window_medians_kb: list[float] = []
    stability_thread_window_medians: list[float] = []
    stability_cpu_sustained_rise = False
    stability_rss_sustained_rise = False
    stability_thread_sustained_rise = False
    stability_rss_excessive_growth = False
    stability_thread_excessive_growth = False
    host_user_idle_assertion_minimum = 0
    host_user_idle_assertion_peak = 0
    host_display_assertion_peak = 0
    if rows:
        try:
            require(len(rows) == duration, "system CSV row count does not match the requested duration")
            require(all(row.get("scenario") == scenario for row in rows), "system CSV contains another scenario")
            elapsed_seconds = [parse_float(row, "elapsed_seconds") for row in rows]
            host_cpu = [parse_float(row, "host_cpu_percent") for row in rows]
            host_rss = [parse_int(row, "host_rss_kb") for row in rows]
            host_threads = [parse_int(row, "host_threads") for row in rows]
            window_cpu = [parse_float(row, "windowserver_cpu_percent") for row in rows]
            media_cpu = [
                parse_float(row, "videotoolboxd_cpu_percent")
                + parse_float(row, "vt_encoder_xpc_cpu_percent")
                for row in rows
            ]
            elapsed_valid = all(
                math.isfinite(value) and value >= 0 for value in elapsed_seconds
            ) and all(
                later > earlier
                for earlier, later in zip(elapsed_seconds, elapsed_seconds[1:])
            )
            cpu_values_valid = all(
                math.isfinite(value) and value >= 0
                for value in host_cpu + window_cpu + media_cpu
            )
            rss_values_valid = all(value > 0 for value in host_rss)
            thread_values_valid = all(value > 0 for value in host_threads)
            require(
                elapsed_valid,
                "system sample elapsed times are non-finite, negative, or not strictly increasing",
            )
            require(
                cpu_values_valid,
                "system samples contain non-finite or negative CPU values",
            )
            require(
                rss_values_valid,
                "system samples contain invalid Host RSS values",
            )
            require(
                thread_values_valid,
                "system samples contain invalid Host thread counts",
            )
            if not (elapsed_valid and cpu_values_valid and rss_values_valid and thread_values_valid):
                raise ValueError("invalid system sample series")
            host_cpu_average = sum(host_cpu) / len(host_cpu)
            host_cpu_peak = max(host_cpu)
            window_cpu_average = sum(window_cpu) / len(window_cpu)
            media_cpu_average = sum(media_cpu) / len(media_cpu)
            host_rss_first_kb = host_rss[0]
            host_rss_last_kb = host_rss[-1]
            host_assertions = [parse_int(row, "host_sleep_assertion_count") for row in rows]
            host_user_idle_assertions = [
                parse_int(row, "host_user_idle_sleep_assertion_count") for row in rows
            ]
            host_display_assertions = [
                parse_int(row, "host_display_sleep_assertion_count") for row in rows
            ]
            host_user_idle_assertion_minimum = min(host_user_idle_assertions)
            host_user_idle_assertion_peak = max(host_user_idle_assertions)
            host_display_assertion_peak = max(host_display_assertions)
            require(host_cpu_average < cpu_ceiling, "Host average CPU exceeded the scenario upper target")
            require(
                all(count >= 1 for count in host_user_idle_assertions),
                "Host user-idle sleep assertion was missing during the active route",
            )
            require(
                all(count == 0 for count in host_display_assertions),
                "native Host held a display-sleep assertion during the active route",
            )
            require(
                all(
                    total >= user_idle + display
                    for total, user_idle, display in zip(
                        host_assertions,
                        host_user_idle_assertions,
                        host_display_assertions,
                    )
                ),
                "Host sleep assertion totals are inconsistent with typed counts",
            )
            if performance_profile == "stability":
                require(
                    len(rows) >= STABILITY_WINDOW_COUNT,
                    "stability system evidence needs at least six samples",
                )
                stability_cpu_window_medians = window_medians(
                    host_cpu, STABILITY_WINDOW_COUNT
                )
                stability_rss_window_medians_kb = window_medians(
                    [float(value) for value in host_rss], STABILITY_WINDOW_COUNT
                )
                stability_thread_window_medians = window_medians(
                    [float(value) for value in host_threads], STABILITY_WINDOW_COUNT
                )
                stability_cpu_sustained_rise = material_sustained_rise(
                    stability_cpu_window_medians, 2.0, 0.20
                )
                stability_rss_sustained_rise = material_sustained_rise(
                    stability_rss_window_medians_kb, 4096.0, 0.05
                )
                stability_thread_sustained_rise = material_sustained_rise(
                    stability_thread_window_medians, 2.0, 0.10
                )
                stability_rss_excessive_growth = excessive_growth(
                    stability_rss_window_medians_kb, 32768.0, 0.20
                )
                stability_thread_excessive_growth = excessive_growth(
                    stability_thread_window_medians, 4.0, 0.25
                )
                require(
                    not stability_cpu_sustained_rise,
                    "Host CPU has a material sustained rise across all six stability windows",
                )
                require(
                    not stability_rss_sustained_rise,
                    "Host RSS has a material sustained rise across all six stability windows",
                )
                require(
                    not stability_thread_sustained_rise,
                    "Host thread count has a material sustained rise across all six stability windows",
                )
                require(
                    not stability_rss_excessive_growth,
                    "Host RSS last-window growth exceeded the stability allowance",
                )
                require(
                    not stability_thread_excessive_growth,
                    "Host thread-count last-window growth exceeded the stability allowance",
                )
        except (KeyError, TypeError, ValueError):
            failures.append("system samples contain malformed numeric fields")
    else:
        failures.append("system samples contain no data rows")

    recovery_binding: dict[str, Any] | None = None
    if recovery_source_path is not None and recovery_sequence is not None:
        require(scenario == "1080p30", "recovery evidence requires scenario 1080p30")
        require(
            sample_mode == "acceptance" and duration >= 600,
            "recovery evidence requires a 600-second acceptance run",
        )
        require(
            is_integer(system.get("schemaVersion"))
            and system["schemaVersion"] >= 4,
            "recovery evidence requires system schemaVersion 4",
        )
        recovery_binding, recovery_failure = load_recovery_binding(
            recovery_source_path,
            recovery_sequence,
            sample_started_at,
        )
        if recovery_failure is not None:
            failures.append(recovery_failure)

    result = {
        "schema": "farpane-host-performance-run",
        "schemaVersion": 5 if recovery_source_path is not None else 4,
        "scenario": scenario,
        "performanceProfile": performance_profile,
        "sampleMode": sample_mode or "unknown",
        "requestedDurationSeconds": duration,
        "machineModel": machine_model,
        "architecture": machine_architecture,
        "macOSVersion": macos_version,
        "sampleStartedAt": sample_started_at_text,
        "sampleCompletedAt": sample_completed_at_text,
        "expectedWidth": expected_width,
        "expectedHeight": expected_height,
        "hostCPUUpperTargetPercent": cpu_ceiling,
        "hostCPUAveragePercent": round(host_cpu_average, 3),
        "hostCPUPeakPercent": round(host_cpu_peak, 3),
        "windowServerCPUAveragePercent": round(window_cpu_average, 3),
        "mediaServicesCPUAveragePercent": round(media_cpu_average, 3),
        "hostRSSFirstKB": host_rss_first_kb,
        "hostRSSLastKB": host_rss_last_kb,
        "hostUserIdleSleepAssertionMinimumCount": host_user_idle_assertion_minimum,
        "hostUserIdleSleepAssertionPeakCount": host_user_idle_assertion_peak,
        "hostDisplaySleepAssertionPeakCount": host_display_assertion_peak,
        "captureActualFramesPerSecond": nested(route, "capture.actualFramesPerSecond"),
        "cadenceContentState": nested(route, "cadence.contentState"),
        "cadenceTargetFramesPerSecond": nested(route, "cadence.targetFramesPerSecond"),
        "cadenceAppliedFramesPerSecond": nested(route, "cadence.appliedFramesPerSecond"),
        "cadenceDirtyMetadataTrusted": nested(route, "cadence.dirtyMetadataTrusted"),
        "cadenceConfigurationUpdateFailures": nested(route, "cadence.configurationUpdateFailures"),
        "cadenceConfigurationUpdateCancellations": nested(route, "cadence.configurationUpdateCancellations"),
        "cadenceConfigurationUpdateInFlight": nested(route, "cadence.configurationUpdateInFlight"),
        "stabilityWindowCount": len(stability_cpu_window_medians),
        "stabilityHostCPUWindowMediansPercent": [
            round(value, 3) for value in stability_cpu_window_medians
        ],
        "stabilityHostRSSWindowMediansKB": [
            round(value, 3) for value in stability_rss_window_medians_kb
        ],
        "stabilityHostThreadWindowMedians": [
            round(value, 3) for value in stability_thread_window_medians
        ],
        "stabilityHostCPUSustainedRise": stability_cpu_sustained_rise,
        "stabilityHostRSSSustainedRise": stability_rss_sustained_rise,
        "stabilityHostThreadSustainedRise": stability_thread_sustained_rise,
        "stabilityHostRSSExcessiveGrowth": stability_rss_excessive_growth,
        "stabilityHostThreadExcessiveGrowth": stability_thread_excessive_growth,
        "stabilityDropCounts": {
            reason: nested(route, f"drops.{reason}.count") for reason in DROP_REASONS
        } if performance_profile == "stability" else {},
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "collectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if recovery_source_path is not None:
        result["recoveryTransition"] = recovery_binding
    try:
        write_atomic_no_replace(output_path, result)
    except (OSError, FileExistsError) as error:
        print(f"failed to publish run evidence: {error}", file=sys.stderr)
        return 2

    print(
        f"result={result['status']} run_evidence={output_path} "
        f"host_cpu_average={host_cpu_average:.3f} host_cpu_peak={host_cpu_peak:.3f} "
        f"windowserver_cpu_average={window_cpu_average:.3f} "
        f"media_services_cpu_average={media_cpu_average:.3f}"
    )
    if failures:
        print("gate failures: " + "; ".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
