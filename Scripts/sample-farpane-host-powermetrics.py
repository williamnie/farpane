#!/usr/bin/env python3
"""Capture bounded raw powermetrics plist evidence without parsing its schema."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import platform
import re
import resource
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


SCHEMA = "farpane-host-powermetrics-raw-capture"
SCHEMA_VERSION = 1
SCENARIOS = ("battery-idle", "battery-active")
SAMPLE_MODES = ("acceptance", "smoke")
SAMPLERS = ("battery", "cpu_power", "thermal")
SAMPLE_INTERVAL_MILLISECONDS = 1_000
MINIMUM_ACCEPTANCE_SECONDS = 600
MAXIMUM_ACCEPTANCE_SECONDS = 1_800
MAXIMUM_SMOKE_SECONDS = 60
MAXIMUM_RAW_BYTES = 256 * 1024 * 1024
MAXIMUM_STDERR_BYTES = 65_536
MAXIMUM_OUTPUT_NAME_BYTES = 240
POWERMETRICS_PATH = Path("/usr/bin/powermetrics")
PMSET_PATH = Path("/usr/bin/pmset")
PROC_PIDPATHINFO_MAXSIZE = 4_096
ALLOWED_HOST_PROCESS_NAMES = ("FarPane", "RustDeskNative")


class CaptureError(RuntimeError):
    pass


@dataclass(frozen=True)
class CaptureRequest:
    scenario: str
    duration_seconds: int
    output_prefix: Path
    host_pid: int
    sample_mode: str


@dataclass(frozen=True)
class ExecutableIdentity:
    process_name: str
    sha256: str
    device: int
    inode: int
    size: int
    modified_nanoseconds: int


@dataclass(frozen=True)
class RawSummary:
    sha256: str
    byte_count: int
    nul_delimiter_count: int


def usage() -> None:
    print(
        "usage: sample-farpane-host-powermetrics.py "
        "SCENARIO DURATION OUTPUT_PREFIX HOST_PID",
        file=sys.stderr,
    )


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_positive_decimal(value: str) -> bool:
    return bool(re.fullmatch(r"[1-9][0-9]*", value))


def has_control_character(value: str) -> bool:
    return any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)


def has_symlink_component(path: Path) -> bool:
    if not path.is_absolute():
        return True
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        if current.is_symlink():
            return True
    return False


def validate_output_prefix(value: str) -> Path:
    if not value or value != value.strip() or has_control_character(value):
        raise CaptureError("output prefix is empty or malformed")
    prefix = Path(value)
    if not prefix.is_absolute():
        raise CaptureError("output prefix must be absolute")
    if not prefix.name or prefix.name in (".", ".."):
        raise CaptureError("output prefix must name one evidence artifact")
    if len(prefix.name.encode("utf-8")) > MAXIMUM_OUTPUT_NAME_BYTES:
        raise CaptureError("output prefix filename is too long")
    parent = prefix.parent
    if has_symlink_component(parent):
        raise CaptureError("output prefix parent contains a symlink")
    if not parent.is_dir():
        raise CaptureError("output prefix parent must already exist")
    try:
        parent_metadata = parent.stat()
    except OSError as error:
        raise CaptureError("output prefix parent is unreadable") from error
    allowed_owners = {os.geteuid()}
    sudo_uid = os.environ.get("SUDO_UID")
    if sudo_uid is not None and sudo_uid.isdecimal():
        allowed_owners.add(int(sudo_uid))
    if parent_metadata.st_uid not in allowed_owners:
        raise CaptureError("output prefix parent is not owned by root or the operator")
    if parent_metadata.st_mode & 0o022:
        raise CaptureError("output prefix parent must not be group/world writable")
    return prefix


def validate_request(
    scenario: str,
    duration_text: str,
    output_prefix_text: str,
    host_pid_text: str,
    sample_mode: str,
) -> CaptureRequest:
    if scenario not in SCENARIOS:
        raise CaptureError("scenario must be battery-idle or battery-active")
    if sample_mode not in SAMPLE_MODES:
        raise CaptureError("FARPANE_HOST_POWER_SAMPLE_MODE must be acceptance or smoke")
    if not is_positive_decimal(duration_text):
        raise CaptureError("duration must be a positive integer number of seconds")
    duration = int(duration_text)
    if sample_mode == "acceptance":
        if not MINIMUM_ACCEPTANCE_SECONDS <= duration <= MAXIMUM_ACCEPTANCE_SECONDS:
            raise CaptureError("acceptance duration must be between 600 and 1800 seconds")
    elif duration > MAXIMUM_SMOKE_SECONDS:
        raise CaptureError("smoke duration must be between 1 and 60 seconds")
    if not is_positive_decimal(host_pid_text) or int(host_pid_text) <= 1:
        raise CaptureError("HOST_PID must be a process ID greater than 1")
    return CaptureRequest(
        scenario=scenario,
        duration_seconds=duration,
        output_prefix=validate_output_prefix(output_prefix_text),
        host_pid=int(host_pid_text),
        sample_mode=sample_mode,
    )


def require_superuser(effective_uid: int) -> None:
    if effective_uid != 0:
        raise CaptureError(
            "powermetrics capture must already be running as root; "
            "this wrapper never invokes sudo"
        )


def resolve_pid_executable(pid: int) -> Path:
    if platform.system() != "Darwin":
        raise CaptureError("powermetrics capture is supported only on macOS")
    try:
        os.kill(pid, 0)
    except OSError as error:
        raise CaptureError("Host process is not running") from error
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError as error:
        raise CaptureError("cannot load macOS process identity authority") from error
    proc_pidpath = libproc.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        raise CaptureError("cannot resolve Host executable for the exact PID")
    try:
        value = buffer.raw[:length].split(b"\0", 1)[0].decode("utf-8")
    except UnicodeError as error:
        raise CaptureError("Host executable path is not valid UTF-8") from error
    path = Path(value)
    if (
        not path.is_absolute()
        or path.is_symlink()
        or has_symlink_component(path.parent)
    ):
        raise CaptureError("Host executable path is not an absolute regular path")
    return path


def hash_open_executable(path: Path) -> ExecutableIdentity:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CaptureError("Host executable is missing or cannot be opened safely") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise CaptureError("Host executable is not a single-link regular file")
        process_name = path.name
        if process_name not in ALLOWED_HOST_PROCESS_NAMES:
            raise CaptureError("exact PID is not a FarPane Host process")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        return ExecutableIdentity(
            process_name=process_name,
            sha256=digest.hexdigest(),
            device=metadata.st_dev,
            inode=metadata.st_ino,
            size=metadata.st_size,
            modified_nanoseconds=metadata.st_mtime_ns,
        )
    finally:
        os.close(descriptor)


def require_same_executable(before: ExecutableIdentity, after: ExecutableIdentity) -> None:
    if before != after:
        raise CaptureError("Host executable identity changed during powermetrics capture")


def battery_power_is_active(
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> bool:
    try:
        completed = runner(
            [str(PMSET_PATH), "-g", "batt"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0 and bool(
        re.search(r"drawing from ['\"]Battery Power['\"]", completed.stdout)
    )


def output_paths(prefix: Path) -> tuple[Path, Path]:
    return (
        prefix.with_name(prefix.name + ".powermetrics.pliststream"),
        prefix.with_name(prefix.name + ".powermetrics.json"),
    )


def require_outputs_absent(raw_path: Path, metadata_path: Path) -> None:
    if raw_path.exists() or raw_path.is_symlink():
        raise CaptureError(f"refusing to overwrite existing artifact: {raw_path}")
    if metadata_path.exists() or metadata_path.is_symlink():
        raise CaptureError(f"refusing to overwrite existing artifact: {metadata_path}")


def build_powermetrics_command(
    request: CaptureRequest,
    executable: Path = POWERMETRICS_PATH,
) -> list[str]:
    return [
        str(executable),
        "--sample-count",
        str(request.duration_seconds),
        "--sample-rate",
        str(SAMPLE_INTERVAL_MILLISECONDS),
        "--samplers",
        ",".join(SAMPLERS),
        "--format",
        "plist",
        "--buffer-size",
        "1",
    ]


def child_file_size_limit() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAXIMUM_RAW_BYTES, MAXIMUM_RAW_BYTES))


def run_powermetrics(
    command: list[str],
    raw_temporary_path: Path,
    stderr_temporary_path: Path,
    timeout_seconds: int,
    preexec_fn: Callable[[], None] | None = child_file_size_limit,
) -> int:
    try:
        with raw_temporary_path.open("wb") as raw_output, stderr_temporary_path.open(
            "wb"
        ) as error_output:
            completed = subprocess.run(
                command,
                check=False,
                stdout=raw_output,
                stderr=error_output,
                timeout=timeout_seconds,
                preexec_fn=preexec_fn,
            )
            raw_output.flush()
            os.fsync(raw_output.fileno())
            error_output.flush()
            os.fsync(error_output.fileno())
            return completed.returncode
    except subprocess.TimeoutExpired as error:
        raise CaptureError("powermetrics exceeded the bounded capture timeout") from error
    except OSError as error:
        raise CaptureError("powermetrics could not be executed") from error


def summarize_raw(path: Path, requested_sample_count: int) -> RawSummary:
    try:
        metadata = path.stat()
    except OSError as error:
        raise CaptureError("powermetrics raw output is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size <= 0
        or metadata.st_size > MAXIMUM_RAW_BYTES
    ):
        raise CaptureError("powermetrics raw output size is outside the accepted bound")
    digest = hashlib.sha256()
    byte_count = 0
    nul_count = 0
    try:
        with path.open("rb") as raw_input:
            while True:
                chunk = raw_input.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                byte_count += len(chunk)
                nul_count += chunk.count(b"\0")
    except OSError as error:
        raise CaptureError("powermetrics raw output is unreadable") from error
    if requested_sample_count > 1 and nul_count == 0:
        raise CaptureError("powermetrics raw output is not a NUL-separated plist stream")
    if nul_count > requested_sample_count + 32:
        raise CaptureError("powermetrics raw record delimiter count exceeds the bound")
    return RawSummary(
        sha256=digest.hexdigest(),
        byte_count=byte_count,
        nul_delimiter_count=nul_count,
    )


def bounded_stderr_size(path: Path) -> int:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise CaptureError("powermetrics stderr evidence is missing") from error
    if size > MAXIMUM_STDERR_BYTES:
        raise CaptureError("powermetrics stderr exceeded the accepted bound")
    return size


def write_json_temporary(parent: Path, document: dict[str, Any]) -> Path:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-powermetrics-metadata-", suffix=".tmp", dir=parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o644)
        return temporary_path
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def publish_pair_no_replace(
    raw_temporary_path: Path,
    raw_path: Path,
    metadata: dict[str, Any],
    metadata_path: Path,
) -> None:
    require_outputs_absent(raw_path, metadata_path)
    metadata_temporary_path = write_json_temporary(metadata_path.parent, metadata)
    raw_published = False
    try:
        os.chmod(raw_temporary_path, 0o644)
        os.link(raw_temporary_path, raw_path)
        raw_published = True
        os.link(metadata_temporary_path, metadata_path)
    except OSError as error:
        if raw_published:
            try:
                published = raw_path.stat()
                temporary = raw_temporary_path.stat()
                if (published.st_dev, published.st_ino) == (
                    temporary.st_dev,
                    temporary.st_ino,
                ):
                    raw_path.unlink()
            except OSError:
                pass
        raise CaptureError("failed to publish powermetrics evidence atomically") from error
    finally:
        metadata_temporary_path.unlink(missing_ok=True)


def system_identity() -> dict[str, str]:
    def checked_output(command: list[str]) -> str:
        try:
            return subprocess.check_output(command, text=True, timeout=10).strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise CaptureError("cannot resolve machine identity") from error

    return {
        "machineModel": checked_output(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "architecture": platform.machine(),
        "macOSVersion": checked_output(["/usr/bin/sw_vers", "-productVersion"]),
    }


def build_metadata(
    request: CaptureRequest,
    executable: ExecutableIdentity,
    raw_path: Path,
    raw: RawSummary,
    started_at: str,
    completed_at: str,
    wall_duration_seconds: float,
    stderr_byte_count: int,
    machine: dict[str, str],
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "schemaVersion": SCHEMA_VERSION,
        "scenario": request.scenario,
        "sampleMode": request.sample_mode,
        "requestedDurationSeconds": request.duration_seconds,
        "requestedSampleCount": request.duration_seconds,
        "sampleIntervalMilliseconds": SAMPLE_INTERVAL_MILLISECONDS,
        "samplers": list(SAMPLERS),
        "authority": {
            "executable": str(POWERMETRICS_PATH),
            "format": "nul-separated-plist",
            "comparisonScope": "same-portable-machine-only",
            "privilege": "operator-explicit-superuser-acceptance-only",
            "wrapperInvokesSudo": False,
        },
        "machine": machine,
        "host": {
            "pid": request.host_pid,
            "processName": executable.process_name,
            "executableSHA256": executable.sha256,
        },
        "capture": {
            "startedAt": started_at,
            "completedAt": completed_at,
            "wallDurationSeconds": round(wall_duration_seconds, 3),
            "powermetricsExitStatus": 0,
            "batteryPowerAtStart": True,
            "batteryPowerAtEnd": True,
            "stderrByteCount": stderr_byte_count,
        },
        "rawArtifact": {
            "path": raw_path.name,
            "sha256": raw.sha256,
            "byteCount": raw.byte_count,
            "nulDelimiterCount": raw.nul_delimiter_count,
        },
        "claims": {
            "rawSourceParsed": False,
            "batterySourceThroughoutProven": False,
            "physicalEnergyThresholdEvaluated": False,
            "thermalResponseEvaluated": False,
            "section15_2Item9Complete": False,
        },
    }


def capture(request: CaptureRequest) -> tuple[Path, Path]:
    require_superuser(os.geteuid())
    if not POWERMETRICS_PATH.is_file() or not os.access(POWERMETRICS_PATH, os.X_OK):
        raise CaptureError("/usr/bin/powermetrics is unavailable")
    raw_path, metadata_path = output_paths(request.output_prefix)
    require_outputs_absent(raw_path, metadata_path)
    executable_path = resolve_pid_executable(request.host_pid)
    executable_before = hash_open_executable(executable_path)
    if not battery_power_is_active():
        raise CaptureError("battery power must be active before capture starts")
    machine = system_identity()

    raw_descriptor, raw_temporary_name = tempfile.mkstemp(
        prefix=".farpane-powermetrics-raw-",
        suffix=".partial",
        dir=raw_path.parent,
    )
    os.close(raw_descriptor)
    raw_temporary_path = Path(raw_temporary_name)
    error_descriptor, error_temporary_name = tempfile.mkstemp(
        prefix=".farpane-powermetrics-stderr-",
        suffix=".partial",
        dir=raw_path.parent,
    )
    os.close(error_descriptor)
    stderr_temporary_path = Path(error_temporary_name)
    started_at = utc_now()
    started_monotonic = time.monotonic()
    try:
        status = run_powermetrics(
            build_powermetrics_command(request),
            raw_temporary_path,
            stderr_temporary_path,
            timeout_seconds=request.duration_seconds + 60,
        )
        wall_duration = time.monotonic() - started_monotonic
        completed_at = utc_now()
        stderr_size = bounded_stderr_size(stderr_temporary_path)
        if status != 0:
            raise CaptureError(f"powermetrics failed with status {status}")
        if wall_duration < max(0, request.duration_seconds - 2):
            raise CaptureError("powermetrics did not cover the requested wall-clock window")
        if not battery_power_is_active():
            raise CaptureError("battery power was not active when capture completed")
        try:
            os.kill(request.host_pid, 0)
        except OSError as error:
            raise CaptureError("Host process exited during powermetrics capture") from error
        executable_after = hash_open_executable(resolve_pid_executable(request.host_pid))
        require_same_executable(executable_before, executable_after)
        raw = summarize_raw(raw_temporary_path, request.duration_seconds)
        metadata = build_metadata(
            request,
            executable_before,
            raw_path,
            raw,
            started_at,
            completed_at,
            wall_duration,
            stderr_size,
            machine,
        )
        publish_pair_no_replace(
            raw_temporary_path,
            raw_path,
            metadata,
            metadata_path,
        )
        return raw_path, metadata_path
    finally:
        raw_temporary_path.unlink(missing_ok=True)
        stderr_temporary_path.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 5:
        usage()
        return 2
    sample_mode = os.environ.get("FARPANE_HOST_POWER_SAMPLE_MODE", "acceptance")
    try:
        request = validate_request(
            sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sample_mode
        )
        raw_path, metadata_path = capture(request)
    except CaptureError as error:
        print(f"powermetrics capture refused: {error}", file=sys.stderr)
        return 2
    print(
        f"raw_powermetrics={raw_path} metadata={metadata_path} "
        "parsed=false section_15_2_item_9_complete=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
