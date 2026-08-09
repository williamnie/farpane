#!/usr/bin/env python3
"""Orchestrate explicit installed-process V1 concurrency evidence capture."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


SCHEMA = "farpane-host-v1-concurrency-capture-receipt"
MANIFEST_SCHEMA = "farpane-host-v1-concurrency-manifest"
SCENARIOS = (
    "hostReadyThenOutboundViewer",
    "viewerThenInboundHost",
    "activeHostViewerStartStop",
    "dualDisconnectRecover",
    "appRestartStableHostID",
)
RESTART_SCENARIO = "appRestartStableHostID"
SERVICE_LABEL = "io.rustdesknative.viewer.host-agent"
OUTPUT_ENVIRONMENT_KEY = "FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"
SCENARIO_ENVIRONMENT_KEY = "FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"
DEFAULT_APP_BUNDLE = Path("/Applications/FarPane.app")
LAUNCHCTL = Path("/bin/launchctl")
CODESIGN = Path("/usr/bin/codesign")
MAXIMUM_RECEIPT_BYTES = 256 * 1024
MAXIMUM_RESOURCE_BYTES = 2 * 1024 * 1024
MAXIMUM_PROCESS_WAIT_SECONDS = 15.0
MAXIMUM_TERMINAL_WAIT_SECONDS = 5.0
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

RECEIPT_KEYS = {
    "schema",
    "schemaVersion",
    "scenario",
    "status",
    "serviceTarget",
    "applicationBundle",
    "expectedExecutable",
    "agent",
    "applications",
    "artifacts",
}
PROCESS_KEYS = {
    "pid",
    "role",
    "executablePath",
    "executableSHA256",
    "bundleIdentifier",
    "buildIdentifier",
    "shortVersion",
    "startMarker",
    "argumentsSHA256",
    "hostAgentFlagCount",
    "terminated",
}
EXPECTED_EXECUTABLE_KEYS = {
    "path",
    "sha256",
    "bundleIdentifier",
    "buildIdentifier",
    "shortVersion",
}
ARTIFACT_KEYS = {"hostAgent", "applications"}


class CaptureError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True)
class ExecutableScope:
    path: Path
    sha256: str
    bundle_identifier: str
    build_identifier: str
    short_version: str


class SystemOperations:
    def run(self, command: list[str], timeout: float = 15.0) -> CommandResult:
        try:
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise CaptureError(f"command failed to execute: {command[0]}") from error
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)

    def spawn(self, executable: Path, environment: dict[str, str]) -> int:
        try:
            process = subprocess.Popen(
                [str(executable)],
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
        except OSError as error:
            raise CaptureError("installed App executable could not start") from error
        return process.pid

    def inspect_running_process(self, pid: int, role: str) -> dict[str, Any]:
        sampler = load_combined_sampler()
        try:
            identity = sampler.capture_process_identity(pid, role)
        except Exception as error:
            raise CaptureError(f"cannot verify exact {role} pid={pid}") from error
        return {
            "pid": identity.pid,
            "role": identity.role,
            "executablePath": str(identity.executable.path),
            "executableSHA256": identity.executable.sha256,
            "bundleIdentifier": identity.bundle.bundle_identifier,
            "buildIdentifier": identity.bundle.build_identifier,
            "shortVersion": identity.bundle.short_version,
            "startMarker": identity.start_marker,
            "argumentsSHA256": identity.arguments_sha256,
            "hostAgentFlagCount": identity.host_agent_flag_count,
            "terminated": False,
        }

    def signal_process(self, pid: int) -> None:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as error:
            raise CaptureError(f"cannot terminate exact pid={pid}") from error

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


_COMBINED_SAMPLER: Any = None


def load_combined_sampler() -> Any:
    global _COMBINED_SAMPLER
    if _COMBINED_SAMPLER is not None:
        return _COMBINED_SAMPLER
    path = Path(__file__).resolve().with_name(
        "sample-farpane-host-combined-role.py"
    )
    spec = importlib.util.spec_from_file_location(
        "farpane_host_combined_role_sampler_for_capture", path
    )
    if spec is None or spec.loader is None:
        raise CaptureError("cannot load exact process identity authority")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    _COMBINED_SAMPLER = module
    return module


def usage() -> None:
    print(
        "usage:\n"
        "  run-farpane-host-v1-concurrency-capture.py start "
        "MATRIX_ROOT SCENARIO\n"
        "  run-farpane-host-v1-concurrency-capture.py restart-app "
        "MATRIX_ROOT\n"
        "  run-farpane-host-v1-concurrency-capture.py finish "
        "MATRIX_ROOT SCENARIO\n"
        "  run-farpane-host-v1-concurrency-capture.py finalize "
        "MATRIX_ROOT ITEM10_PAIR_RESULT",
        file=sys.stderr,
    )


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def has_control_character(value: str) -> bool:
    return any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)


def has_symlink_component(path: Path) -> bool:
    if not path.is_absolute():
        return True
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            return True
    return False


def validate_matrix_root(path: Path) -> Path:
    if not path.is_absolute() or path.is_symlink() or has_symlink_component(path):
        raise CaptureError("matrix root must be absolute and non-symlink")
    try:
        metadata = path.stat()
    except OSError as error:
        raise CaptureError("matrix root must already exist") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise CaptureError("matrix root must be an operator-owned mode-0700 directory")
    return path


def validate_scenario(value: str) -> str:
    if value not in SCENARIOS:
        raise CaptureError("scenario is not one of the five V1 cases")
    return value


def scenario_directory(root: Path, scenario: str) -> Path:
    return root / scenario


def validate_existing_scenario_directory(root: Path, scenario: str) -> Path:
    directory = scenario_directory(root, scenario)
    if directory.is_symlink() or has_symlink_component(directory):
        raise CaptureError("scenario directory must not contain a symlink")
    try:
        metadata = directory.stat()
    except OSError as error:
        raise CaptureError("scenario directory is missing") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise CaptureError(
            "scenario directory must be operator-owned mode-0700"
        )
    return directory


def receipt_path(root: Path, scenario: str) -> Path:
    return scenario_directory(root, scenario) / "capture-receipt.json"


def inspect_installed_executable(app_bundle: Path) -> ExecutableScope:
    if app_bundle != DEFAULT_APP_BUNDLE:
        raise CaptureError("capture requires /Applications/FarPane.app")
    if app_bundle.is_symlink() or has_symlink_component(app_bundle):
        raise CaptureError("installed App bundle path contains a symlink")
    info_path = app_bundle / "Contents/Info.plist"
    try:
        raw = info_path.read_bytes()
        document = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise CaptureError("installed App Info.plist is unreadable") from error
    if not isinstance(document, dict):
        raise CaptureError("installed App Info.plist is malformed")
    executable_name = document.get("CFBundleExecutable")
    executable = app_bundle / "Contents/MacOS" / str(executable_name)
    sampler = load_combined_sampler()
    try:
        executable_identity = sampler.hash_open_executable(executable)
        bundle_identity = sampler.read_bundle_identity(executable)
    except Exception as error:
        raise CaptureError("installed App identity is invalid") from error
    if bundle_identity.bundle_identifier != SERVICE_LABEL.removesuffix(".host-agent"):
        raise CaptureError("installed App bundle identifier is unexpected")
    return ExecutableScope(
        path=executable_identity.path,
        sha256=executable_identity.sha256,
        bundle_identifier=bundle_identity.bundle_identifier,
        build_identifier=bundle_identity.build_identifier,
        short_version=bundle_identity.short_version,
    )


def expected_executable_document(scope: ExecutableScope) -> dict[str, Any]:
    return {
        "path": str(scope.path),
        "sha256": scope.sha256,
        "bundleIdentifier": scope.bundle_identifier,
        "buildIdentifier": scope.build_identifier,
        "shortVersion": scope.short_version,
    }


def process_matches_scope(process: dict[str, Any], scope: dict[str, Any]) -> bool:
    return (
        process.get("executablePath") == scope.get("path")
        and process.get("executableSHA256") == scope.get("sha256")
        and process.get("bundleIdentifier") == scope.get("bundleIdentifier")
        and process.get("buildIdentifier") == scope.get("buildIdentifier")
        and process.get("shortVersion") == scope.get("shortVersion")
    )


def validate_process_document(process: Any, role: str) -> dict[str, Any]:
    if not isinstance(process, dict) or set(process) != PROCESS_KEYS:
        raise CaptureError("capture receipt process identity is invalid")
    expected_flag_count = 1 if role == "host-agent" else 0
    if (
        not isinstance(process.get("pid"), int)
        or isinstance(process.get("pid"), bool)
        or process["pid"] <= 1
        or process.get("role") != role
        or not isinstance(process.get("executablePath"), str)
        or not is_sha256(process.get("executableSHA256"))
        or not is_sha256(process.get("argumentsSHA256"))
        or process.get("hostAgentFlagCount") != expected_flag_count
        or not isinstance(process.get("terminated"), bool)
    ):
        raise CaptureError("capture receipt process identity is invalid")
    for key in ("bundleIdentifier", "buildIdentifier", "shortVersion", "startMarker"):
        value = process.get(key)
        if not isinstance(value, str) or not value or has_control_character(value):
            raise CaptureError("capture receipt process identity is invalid")
    return process


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
        raise CaptureError(f"{label} is invalid strict JSON") from error
    if not isinstance(value, dict):
        raise CaptureError(f"{label} root is not an object")
    return value


def read_receipt(root: Path, scenario: str) -> dict[str, Any]:
    validate_existing_scenario_directory(root, scenario)
    path = receipt_path(root, scenario)
    if path.is_symlink():
        raise CaptureError("capture receipt must not be a symlink")
    try:
        metadata = path.stat()
        raw = path.read_bytes()
    except OSError as error:
        raise CaptureError("capture receipt is missing or unreadable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or not 0 < len(raw) <= MAXIMUM_RECEIPT_BYTES
    ):
        raise CaptureError("capture receipt identity or size is invalid")
    document = strict_json(raw, "capture receipt")
    validate_receipt(document, scenario)
    return document


def validate_receipt(document: dict[str, Any], scenario: str) -> None:
    if set(document) != RECEIPT_KEYS:
        raise CaptureError("capture receipt keys do not match schema v1")
    if (
        document.get("schema") != SCHEMA
        or document.get("schemaVersion") != 1
        or document.get("scenario") != scenario
        or document.get("serviceTarget")
        != f"gui/{os.geteuid()}/{SERVICE_LABEL}"
        or document.get("applicationBundle") != str(DEFAULT_APP_BUNDLE)
        or document.get("status")
        not in (
            "agentStarted",
            "active",
            "restarting",
            "restartFailed",
            "finishing",
            "aborting",
            "aborted",
            "completed",
        )
    ):
        raise CaptureError("capture receipt schema or scope is invalid")
    expected = document.get("expectedExecutable")
    if not isinstance(expected, dict) or set(expected) != EXPECTED_EXECUTABLE_KEYS:
        raise CaptureError("capture receipt executable scope is invalid")
    if not is_sha256(expected.get("sha256")):
        raise CaptureError("capture receipt executable scope is invalid")
    agent = validate_process_document(document.get("agent"), "host-agent")
    applications = document.get("applications")
    if not isinstance(applications, list) or len(applications) > 2:
        raise CaptureError("capture receipt App lifetimes are invalid")
    for process in applications:
        validate_process_document(process, "viewer")
    if any(not process_matches_scope(process, expected) for process in [agent, *applications]):
        raise CaptureError("capture receipt process build scope drifted")
    if any(process["pid"] == agent["pid"] for process in applications):
        raise CaptureError("capture receipt reuses the live HostAgent PID")
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != ARTIFACT_KEYS:
        raise CaptureError("capture receipt artifact paths are invalid")
    expected_app_count = 2 if scenario == RESTART_SCENARIO else 1
    app_paths = artifacts.get("applications")
    if (
        artifacts.get("hostAgent") != "host-agent.jsonl"
        or not isinstance(app_paths, list)
        or app_paths != [f"application-{index}.jsonl" for index in range(1, expected_app_count + 1)]
    ):
        raise CaptureError("capture receipt artifact paths are invalid")
    status = document["status"]
    if status == "agentStarted" and (
        agent["terminated"] or applications
    ):
        raise CaptureError("agent-started receipt has impossible lifetimes")
    if status == "active":
        active_shape = (
            not agent["terminated"]
            and len(applications) in (
                (1, 2) if scenario == RESTART_SCENARIO else (1,)
            )
            and not applications[-1]["terminated"]
            and all(app["terminated"] for app in applications[:-1])
        )
        if not active_shape:
            raise CaptureError("active receipt has impossible lifetimes")
    if status == "restarting" and (
        scenario != RESTART_SCENARIO
        or agent["terminated"]
        or len(applications) != 1
        or not applications[0]["terminated"]
    ):
        raise CaptureError("restarting receipt has impossible lifetimes")
    if status == "finishing" and len(applications) != expected_app_count:
        raise CaptureError("finishing receipt lacks required App lifetimes")
    if status == "completed" and (
        len(applications) != expected_app_count
        or not agent["terminated"]
        or any(not app["terminated"] for app in applications)
    ):
        raise CaptureError("completed receipt has incomplete lifetimes")
    if status == "aborted" and (
        not agent["terminated"]
        or any(not app["terminated"] for app in applications)
    ):
        raise CaptureError("aborted receipt retains a live recorded process")


def write_new_json(path: Path, document: dict[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        raise CaptureError(f"refusing to overwrite {path.name}")
    raw = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        with os.fdopen(descriptor, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        if created:
            path.unlink(missing_ok=True)
        raise CaptureError(f"cannot publish {path.name}") from error


def replace_receipt(path: Path, document: dict[str, Any]) -> None:
    validate_receipt(document, document["scenario"])
    raw = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".capture-receipt-", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        parent_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    except OSError as error:
        raise CaptureError("cannot update capture receipt") from error
    finally:
        temporary.unlink(missing_ok=True)


def command_must_pass(
    operations: SystemOperations,
    command: list[str],
    failure: str,
) -> CommandResult:
    result = operations.run(command)
    if result.returncode != 0:
        raise CaptureError(failure)
    return result


def inspect_with_retry(
    operations: SystemOperations,
    pid: int,
    role: str,
    timeout: float = 5.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_error: CaptureError | None = None
    while time.monotonic() < deadline:
        try:
            return operations.inspect_running_process(pid, role)
        except CaptureError as error:
            last_error = error
            operations.sleep(0.05)
    raise CaptureError(f"cannot verify launched {role} pid={pid}") from last_error


def revalidate_process(
    operations: SystemOperations,
    recorded: dict[str, Any],
) -> dict[str, Any]:
    current = operations.inspect_running_process(recorded["pid"], recorded["role"])
    comparable_keys = PROCESS_KEYS - {"terminated"}
    if any(current.get(key) != recorded.get(key) for key in comparable_keys):
        raise CaptureError(
            f"refusing to signal changed or reused pid={recorded['pid']}"
        )
    return current


def wait_for_process_exit(
    operations: SystemOperations,
    recorded: dict[str, Any],
    timeout: float = MAXIMUM_PROCESS_WAIT_SECONDS,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            revalidate_process(operations, recorded)
        except CaptureError as error:
            if "cannot verify exact" in str(error):
                return
            raise
        operations.sleep(0.05)
    raise CaptureError(f"pid={recorded['pid']} did not terminate in time")


def terminal_record_present(path: Path, role: str) -> bool:
    if path.is_symlink() or has_symlink_component(path):
        return False
    try:
        metadata = path.stat()
        raw = path.read_bytes()
    except OSError:
        return False
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
        or not 0 < len(raw) <= MAXIMUM_RESOURCE_BYTES
    ):
        return False
    lines = raw.splitlines()
    if not lines:
        return False
    try:
        record = strict_json(lines[-1], f"{role} terminal record")
    except CaptureError:
        return False
    return (
        record.get("observerProcessRole")
        == ("hostAgent" if role == "host-agent" else "application")
        and record.get("event") == {"kind": "processTerminating"}
    )


def wait_for_terminal_record(
    operations: SystemOperations,
    path: Path,
    role: str,
    timeout: float = MAXIMUM_TERMINAL_WAIT_SECONDS,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if terminal_record_present(path, role):
            return
        operations.sleep(0.05)
    raise CaptureError(f"{role} terminal lifecycle record is missing")


def terminate_recorded_process(
    operations: SystemOperations,
    recorded: dict[str, Any],
    artifact: Path,
) -> dict[str, Any]:
    if recorded["terminated"]:
        raise CaptureError("process lifetime is already terminated")
    revalidate_process(operations, recorded)
    operations.signal_process(recorded["pid"])
    wait_for_process_exit(operations, recorded)
    wait_for_terminal_record(operations, artifact, recorded["role"])
    updated = dict(recorded)
    updated["terminated"] = True
    return updated


def start_capture(
    root: Path,
    scenario: str,
    operations: SystemOperations,
    *,
    app_bundle: Path = DEFAULT_APP_BUNDLE,
    inspect_bundle: Callable[[Path], ExecutableScope] = inspect_installed_executable,
) -> dict[str, Any]:
    root = validate_matrix_root(root)
    scenario = validate_scenario(scenario)
    directory = scenario_directory(root, scenario)
    if directory.exists() or directory.is_symlink():
        raise CaptureError("scenario directory already exists")
    scope = inspect_bundle(app_bundle)
    codesign = command_must_pass(
        operations,
        [str(CODESIGN), "--verify", "--strict", "--deep", str(app_bundle)],
        "installed App code signature verification failed",
    )
    _ = codesign
    service_target = f"gui/{os.geteuid()}/{SERVICE_LABEL}"
    agent_output = directory / "host-agent.jsonl"
    app_output = directory / "application-1.jsonl"
    command_must_pass(
        operations,
        [str(LAUNCHCTL), "print", service_target],
        "registered HostAgent service is unavailable",
    )
    try:
        os.mkdir(directory, 0o700)
    except OSError as error:
        raise CaptureError("cannot create scenario directory") from error
    try:
        command_must_pass(
            operations,
            [
                str(LAUNCHCTL), "debug", service_target, "--environment",
                f"{OUTPUT_ENVIRONMENT_KEY}={agent_output}",
                f"{SCENARIO_ENVIRONMENT_KEY}={scenario}",
            ],
            "cannot configure one-shot HostAgent evidence environment",
        )
    except CaptureError:
        try:
            directory.rmdir()
        except OSError:
            pass
        raise
    kickstart = operations.run(
        [str(LAUNCHCTL), "kickstart", "-k", "-p", service_target]
    )
    if kickstart.returncode != 0:
        operations.run([
            str(LAUNCHCTL), "debug", service_target, "--environment",
            f"{OUTPUT_ENVIRONMENT_KEY}=", f"{SCENARIO_ENVIRONMENT_KEY}=",
        ])
        try:
            directory.rmdir()
        except OSError:
            pass
        raise CaptureError("cannot restart exact HostAgent service")
    pid_text = kickstart.stdout.strip()
    if not re.fullmatch(r"[1-9][0-9]*", pid_text) or int(pid_text) <= 1:
        raise CaptureError("launchctl did not return an exact HostAgent PID")
    agent = inspect_with_retry(operations, int(pid_text), "host-agent")
    validate_process_document(agent, "host-agent")
    expected = expected_executable_document(scope)
    if not process_matches_scope(agent, expected):
        raise CaptureError("HostAgent does not match installed App identity")
    receipt = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "scenario": scenario,
        "status": "agentStarted",
        "serviceTarget": service_target,
        "applicationBundle": str(app_bundle),
        "expectedExecutable": expected,
        "agent": agent,
        "applications": [],
        "artifacts": {
            "hostAgent": agent_output.name,
            "applications": [
                f"application-{index}.jsonl"
                for index in range(1, 3 if scenario == RESTART_SCENARIO else 2)
            ],
        },
    }
    try:
        write_new_json(receipt_path(root, scenario), receipt)
    except CaptureError:
        try:
            terminate_recorded_process(
                operations,
                agent,
                agent_output,
            )
        except CaptureError:
            pass
        raise
    environment = dict(os.environ)
    environment[OUTPUT_ENVIRONMENT_KEY] = str(app_output)
    environment[SCENARIO_ENVIRONMENT_KEY] = scenario
    application: dict[str, Any] | None = None
    try:
        app_pid = operations.spawn(scope.path, environment)
        application = inspect_with_retry(operations, app_pid, "viewer")
        validate_process_document(application, "viewer")
        if not process_matches_scope(application, expected):
            raise CaptureError("App does not match HostAgent build identity")
        receipt["applications"] = [application]
        receipt["status"] = "active"
        replace_receipt(receipt_path(root, scenario), receipt)
    except CaptureError:
        if application is not None:
            try:
                terminated_application = terminate_recorded_process(
                    operations,
                    application,
                    app_output,
                )
                if receipt["applications"]:
                    receipt["applications"][0] = terminated_application
            except CaptureError:
                pass
        try:
            receipt["agent"] = terminate_recorded_process(
                operations,
                agent,
                agent_output,
            )
        except CaptureError:
            pass
        receipt["status"] = "restartFailed"
        replace_receipt(receipt_path(root, scenario), receipt)
        raise
    return receipt


def restart_application(
    root: Path,
    operations: SystemOperations,
) -> dict[str, Any]:
    root = validate_matrix_root(root)
    scenario = RESTART_SCENARIO
    receipt = read_receipt(root, scenario)
    if receipt["status"] != "active" or len(receipt["applications"]) != 1:
        raise CaptureError("restart case is not awaiting its second App lifetime")
    directory = scenario_directory(root, scenario)
    first = receipt["applications"][0]
    receipt["applications"][0] = terminate_recorded_process(
        operations,
        first,
        directory / receipt["artifacts"]["applications"][0],
    )
    receipt["status"] = "restarting"
    replace_receipt(receipt_path(root, scenario), receipt)
    environment = dict(os.environ)
    environment[OUTPUT_ENVIRONMENT_KEY] = str(
        directory / receipt["artifacts"]["applications"][1]
    )
    environment[SCENARIO_ENVIRONMENT_KEY] = scenario
    second: dict[str, Any] | None = None
    try:
        app_pid = operations.spawn(
            Path(receipt["expectedExecutable"]["path"]), environment
        )
        second = inspect_with_retry(operations, app_pid, "viewer")
        validate_process_document(second, "viewer")
        if not process_matches_scope(second, receipt["expectedExecutable"]):
            raise CaptureError("second App lifetime changed build identity")
        if second["startMarker"] == first["startMarker"]:
            raise CaptureError("second App lifetime did not change process start")
        receipt["applications"].append(second)
        receipt["status"] = "active"
        replace_receipt(receipt_path(root, scenario), receipt)
    except CaptureError:
        if second is not None:
            try:
                terminated_second = terminate_recorded_process(
                    operations,
                    second,
                    directory / receipt["artifacts"]["applications"][1],
                )
                if len(receipt["applications"]) == 2:
                    receipt["applications"][1] = terminated_second
            except CaptureError:
                pass
        receipt["status"] = "restartFailed"
        replace_receipt(receipt_path(root, scenario), receipt)
        raise
    return receipt


def finish_capture(
    root: Path,
    scenario: str,
    operations: SystemOperations,
) -> dict[str, Any]:
    root = validate_matrix_root(root)
    scenario = validate_scenario(scenario)
    receipt = read_receipt(root, scenario)
    required_apps = 2 if scenario == RESTART_SCENARIO else 1
    if receipt["status"] not in (
        "active",
        "restarting",
        "restartFailed",
        "finishing",
        "aborting",
    ):
        raise CaptureError("scenario is not active")
    if receipt["status"] == "active" and len(receipt["applications"]) != required_apps:
        raise CaptureError("scenario has not completed every App lifetime")
    cleanup_status = (
        "finishing"
        if receipt["status"] in ("active", "finishing")
        else "aborting"
    )
    receipt["status"] = cleanup_status
    replace_receipt(receipt_path(root, scenario), receipt)
    directory = scenario_directory(root, scenario)
    for index, application in enumerate(receipt["applications"]):
        if application["terminated"]:
            continue
        receipt["applications"][index] = terminate_recorded_process(
            operations,
            application,
            directory / receipt["artifacts"]["applications"][index],
        )
        replace_receipt(receipt_path(root, scenario), receipt)
    if not receipt["agent"]["terminated"]:
        receipt["agent"] = terminate_recorded_process(
            operations,
            receipt["agent"],
            directory / receipt["artifacts"]["hostAgent"],
        )
    receipt["status"] = (
        "completed"
        if cleanup_status == "finishing"
        else "aborted"
    )
    replace_receipt(receipt_path(root, scenario), receipt)
    return receipt


def hash_file(path: Path, maximum: int) -> tuple[str, int]:
    if path.is_symlink():
        raise CaptureError(f"{path.name} must not be a symlink")
    try:
        metadata = path.stat()
    except OSError as error:
        raise CaptureError(f"{path.name} is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > maximum
    ):
        raise CaptureError(f"{path.name} identity or size is invalid")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise CaptureError(f"{path.name} is unreadable") from error
    return digest.hexdigest(), metadata.st_size


def build_identity_digest(raw_identity: str) -> str:
    return hashlib.sha256(
        b"farpane.v1-concurrency.build.v1\0" + raw_identity.encode("utf-8")
    ).hexdigest()


def read_resource(source: Path) -> bytes:
    if not source.is_absolute() or source.is_symlink() or has_symlink_component(source):
        raise CaptureError("item-10 result must be absolute and non-symlink")
    hash_file(source, MAXIMUM_RESOURCE_BYTES)
    try:
        return source.read_bytes()
    except OSError as error:
        raise CaptureError("item-10 result is unreadable") from error


def publish_resource_no_replace(raw: bytes, target: Path) -> None:
    if target.exists() or target.is_symlink():
        raise CaptureError("refusing to overwrite copied item-10 result")
    created = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(target, flags, 0o600)
        created = True
        with os.fdopen(descriptor, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        if created:
            target.unlink(missing_ok=True)
        raise CaptureError("cannot copy item-10 result") from error


def finalize_matrix(
    root: Path,
    item_ten_result: Path,
    operations: SystemOperations,
) -> Path:
    root = validate_matrix_root(root)
    manifest_path = root / "v1-concurrency-manifest.json"
    result_path = root / "v1-concurrency-result.json"
    resource_path = root / "item-10-pair-result.json"
    for path in (manifest_path, result_path, resource_path):
        if path.exists() or path.is_symlink():
            raise CaptureError(f"refusing to overwrite {path.name}")
    resource_raw = read_resource(item_ten_result)
    resource = strict_json(resource_raw, "item-10 pair result")
    scope = resource.get("scope")
    if not isinstance(scope, dict):
        raise CaptureError("item-10 pair result scope is missing")
    build_identifier = scope.get("buildIdentifier")
    if not isinstance(build_identifier, str) or not build_identifier:
        raise CaptureError("item-10 pair result build identity is missing")
    build_digest = build_identity_digest(build_identifier)
    scenarios: list[dict[str, Any]] = []
    for scenario in SCENARIOS:
        receipt = read_receipt(root, scenario)
        if receipt["status"] != "completed":
            raise CaptureError(f"scenario {scenario} is not completed")
        directory = scenario_directory(root, scenario)
        references: list[dict[str, Any]] = []
        for relative in receipt["artifacts"]["applications"]:
            path = directory / relative
            digest, _ = hash_file(path, MAXIMUM_RESOURCE_BYTES)
            references.append({
                "role": "application",
                "path": str(path.relative_to(root)),
                "sha256": digest,
            })
        agent_path = directory / receipt["artifacts"]["hostAgent"]
        agent_digest, _ = hash_file(agent_path, MAXIMUM_RESOURCE_BYTES)
        references.append({
            "role": "hostAgent",
            "path": str(agent_path.relative_to(root)),
            "sha256": agent_digest,
        })
        scenarios.append({"name": scenario, "sources": references})
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "schemaVersion": 1,
        "scope": {
            **scope,
            "applicationBuildIdentitySHA256": build_digest,
            "hostAgentBuildIdentitySHA256": build_digest,
        },
        "resourceAuthority": {
            "path": resource_path.name,
            "sha256": hashlib.sha256(resource_raw).hexdigest(),
        },
        "scenarios": scenarios,
    }
    publish_resource_no_replace(resource_raw, resource_path)
    write_new_json(manifest_path, manifest)
    validator = Path(__file__).resolve().with_name(
        "validate-farpane-host-v1-concurrency.py"
    )
    result = operations.run([
        sys.executable,
        str(validator),
        str(manifest_path),
        str(result_path),
    ], timeout=30.0)
    if result.returncode != 0:
        raise CaptureError(
            "V1 concurrency validator did not produce a passing result"
        )
    result_raw = strict_json(
        read_resource(result_path), "V1 concurrency result"
    )
    if (
        result_raw.get("schema") != "farpane-host-v1-concurrency-result"
        or result_raw.get("schemaVersion") != 1
        or result_raw.get("status") != "pass"
    ):
        raise CaptureError("V1 concurrency result is not an exact pass")
    return result_path


def main() -> int:
    if len(sys.argv) < 2:
        usage()
        return 2
    command = sys.argv[1]
    operations = SystemOperations()
    try:
        if command == "start" and len(sys.argv) == 4:
            receipt = start_capture(
                Path(sys.argv[2]), sys.argv[3], operations
            )
            print(
                f"status={receipt['status']} scenario={receipt['scenario']} "
                f"agent_pid={receipt['agent']['pid']} "
                f"app_pid={receipt['applications'][0]['pid']}"
            )
            return 0
        if command == "restart-app" and len(sys.argv) == 3:
            receipt = restart_application(Path(sys.argv[2]), operations)
            print(
                f"status={receipt['status']} scenario={receipt['scenario']} "
                f"app_pid={receipt['applications'][-1]['pid']}"
            )
            return 0
        if command == "finish" and len(sys.argv) == 4:
            receipt = finish_capture(
                Path(sys.argv[2]), sys.argv[3], operations
            )
            print(f"status={receipt['status']} scenario={receipt['scenario']}")
            return 0
        if command == "finalize" and len(sys.argv) == 4:
            result = finalize_matrix(
                Path(sys.argv[2]), Path(sys.argv[3]), operations
            )
            print(f"status=pass result={result}")
            return 0
        usage()
        return 2
    except CaptureError as error:
        print(f"V1 concurrency capture refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
