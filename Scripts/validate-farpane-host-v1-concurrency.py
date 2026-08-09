#!/usr/bin/env python3
"""Validate the five ordered FarPane V1 Host/Viewer coexistence scenarios."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any


MANIFEST_SCHEMA = "farpane-host-v1-concurrency-manifest"
LIFECYCLE_SCHEMA = "farpane-host-viewer-concurrency-lifecycle"
OUTPUT_SCHEMA = "farpane-host-v1-concurrency-result"
RESOURCE_AUTHORITY_SCHEMA = "farpane-host-combined-role-pair"
SCENARIO_NAMES = (
    "hostReadyThenOutboundViewer",
    "viewerThenInboundHost",
    "activeHostViewerStartStop",
    "dualDisconnectRecover",
    "appRestartStableHostID",
)
SOURCE_ROLES = {
    "hostReadyThenOutboundViewer": ("application", "hostAgent"),
    "viewerThenInboundHost": ("application", "hostAgent"),
    "activeHostViewerStartStop": ("application", "hostAgent"),
    "dualDisconnectRecover": ("application", "hostAgent"),
    "appRestartStableHostID": ("application", "application", "hostAgent"),
}
MAXIMUM_MANIFEST_BYTES = 128 * 1024
MAXIMUM_LIFECYCLE_BYTES = 2 * 1024 * 1024
MAXIMUM_RECORDS = 512
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
UUID_PATTERN = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
MANIFEST_KEYS = {
    "schema", "schemaVersion", "scope", "resourceAuthority", "scenarios"
}
SCOPE_KEYS = {
    "machineModel",
    "architecture",
    "macOSVersion",
    "bundleIdentifier",
    "buildIdentifier",
    "shortVersion",
    "executableSHA256",
    "applicationBuildIdentitySHA256",
    "hostAgentBuildIdentitySHA256",
}
RESOURCE_REFERENCE_KEYS = {"path", "sha256"}
RESOURCE_RESULT_KEYS = {
    "schema", "schemaVersion", "coverageScope", "status", "failures",
    "scope", "requirements", "runs", "claims", "collectedAt",
}
RESOURCE_SCOPE_KEYS = {
    "machineModel", "architecture", "macOSVersion", "bundleIdentifier",
    "buildIdentifier", "shortVersion", "executableSHA256",
}
RESOURCE_CLAIM_KEYS = {
    "bothAcceptanceScenariosComplete", "sameMachineBuildMacOSScope",
    "section15_2Item10Complete", "v1ConcurrencyRecoveryMatrixComplete",
}
RESOURCE_RUN_NAMES = ("hostReadyViewer", "hostViewerDual")
RESOURCE_RUN_SCENARIOS = {
    "hostReadyViewer": "host-ready-viewer",
    "hostViewerDual": "host-viewer-dual",
}
RESOURCE_RUN_KEYS = {
    "scenario", "requestedDurationSeconds", "scope", "path", "sha256",
    "byteCount",
}
SCENARIO_KEYS = {"name", "sources"}
SOURCE_KEYS = {"role", "path", "sha256"}
RECORD_KEYS = {
    "schema",
    "schemaVersion",
    "sequence",
    "capturedAt",
    "monotonicNanoseconds",
    "observerProcessRole",
    "observerProcessID",
    "observerProcessStartIdentitySHA256",
    "observerBuildIdentitySHA256",
    "scenarioCorrelationSHA256",
    "event",
}
PROCESS_EVENT_KEYS = {"kind"}
HOST_EVENT_KEYS = {
    "kind",
    "state",
    "hostInstanceScopeSHA256",
    "agentBootID",
    "configRevision",
    "hostAgentProcessID",
    "hostAgentProcessStartIdentitySHA256",
    "hostAgentBuildIdentitySHA256",
    "transitionGeneration",
}
VIEWER_EVENT_KEYS = {"kind", "state", "sessionEpoch", "transitionGeneration"}
HOST_STATES = {
    "readyZeroInbound",
    "inboundMediaActive",
    "disconnected",
    "recoveredReadyZeroInbound",
    "recoveredInboundMediaActive",
}
VIEWER_STATES = {
    "starting",
    "authenticatedStreaming",
    "stopped",
    "disconnected",
    "recoveredStreaming",
}


class V1ConcurrencyValidationError(RuntimeError):
    pass


def usage() -> None:
    print(
        "usage: validate-farpane-host-v1-concurrency.py "
        "MANIFEST_JSON OUTPUT_JSON",
        file=sys.stderr,
    )


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_bounded_text(value: Any, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value.encode("utf-8")) <= maximum
        and value == value.strip()
        and all(ord(character) >= 0x20 and ord(character) != 0x7F for character in value)
    )


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def strict_json(raw: bytes, label: str) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"non-finite {token}")
            ),
            object_pairs_hook=unique_object,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise V1ConcurrencyValidationError(f"{label} is invalid strict JSON") from error
    if not isinstance(value, dict):
        raise V1ConcurrencyValidationError(f"{label} root is not an object")
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


def read_bounded_regular(path: Path, maximum_bytes: int, label: str) -> bytes:
    if path.is_symlink():
        raise V1ConcurrencyValidationError(f"{label} must not be a symlink")
    try:
        metadata = path.stat()
    except OSError as error:
        raise V1ConcurrencyValidationError(f"{label} is missing or unreadable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > maximum_bytes
    ):
        raise V1ConcurrencyValidationError(f"{label} identity or size is invalid")
    try:
        return path.read_bytes()
    except OSError as error:
        raise V1ConcurrencyValidationError(f"{label} is unreadable") from error


def safe_relative_jsonl_path(value: Any) -> bool:
    if not is_bounded_text(value, 512):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and candidate.suffix.lower() == ".jsonl"
        and candidate.parts
        and all(part not in ("", ".", "..") for part in candidate.parts)
    )


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


def build_identity_digest(raw_identity: str) -> str:
    payload = b"farpane.v1-concurrency.build.v1\0" + raw_identity.encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise V1ConcurrencyValidationError(f"{label} capturedAt is invalid")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise V1ConcurrencyValidationError(f"{label} capturedAt is invalid") from error
    if parsed.tzinfo is None or parsed.timestamp() < 0:
        raise V1ConcurrencyValidationError(f"{label} capturedAt is invalid")
    return parsed


def validate_scope(scope: Any) -> dict[str, Any]:
    if not isinstance(scope, dict) or set(scope) != SCOPE_KEYS:
        raise V1ConcurrencyValidationError("manifest scope keys do not match schema v1")
    if not is_bounded_text(scope.get("machineModel"), 128):
        raise V1ConcurrencyValidationError("manifest machine model is invalid")
    if scope.get("architecture") not in ("arm64", "x86_64"):
        raise V1ConcurrencyValidationError("manifest architecture is unsupported")
    if not is_bounded_text(scope.get("macOSVersion"), 64):
        raise V1ConcurrencyValidationError("manifest macOS version is invalid")
    for key in ("bundleIdentifier", "buildIdentifier", "shortVersion"):
        if not is_bounded_text(scope.get(key), 128):
            raise V1ConcurrencyValidationError(f"manifest {key} is invalid")
    if not is_sha256(scope.get("executableSHA256")):
        raise V1ConcurrencyValidationError("manifest executable SHA-256 is invalid")
    for key in ("applicationBuildIdentitySHA256", "hostAgentBuildIdentitySHA256"):
        if not is_sha256(scope.get(key)):
            raise V1ConcurrencyValidationError(f"manifest {key} is invalid")
    return scope


def resolve_resource_authority(
    manifest_path: Path,
    reference: Any,
) -> tuple[dict[str, Any], Path, bytes]:
    if not isinstance(reference, dict) or set(reference) != RESOURCE_REFERENCE_KEYS:
        raise V1ConcurrencyValidationError("resource authority reference is invalid")
    relative = reference.get("path")
    if not safe_relative_json_path(relative):
        raise V1ConcurrencyValidationError("resource authority path is unsafe")
    root = manifest_path.parent.resolve()
    path = manifest_path.parent / relative
    try:
        canonical = path.resolve(strict=True)
    except OSError as error:
        raise V1ConcurrencyValidationError("resource authority is missing") from error
    if (
        (canonical.parent != root and root not in canonical.parents)
        or path.is_symlink()
        or canonical != path.absolute()
    ):
        raise V1ConcurrencyValidationError(
            "resource authority escapes its root or uses a symlink"
        )
    raw = read_bounded_regular(
        canonical, MAXIMUM_LIFECYCLE_BYTES, "resource authority"
    )
    if not is_sha256(reference.get("sha256")) or reference["sha256"] != hash_bytes(raw):
        raise V1ConcurrencyValidationError("resource authority SHA-256 does not match")
    document = strict_json(raw, "resource authority")
    if set(document) != RESOURCE_RESULT_KEYS:
        raise V1ConcurrencyValidationError("resource authority keys do not match schema v1")
    if (
        document.get("schema") != RESOURCE_AUTHORITY_SCHEMA
        or document.get("schemaVersion") != 1
        or document.get("coverageScope") != "section-15.2-item-10"
        or document.get("status") != "pass"
        or document.get("failures") != []
        or document.get("requirements")
        != {"host-ready-viewer": "pass", "host-viewer-dual": "pass"}
    ):
        raise V1ConcurrencyValidationError("resource authority did not pass item 10")
    claims = document.get("claims")
    if (
        not isinstance(claims, dict)
        or set(claims) != RESOURCE_CLAIM_KEYS
        or claims.get("bothAcceptanceScenariosComplete") is not True
        or claims.get("sameMachineBuildMacOSScope") is not True
        or claims.get("section15_2Item10Complete") is not True
        or claims.get("v1ConcurrencyRecoveryMatrixComplete") is not False
    ):
        raise V1ConcurrencyValidationError("resource authority claims are invalid")
    resource_scope = document.get("scope")
    if not isinstance(resource_scope, dict) or set(resource_scope) != RESOURCE_SCOPE_KEYS:
        raise V1ConcurrencyValidationError("resource authority scope is invalid")
    for key in ("machineModel", "macOSVersion", "bundleIdentifier", "buildIdentifier", "shortVersion"):
        if not is_bounded_text(resource_scope.get(key), 128):
            raise V1ConcurrencyValidationError("resource authority scope is invalid")
    if (
        resource_scope.get("architecture") not in ("arm64", "x86_64")
        or not is_sha256(resource_scope.get("executableSHA256"))
    ):
        raise V1ConcurrencyValidationError("resource authority scope is invalid")
    runs = document.get("runs")
    if not isinstance(runs, dict) or set(runs) != set(RESOURCE_RUN_NAMES):
        raise V1ConcurrencyValidationError("resource authority runs are invalid")
    seen_paths: set[str] = set()
    seen_digests: set[str] = set()
    for name in RESOURCE_RUN_NAMES:
        run = runs.get(name)
        if not isinstance(run, dict) or set(run) != RESOURCE_RUN_KEYS:
            raise V1ConcurrencyValidationError("resource authority run is invalid")
        if (
            run.get("scenario") != RESOURCE_RUN_SCENARIOS[name]
            or not is_integer(run.get("requestedDurationSeconds"))
            or run["requestedDurationSeconds"] < 600
            or run.get("scope") != resource_scope
            or not is_bounded_text(run.get("path"), 512)
            or not is_sha256(run.get("sha256"))
            or not is_integer(run.get("byteCount"))
            or run["byteCount"] <= 0
            or run["path"] in seen_paths
            or run["sha256"] in seen_digests
        ):
            raise V1ConcurrencyValidationError("resource authority run is invalid")
        seen_paths.add(run["path"])
        seen_digests.add(run["sha256"])
    parse_timestamp(document.get("collectedAt"), "resource authority")
    return document, canonical, raw


def bind_resource_scope(scope: dict[str, Any], resource: dict[str, Any]) -> None:
    resource_scope = resource["scope"]
    for key in RESOURCE_SCOPE_KEYS:
        if scope[key] != resource_scope.get(key):
            raise V1ConcurrencyValidationError(
                f"manifest scope {key} does not match resource authority"
            )
    expected_build_digest = build_identity_digest(scope["buildIdentifier"])
    if (
        scope["applicationBuildIdentitySHA256"] != expected_build_digest
        or scope["hostAgentBuildIdentitySHA256"] != expected_build_digest
    ):
        raise V1ConcurrencyValidationError(
            "lifecycle build identity does not match resource authority build"
        )


def validate_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    if set(manifest) != MANIFEST_KEYS:
        raise V1ConcurrencyValidationError("manifest keys do not match schema v1")
    if manifest.get("schema") != MANIFEST_SCHEMA or manifest.get("schemaVersion") != 1:
        raise V1ConcurrencyValidationError("manifest schema is invalid")
    scope = validate_scope(manifest.get("scope"))
    scenarios = manifest.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) != len(SCENARIO_NAMES):
        raise V1ConcurrencyValidationError("manifest must contain exactly five scenarios")
    if [item.get("name") if isinstance(item, dict) else None for item in scenarios] != list(SCENARIO_NAMES):
        raise V1ConcurrencyValidationError("manifest scenario order does not match V1")
    return scope


def resolve_sources(
    manifest_path: Path,
    scenarios: list[Any],
    reserved_identity: tuple[int, int],
) -> dict[str, list[tuple[dict[str, Any], Path, bytes]]]:
    root = manifest_path.parent.resolve()
    resolved: dict[str, list[tuple[dict[str, Any], Path, bytes]]] = {}
    seen_paths: set[Path] = set()
    seen_identities: set[tuple[int, int]] = {reserved_identity}
    for scenario, expected_name in zip(scenarios, SCENARIO_NAMES):
        if not isinstance(scenario, dict) or set(scenario) != SCENARIO_KEYS:
            raise V1ConcurrencyValidationError(f"scenario {expected_name} keys are invalid")
        sources = scenario.get("sources")
        expected_roles = SOURCE_ROLES[expected_name]
        if not isinstance(sources, list) or len(sources) != len(expected_roles):
            raise V1ConcurrencyValidationError(f"scenario {expected_name} source count is invalid")
        if [item.get("role") if isinstance(item, dict) else None for item in sources] != list(expected_roles):
            raise V1ConcurrencyValidationError(f"scenario {expected_name} source roles are invalid")
        resolved[expected_name] = []
        for index, source in enumerate(sources):
            label = f"scenario {expected_name} source {index + 1}"
            if not isinstance(source, dict) or set(source) != SOURCE_KEYS:
                raise V1ConcurrencyValidationError(f"{label} reference is invalid")
            relative = source.get("path")
            if not safe_relative_jsonl_path(relative):
                raise V1ConcurrencyValidationError(f"{label} path is unsafe")
            path = manifest_path.parent / relative
            try:
                canonical = path.resolve(strict=True)
            except OSError as error:
                raise V1ConcurrencyValidationError(f"{label} is missing") from error
            if (canonical.parent != root and root not in canonical.parents) or path.is_symlink() or canonical != path.absolute():
                raise V1ConcurrencyValidationError(f"{label} escapes its root or uses a symlink")
            raw = read_bounded_regular(canonical, MAXIMUM_LIFECYCLE_BYTES, label)
            metadata = canonical.stat()
            identity = (metadata.st_dev, metadata.st_ino)
            if canonical in seen_paths or identity in seen_identities:
                raise V1ConcurrencyValidationError("manifest contains a duplicate lifecycle source")
            seen_paths.add(canonical)
            seen_identities.add(identity)
            if not is_sha256(source.get("sha256")) or source["sha256"] != hash_bytes(raw):
                raise V1ConcurrencyValidationError(f"{label} SHA-256 does not match")
            resolved[expected_name].append((source, canonical, raw))
    return resolved


def validate_event(event: Any, role: str, label: str) -> None:
    if not isinstance(event, dict) or not isinstance(event.get("kind"), str):
        raise V1ConcurrencyValidationError(f"{label} event is invalid")
    kind = event["kind"]
    if kind in ("processStarted", "processTerminating"):
        if set(event) != PROCESS_EVENT_KEYS:
            raise V1ConcurrencyValidationError(f"{label} process event keys are invalid")
        return
    if kind == "hostState":
        if set(event) != HOST_EVENT_KEYS or event.get("state") not in HOST_STATES:
            raise V1ConcurrencyValidationError(f"{label} Host event is invalid")
        if (
            not is_sha256(event.get("hostInstanceScopeSHA256"))
            or not isinstance(event.get("agentBootID"), str)
            or UUID_PATTERN.fullmatch(event["agentBootID"]) is None
            or not is_integer(event.get("configRevision"))
            or event["configRevision"] <= 0
            or not is_integer(event.get("hostAgentProcessID"))
            or event["hostAgentProcessID"] <= 1
            or not is_sha256(event.get("hostAgentProcessStartIdentitySHA256"))
            or not is_sha256(event.get("hostAgentBuildIdentitySHA256"))
            or not is_integer(event.get("transitionGeneration"))
        ):
            raise V1ConcurrencyValidationError(f"{label} Host event fields are invalid")
        generation = event["transitionGeneration"]
        if (event["state"] in ("readyZeroInbound", "inboundMediaActive")) != (generation == 0):
            raise V1ConcurrencyValidationError(f"{label} Host generation is invalid")
        return
    if kind == "viewerState":
        if role != "application" or set(event) != VIEWER_EVENT_KEYS or event.get("state") not in VIEWER_STATES:
            raise V1ConcurrencyValidationError(f"{label} Viewer event is invalid")
        if (
            not is_integer(event.get("sessionEpoch"))
            or event["sessionEpoch"] <= 0
            or not is_integer(event.get("transitionGeneration"))
        ):
            raise V1ConcurrencyValidationError(f"{label} Viewer event fields are invalid")
        generation = event["transitionGeneration"]
        if (event["state"] in ("starting", "authenticatedStreaming", "stopped")) != (generation == 0):
            raise V1ConcurrencyValidationError(f"{label} Viewer generation is invalid")
        return
    raise V1ConcurrencyValidationError(f"{label} event kind is unknown")


def validate_semantic_transitions(records: list[dict[str, Any]], role: str, label: str) -> None:
    viewer: tuple[int, str, int] | None = None
    host_scope: tuple[Any, ...] | None = None
    host_state: str | None = None
    host_generation = 0
    for record in records[1:-1]:
        event = record["event"]
        if event["kind"] == "viewerState":
            state = event["state"]
            epoch = event["sessionEpoch"]
            generation = event["transitionGeneration"]
            if state == "starting":
                if viewer is not None:
                    raise V1ConcurrencyValidationError(f"{label} overlaps Viewer sessions")
                viewer = (epoch, state, 0)
            elif viewer is None or viewer[0] != epoch:
                raise V1ConcurrencyValidationError(f"{label} Viewer epoch is not active")
            elif state == "authenticatedStreaming" and viewer[1] != "starting":
                raise V1ConcurrencyValidationError(f"{label} Viewer streaming order is invalid")
            elif state == "disconnected" and (
                viewer[1] not in ("authenticatedStreaming", "recoveredStreaming")
                or generation != viewer[2] + 1
            ):
                raise V1ConcurrencyValidationError(f"{label} Viewer disconnect generation is invalid")
            elif state == "recoveredStreaming" and (
                viewer[1] != "disconnected" or generation != viewer[2]
            ):
                raise V1ConcurrencyValidationError(f"{label} Viewer recovery generation is invalid")
            if state == "stopped":
                viewer = None
            else:
                viewer = (epoch, state, generation)
        elif event["kind"] == "hostState":
            scope = (
                event["hostInstanceScopeSHA256"], event["agentBootID"],
                event["configRevision"], event["hostAgentProcessID"],
                event["hostAgentProcessStartIdentitySHA256"],
                event["hostAgentBuildIdentitySHA256"],
            )
            if host_scope is None:
                host_scope = scope
            elif host_scope != scope:
                raise V1ConcurrencyValidationError(f"{label} Host scope drifted")
            state = event["state"]
            generation = event["transitionGeneration"]
            if state == "disconnected":
                if host_state is None or host_state == "disconnected" or generation != host_generation + 1:
                    raise V1ConcurrencyValidationError(f"{label} Host disconnect generation is invalid")
            elif state.startswith("recovered"):
                if (
                    host_state not in (
                        "disconnected",
                        "recoveredReadyZeroInbound",
                        "recoveredInboundMediaActive",
                    )
                    or generation != host_generation
                ):
                    raise V1ConcurrencyValidationError(f"{label} Host recovery generation is invalid")
            elif host_generation != 0:
                raise V1ConcurrencyValidationError(f"{label} Host state lost recovery generation")
            host_state = state
            host_generation = generation


def parse_lifecycle(raw: bytes, expected_role: str, label: str) -> dict[str, Any]:
    lines = raw.splitlines()
    if not lines or len(lines) > MAXIMUM_RECORDS:
        raise V1ConcurrencyValidationError(f"{label} record count is invalid")
    records: list[dict[str, Any]] = []
    identity: tuple[Any, ...] | None = None
    last_time: datetime | None = None
    last_monotonic = 0
    for index, line in enumerate(lines, 1):
        record = strict_json(line, f"{label} record {index}")
        if set(record) != RECORD_KEYS:
            raise V1ConcurrencyValidationError(f"{label} record {index} keys are invalid")
        if record.get("schema") != LIFECYCLE_SCHEMA or record.get("schemaVersion") != 1:
            raise V1ConcurrencyValidationError(f"{label} record {index} schema is invalid")
        if record.get("sequence") != index:
            raise V1ConcurrencyValidationError(f"{label} sequence is not contiguous")
        if record.get("observerProcessRole") != expected_role:
            raise V1ConcurrencyValidationError(f"{label} role does not match manifest")
        if (
            not is_integer(record.get("observerProcessID"))
            or record["observerProcessID"] <= 1
            or not is_sha256(record.get("observerProcessStartIdentitySHA256"))
            or not is_sha256(record.get("observerBuildIdentitySHA256"))
            or not is_sha256(record.get("scenarioCorrelationSHA256"))
            or not is_integer(record.get("monotonicNanoseconds"))
            or record["monotonicNanoseconds"] <= last_monotonic
        ):
            raise V1ConcurrencyValidationError(f"{label} record {index} identity or monotonic time is invalid")
        captured = parse_timestamp(record.get("capturedAt"), f"{label} record {index}")
        if last_time is not None and captured < last_time:
            raise V1ConcurrencyValidationError(f"{label} wall time moved backwards")
        candidate_identity = (
            record["observerProcessID"], record["observerProcessStartIdentitySHA256"],
            record["observerBuildIdentitySHA256"], record["scenarioCorrelationSHA256"],
        )
        if identity is None:
            identity = candidate_identity
        elif identity != candidate_identity:
            raise V1ConcurrencyValidationError(f"{label} process identity drifted")
        validate_event(record.get("event"), expected_role, f"{label} record {index}")
        records.append(record)
        last_time = captured
        last_monotonic = record["monotonicNanoseconds"]
    if records[0]["event"] != {"kind": "processStarted"} or records[-1]["event"] != {"kind": "processTerminating"}:
        raise V1ConcurrencyValidationError(f"{label} lifecycle is incomplete")
    if any(record["event"]["kind"] in ("processStarted", "processTerminating") for record in records[1:-1]):
        raise V1ConcurrencyValidationError(f"{label} lifecycle has an interior process edge")
    validate_semantic_transitions(records, expected_role, label)
    assert identity is not None
    if expected_role == "hostAgent":
        for record in records:
            event = record["event"]
            if event["kind"] == "hostState" and (
                event["hostAgentProcessID"] != identity[0]
                or event["hostAgentProcessStartIdentitySHA256"] != identity[1]
                or event["hostAgentBuildIdentitySHA256"] != identity[2]
            ):
                raise V1ConcurrencyValidationError(f"{label} HostAgent self identity is inconsistent")
    return {"role": expected_role, "identity": identity, "records": records}


def event_records(source: dict[str, Any], kind: str, state: str | None = None) -> list[dict[str, Any]]:
    return [
        record for record in source["records"]
        if record["event"]["kind"] == kind
        and (state is None or record["event"].get("state") == state)
    ]


def first_after(records: list[dict[str, Any]], after: int) -> dict[str, Any]:
    for record in records:
        if record["monotonicNanoseconds"] > after:
            return record
    raise V1ConcurrencyValidationError("required ordered lifecycle edge is missing")


def correlate_agent(apps: list[dict[str, Any]], agent: dict[str, Any], label: str) -> tuple[Any, ...]:
    agent_hosts = event_records(agent, "hostState")
    if not agent_hosts:
        raise V1ConcurrencyValidationError(f"{label} HostAgent has no Host state")
    canonical = agent_hosts[0]["event"]
    scope = (
        canonical["hostInstanceScopeSHA256"], canonical["agentBootID"],
        canonical["configRevision"], canonical["hostAgentProcessID"],
        canonical["hostAgentProcessStartIdentitySHA256"],
        canonical["hostAgentBuildIdentitySHA256"],
    )
    for app in apps:
        if not (
            agent["records"][0]["monotonicNanoseconds"]
            < app["records"][0]["monotonicNanoseconds"]
            and app["records"][-1]["monotonicNanoseconds"]
            < agent["records"][-1]["monotonicNanoseconds"]
        ):
            raise V1ConcurrencyValidationError(
                f"{label} HostAgent does not span the App lifecycle"
            )
        app_hosts = event_records(app, "hostState")
        if not app_hosts:
            raise V1ConcurrencyValidationError(f"{label} App has no Host observation")
        for record in app_hosts:
            event = record["event"]
            candidate = (
                event["hostInstanceScopeSHA256"], event["agentBootID"],
                event["configRevision"], event["hostAgentProcessID"],
                event["hostAgentProcessStartIdentitySHA256"],
                event["hostAgentBuildIdentitySHA256"],
            )
            if candidate != scope:
                raise V1ConcurrencyValidationError(f"{label} App/HostAgent identity does not match")
            if not any(
                agent_record["event"]["state"] == event["state"]
                and agent_record["monotonicNanoseconds"]
                <= record["monotonicNanoseconds"]
                for agent_record in agent_hosts
            ):
                raise V1ConcurrencyValidationError(
                    f"{label} App Host state lacks prior HostAgent authority"
                )
    return scope


def validate_scenario(name: str, sources: list[dict[str, Any]]) -> tuple[str, tuple[Any, ...]]:
    apps = [source for source in sources if source["role"] == "application"]
    agent = next(source for source in sources if source["role"] == "hostAgent")
    scope = correlate_agent(apps, agent, name)
    if name == "appRestartStableHostID":
        apps.sort(key=lambda source: source["records"][0]["monotonicNanoseconds"])
        first, second = apps
        first_ready = event_records(first, "hostState", "readyZeroInbound")
        second_ready = event_records(second, "hostState", "readyZeroInbound")
        if not first_ready or not second_ready:
            raise V1ConcurrencyValidationError(f"{name} lacks a ready Host observation")
        first_end = first["records"][-1]["monotonicNanoseconds"]
        second_start = second["records"][0]["monotonicNanoseconds"]
        if first_end >= second_start or first["identity"][1] == second["identity"][1]:
            raise V1ConcurrencyValidationError(f"{name} does not prove two ordered App lifetimes")
        if not (
            agent["records"][0]["monotonicNanoseconds"] < first_ready[0]["monotonicNanoseconds"]
            and second_ready[0]["monotonicNanoseconds"] < agent["records"][-1]["monotonicNanoseconds"]
        ):
            raise V1ConcurrencyValidationError(f"{name} HostAgent does not span both App lifetimes")
        return "pass", scope

    app = apps[0]
    if name == "hostReadyThenOutboundViewer":
        ready = event_records(app, "hostState", "readyZeroInbound")
        streaming = event_records(app, "viewerState", "authenticatedStreaming")
        if not ready or not streaming:
            raise V1ConcurrencyValidationError(f"{name} required states are missing")
        first_ready = ready[0]
        stream = first_after(streaming, first_ready["monotonicNanoseconds"])
        first_after(ready, stream["monotonicNanoseconds"])
    elif name == "viewerThenInboundHost":
        streaming = event_records(app, "viewerState", "authenticatedStreaming")
        active = event_records(app, "hostState", "inboundMediaActive")
        if not streaming or not active:
            raise V1ConcurrencyValidationError(f"{name} required states are missing")
        first_after(active, streaming[0]["monotonicNanoseconds"])
    elif name == "activeHostViewerStartStop":
        active = event_records(app, "hostState", "inboundMediaActive")
        starting = event_records(app, "viewerState", "starting")
        streaming = event_records(app, "viewerState", "authenticatedStreaming")
        stopped = event_records(app, "viewerState", "stopped")
        if not active or not starting or not streaming or not stopped:
            raise V1ConcurrencyValidationError(f"{name} required states are missing")
        start = first_after(starting, active[0]["monotonicNanoseconds"])
        stream = first_after(streaming, start["monotonicNanoseconds"])
        stop = first_after(stopped, stream["monotonicNanoseconds"])
        first_after(active, stop["monotonicNanoseconds"])
    elif name == "dualDisconnectRecover":
        active = event_records(app, "hostState", "inboundMediaActive")
        streaming = event_records(app, "viewerState", "authenticatedStreaming")
        if not active or not streaming:
            raise V1ConcurrencyValidationError(f"{name} initial dual-active state is missing")
        both_active = max(active[0]["monotonicNanoseconds"], streaming[0]["monotonicNanoseconds"])
        host_disconnected = first_after(event_records(app, "hostState", "disconnected"), both_active)
        viewer_disconnected = first_after(event_records(app, "viewerState", "disconnected"), both_active)
        both_disconnected = max(host_disconnected["monotonicNanoseconds"], viewer_disconnected["monotonicNanoseconds"])
        host_recovered = first_after(event_records(app, "hostState", "recoveredInboundMediaActive"), both_disconnected)
        viewer_recovered = first_after(event_records(app, "viewerState", "recoveredStreaming"), both_disconnected)
        agent_disconnected = event_records(agent, "hostState", "disconnected")
        agent_recovered = event_records(agent, "hostState", "recoveredInboundMediaActive")
        if not agent_disconnected or not agent_recovered or agent_disconnected[0]["monotonicNanoseconds"] >= agent_recovered[0]["monotonicNanoseconds"]:
            raise V1ConcurrencyValidationError(f"{name} HostAgent recovery order is missing")
        _ = max(host_recovered["monotonicNanoseconds"], viewer_recovered["monotonicNanoseconds"])
    else:
        raise V1ConcurrencyValidationError(f"unknown scenario {name}")
    return "pass", scope


def validate(manifest_path: Path) -> dict[str, Any]:
    if not manifest_path.is_absolute() or has_symlink_component(manifest_path):
        raise V1ConcurrencyValidationError("manifest path must be absolute and non-symlink")
    manifest_raw = read_bounded_regular(manifest_path, MAXIMUM_MANIFEST_BYTES, "manifest")
    manifest = strict_json(manifest_raw, "manifest")
    scope = validate_manifest(manifest)
    resource, resource_path, resource_raw = resolve_resource_authority(
        manifest_path, manifest["resourceAuthority"]
    )
    bind_resource_scope(scope, resource)
    resource_metadata = resource_path.stat()
    resolved = resolve_sources(
        manifest_path,
        manifest["scenarios"],
        (resource_metadata.st_dev, resource_metadata.st_ino),
    )
    requirements: dict[str, str] = {}
    source_results: dict[str, list[dict[str, Any]]] = {}
    scenario_scopes: list[tuple[Any, ...]] = []
    scenario_digests: set[str] = set()
    failures: list[str] = []
    for name in SCENARIO_NAMES:
        parsed: list[dict[str, Any]] = []
        source_results[name] = []
        try:
            for reference, _, raw in resolved[name]:
                lifecycle = parse_lifecycle(raw, reference["role"], f"scenario {name} {reference['role']}")
                expected_build = scope[
                    "applicationBuildIdentitySHA256" if reference["role"] == "application"
                    else "hostAgentBuildIdentitySHA256"
                ]
                if lifecycle["identity"][2] != expected_build:
                    raise V1ConcurrencyValidationError(f"scenario {name} build identity does not match scope")
                parsed.append(lifecycle)
                source_results[name].append({
                    "role": reference["role"], "path": reference["path"],
                    "sha256": hash_bytes(raw), "byteCount": len(raw),
                    "recordCount": len(lifecycle["records"]),
                })
            digests = {source["identity"][3] for source in parsed}
            if len(digests) != 1:
                raise V1ConcurrencyValidationError(f"scenario {name} correlation digest does not match")
            digest = next(iter(digests))
            if digest in scenario_digests:
                raise V1ConcurrencyValidationError(f"scenario {name} reuses another scenario correlation digest")
            scenario_digests.add(digest)
            result, scenario_scope = validate_scenario(name, parsed)
            requirements[name] = result
            scenario_scopes.append(scenario_scope)
        except V1ConcurrencyValidationError as error:
            requirements[name] = "fail"
            failures.append(str(error))
    same_host = len(scenario_scopes) == len(SCENARIO_NAMES) and len({item[0] for item in scenario_scopes}) == 1
    if not same_host:
        failures.append("five scenarios do not preserve one Host instance scope")
    status = "pass" if not failures else "fail"
    return {
        "schema": OUTPUT_SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "sections-18-and-20.3-v1-coexistence",
        "status": status,
        "failures": failures,
        "scope": scope,
        "resourceAuthority": {
            "path": manifest["resourceAuthority"]["path"],
            "sha256": hash_bytes(resource_raw),
            "byteCount": len(resource_raw),
            "section15_2Item10Complete": True,
        },
        "requirements": requirements,
        "sources": source_results,
        "claims": {
            "exactlyFiveOrderedScenariosComplete": status == "pass",
            "sameMachineArchitectureMacOSAndBuild": status == "pass",
            "sameHostInstanceScopeAcrossMatrix": status == "pass" and same_host,
            "exactProcessAndAgentIdentityBound": status == "pass",
            "itemTenResourceAuthorityBound": status == "pass",
            "v1ConcurrencyMatrixComplete": status == "pass",
            "installedTwoMachineExecutionBound": status == "pass",
        },
        "validatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def validate_output_path(output: Path, manifest: Path) -> None:
    if not output.is_absolute() or output.suffix.lower() != ".json":
        raise V1ConcurrencyValidationError("output path must be an absolute JSON path")
    if output.exists() or output.is_symlink():
        raise V1ConcurrencyValidationError("refusing to overwrite existing output")
    if output == manifest:
        raise V1ConcurrencyValidationError("output path must differ from manifest")
    if not output.parent.is_dir() or has_symlink_component(output.parent):
        raise V1ConcurrencyValidationError("output parent must be existing and non-symlink")
    metadata = output.parent.stat()
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise V1ConcurrencyValidationError("output parent ownership or permissions are unsafe")


def write_atomic_no_replace(path: Path, document: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-v1-concurrency-", suffix=".tmp", dir=path.parent
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
        raise V1ConcurrencyValidationError("failed to publish V1 concurrency result") from error
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
    except V1ConcurrencyValidationError as error:
        print(f"V1 concurrency validation refused: {error}", file=sys.stderr)
        return 2
    print(
        f"status={result['status']} output={output_path} "
        f"v1_concurrency_matrix_complete="
        f"{str(result['claims']['v1ConcurrencyMatrixComplete']).lower()}"
    )
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
