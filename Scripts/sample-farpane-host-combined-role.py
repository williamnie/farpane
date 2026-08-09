#!/usr/bin/env python3
"""Sample exact HostAgent and Viewer processes for §15.2 item 10 evidence."""

from __future__ import annotations

import csv
import ctypes
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, TextIO


SCHEMA = "farpane-host-combined-role-system-sample"
SCHEMA_VERSION = 1
SCENARIOS = ("host-ready-viewer", "host-viewer-dual")
SAMPLE_MODES = ("acceptance", "smoke")
MINIMUM_ACCEPTANCE_SECONDS = 600
MAXIMUM_ACCEPTANCE_SECONDS = 1_800
MAXIMUM_SMOKE_SECONDS = 60
MAXIMUM_OUTPUT_NAME_BYTES = 240
MAXIMUM_ARGUMENT_BYTES = 1_048_576
MAXIMUM_PLIST_BYTES = 1_048_576
PROC_PIDPATHINFO_MAXSIZE = 4_096
CTL_KERN = 1
KERN_PROCARGS2 = 49
HOST_AGENT_FLAG = "--host-agent"
ALLOWED_PROCESS_NAMES = ("FarPane", "RustDeskNative")

PS_PATH = Path("/bin/ps")
PGREP_PATH = Path("/usr/bin/pgrep")
TOP_PATH = Path("/usr/bin/top")
MEMORY_PRESSURE_PATH = Path("/usr/bin/memory_pressure")
PMSET_PATH = Path("/usr/bin/pmset")
SYSCTL_PATH = Path("/usr/sbin/sysctl")
SW_VERS_PATH = Path("/usr/bin/sw_vers")

CSV_HEADER = (
    "elapsed_seconds",
    "monotonic_nanoseconds",
    "scenario",
    "host_agent_pid",
    "host_agent_cpu_percent",
    "host_agent_rss_kb",
    "host_agent_threads",
    "host_agent_energy_impact",
    "viewer_pid",
    "viewer_cpu_percent",
    "viewer_rss_kb",
    "viewer_threads",
    "viewer_energy_impact",
    "farpane_combined_cpu_percent",
    "farpane_combined_rss_kb",
    "farpane_combined_threads",
    "farpane_combined_energy_impact",
    "windowserver_cpu_percent",
    "windowserver_rss_kb",
    "windowserver_threads",
    "windowserver_energy_impact",
    "videotoolboxd_cpu_percent",
    "videotoolboxd_rss_kb",
    "videotoolboxd_threads",
    "videotoolboxd_energy_impact",
    "vt_encoder_xpc_cpu_percent",
    "vt_encoder_xpc_rss_kb",
    "vt_encoder_xpc_threads",
    "vt_encoder_xpc_energy_impact",
    "system_cpu_user_percent",
    "system_cpu_sys_percent",
    "system_cpu_idle_percent",
    "memory_free_percent",
    "thermal_pressure",
    "power_source",
    "host_agent_sleep_assertion_count",
    "host_agent_user_idle_sleep_assertion_count",
    "host_agent_display_sleep_assertion_count",
    "viewer_sleep_assertion_count",
    "viewer_user_idle_sleep_assertion_count",
    "viewer_display_sleep_assertion_count",
)


class SampleError(RuntimeError):
    pass


@dataclass(frozen=True)
class SampleRequest:
    scenario: str
    duration_seconds: int
    output_prefix: Path
    host_agent_pid: int
    viewer_pid: int
    sample_mode: str


@dataclass(frozen=True)
class ExecutableIdentity:
    path: Path
    process_name: str
    sha256: str
    device: int
    inode: int
    size: int
    modified_nanoseconds: int


@dataclass(frozen=True)
class BundleIdentity:
    bundle_identifier: str
    build_identifier: str
    short_version: str


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    role: str
    executable: ExecutableIdentity
    bundle: BundleIdentity
    start_marker: str
    arguments_sha256: str
    host_agent_flag_count: int


@dataclass(frozen=True)
class RuntimeProcessSnapshot:
    pid: int
    executable_path: Path
    start_marker: str
    arguments_sha256: str
    host_agent_flag_count: int


@dataclass(frozen=True)
class ProcessStats:
    cpu_percent: float
    rss_kb: int
    threads: int


@dataclass(frozen=True)
class AssertionCounts:
    total: int
    user_idle_system_sleep: int
    user_idle_display_sleep: int


def usage() -> None:
    print(
        "usage: sample-farpane-host-combined-role.py "
        "SCENARIO DURATION OUTPUT_PREFIX HOST_AGENT_PID VIEWER_PID",
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
        current /= component
        if current.is_symlink():
            return True
    return False


def validate_output_prefix(value: str) -> Path:
    if not value or value != value.strip() or has_control_character(value):
        raise SampleError("output prefix is empty or malformed")
    prefix = Path(value)
    if not prefix.is_absolute():
        raise SampleError("output prefix must be absolute")
    if not prefix.name or prefix.name in (".", ".."):
        raise SampleError("output prefix must name one evidence artifact")
    if len(prefix.name.encode("utf-8")) > MAXIMUM_OUTPUT_NAME_BYTES:
        raise SampleError("output prefix filename is too long")
    parent = prefix.parent
    if has_symlink_component(parent):
        raise SampleError("output prefix parent contains a symlink")
    if not parent.is_dir():
        raise SampleError("output prefix parent must already exist")
    try:
        parent_metadata = parent.stat()
    except OSError as error:
        raise SampleError("output prefix parent is unreadable") from error
    if parent_metadata.st_uid != os.geteuid():
        raise SampleError("output prefix parent is not owned by the operator")
    if parent_metadata.st_mode & 0o022:
        raise SampleError("output prefix parent must not be group/world writable")
    return prefix


def validate_request(
    scenario: str,
    duration_text: str,
    output_prefix_text: str,
    host_agent_pid_text: str,
    viewer_pid_text: str,
    sample_mode: str,
) -> SampleRequest:
    if scenario not in SCENARIOS:
        raise SampleError("scenario must be host-ready-viewer or host-viewer-dual")
    if sample_mode not in SAMPLE_MODES:
        raise SampleError(
            "FARPANE_HOST_COMBINED_SAMPLE_MODE must be acceptance or smoke"
        )
    if not is_positive_decimal(duration_text):
        raise SampleError("duration must be a positive integer number of seconds")
    duration = int(duration_text)
    if sample_mode == "acceptance":
        if not MINIMUM_ACCEPTANCE_SECONDS <= duration <= MAXIMUM_ACCEPTANCE_SECONDS:
            raise SampleError("acceptance duration must be between 600 and 1800 seconds")
    elif duration > MAXIMUM_SMOKE_SECONDS:
        raise SampleError("smoke duration must be between 1 and 60 seconds")
    if not is_positive_decimal(host_agent_pid_text) or int(host_agent_pid_text) <= 1:
        raise SampleError("HOST_AGENT_PID must be a process ID greater than 1")
    if not is_positive_decimal(viewer_pid_text) or int(viewer_pid_text) <= 1:
        raise SampleError("VIEWER_PID must be a process ID greater than 1")
    host_agent_pid = int(host_agent_pid_text)
    viewer_pid = int(viewer_pid_text)
    if host_agent_pid == viewer_pid:
        raise SampleError("HOST_AGENT_PID and VIEWER_PID must be distinct")
    return SampleRequest(
        scenario=scenario,
        duration_seconds=duration,
        output_prefix=validate_output_prefix(output_prefix_text),
        host_agent_pid=host_agent_pid,
        viewer_pid=viewer_pid,
        sample_mode=sample_mode,
    )


def resolve_pid_executable(pid: int) -> Path:
    if platform.system() != "Darwin":
        raise SampleError("combined-role sampling is supported only on macOS")
    try:
        os.kill(pid, 0)
    except OSError as error:
        raise SampleError(f"process is not running: pid={pid}") from error
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError as error:
        raise SampleError("cannot load macOS process identity authority") from error
    proc_pidpath = libproc.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        raise SampleError(f"cannot resolve executable for exact pid={pid}")
    try:
        value = buffer.raw[:length].split(b"\0", 1)[0].decode("utf-8")
    except UnicodeError as error:
        raise SampleError("process executable path is not valid UTF-8") from error
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or has_symlink_component(path.parent):
        raise SampleError("process executable path is not an absolute regular path")
    return path


def parse_kern_procargs2(raw: bytes) -> tuple[str, ...]:
    if len(raw) < 5 or len(raw) > MAXIMUM_ARGUMENT_BYTES:
        raise SampleError("process argument evidence size is outside the accepted bound")
    argument_count = struct.unpack_from("=i", raw, 0)[0]
    if argument_count <= 0 or argument_count > 4_096:
        raise SampleError("process argument count is outside the accepted bound")
    offset = struct.calcsize("=i")
    executable_end = raw.find(b"\0", offset)
    if executable_end <= offset:
        raise SampleError("process argument evidence has no executable path")
    offset = executable_end + 1
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    arguments: list[str] = []
    for _ in range(argument_count):
        end = raw.find(b"\0", offset)
        if end < offset:
            raise SampleError("process argument evidence is truncated")
        try:
            argument = raw[offset:end].decode("utf-8")
        except UnicodeError as error:
            raise SampleError("process argument is not valid UTF-8") from error
        if has_control_character(argument):
            raise SampleError("process argument contains a control character")
        arguments.append(argument)
        offset = end + 1
    return tuple(arguments)


def read_process_arguments(pid: int) -> tuple[str, ...]:
    if platform.system() != "Darwin":
        raise SampleError("process argument authority is supported only on macOS")
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError as error:
        raise SampleError("cannot load macOS process argument authority") from error
    sysctl = libc.sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    try:
        configured_argmax = int(os.sysconf("SC_ARG_MAX"))
    except (OSError, ValueError):
        configured_argmax = MAXIMUM_ARGUMENT_BYTES
    capacity = min(MAXIMUM_ARGUMENT_BYTES, max(4_096, configured_argmax))
    buffer = ctypes.create_string_buffer(capacity)
    size = ctypes.c_size_t(capacity)
    if sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        raise SampleError(f"cannot read arguments for exact pid={pid}")
    return parse_kern_procargs2(buffer.raw[: size.value])


def hash_arguments(arguments: Iterable[str]) -> str:
    digest = hashlib.sha256()
    for argument in arguments:
        digest.update(argument.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def checked_stdout(
    command: list[str],
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    error_message: str,
) -> str:
    try:
        completed = runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise SampleError(error_message) from error
    if completed.returncode != 0:
        raise SampleError(error_message)
    return completed.stdout.strip()


def read_start_marker(
    pid: int,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> str:
    marker = checked_stdout(
        [str(PS_PATH), "-p", str(pid), "-o", "lstart="],
        runner=runner,
        error_message=f"cannot resolve process start marker for pid={pid}",
    )
    marker = " ".join(marker.split())
    if not marker or len(marker) > 64 or has_control_character(marker):
        raise SampleError("process start marker is malformed")
    return marker


def hash_open_executable(path: Path) -> ExecutableIdentity:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SampleError("process executable cannot be opened safely") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SampleError("process executable is not a single-link regular file")
        if metadata.st_mode & 0o022:
            raise SampleError("process executable is group/world writable")
        process_name = path.name
        if process_name not in ALLOWED_PROCESS_NAMES:
            raise SampleError("exact PID is not a FarPane process")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        return ExecutableIdentity(
            path=path,
            process_name=process_name,
            sha256=digest.hexdigest(),
            device=metadata.st_dev,
            inode=metadata.st_ino,
            size=metadata.st_size,
            modified_nanoseconds=metadata.st_mtime_ns,
        )
    finally:
        os.close(descriptor)


def read_bundle_identity(executable: Path) -> BundleIdentity:
    if executable.parent.name != "MacOS" or executable.parent.parent.name != "Contents":
        raise SampleError("process executable is not inside an installed app bundle")
    info_path = executable.parent.parent / "Info.plist"
    if info_path.is_symlink() or has_symlink_component(info_path.parent):
        raise SampleError("app bundle Info.plist path contains a symlink")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(info_path, flags)
    except OSError as error:
        raise SampleError("app bundle Info.plist cannot be opened safely") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_size <= 0
            or metadata.st_size > MAXIMUM_PLIST_BYTES
            or metadata.st_mode & 0o022
        ):
            raise SampleError("app bundle Info.plist is outside the accepted bound")
        raw = bytearray()
        while len(raw) <= MAXIMUM_PLIST_BYTES:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            raw.extend(chunk)
    finally:
        os.close(descriptor)
    try:
        document = plistlib.loads(bytes(raw))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise SampleError("app bundle Info.plist is malformed") from error
    if not isinstance(document, dict):
        raise SampleError("app bundle Info.plist root is not a dictionary")
    values = {
        "bundle_identifier": document.get("CFBundleIdentifier"),
        "build_identifier": document.get("CFBundleVersion"),
        "short_version": document.get("CFBundleShortVersionString"),
        "bundle_executable": document.get("CFBundleExecutable"),
    }
    if values["bundle_executable"] != executable.name:
        raise SampleError("app bundle executable identity does not match the running process")
    for key in ("bundle_identifier", "build_identifier", "short_version"):
        value = values[key]
        if (
            not isinstance(value, str)
            or value != value.strip()
            or not value
            or len(value) > 128
            or has_control_character(value)
        ):
            raise SampleError(f"app bundle {key} is missing or malformed")
    return BundleIdentity(
        bundle_identifier=values["bundle_identifier"],
        build_identifier=values["build_identifier"],
        short_version=values["short_version"],
    )


def observe_runtime_process(
    pid: int,
    *,
    argument_reader: Callable[[int], tuple[str, ...]] = read_process_arguments,
    executable_resolver: Callable[[int], Path] = resolve_pid_executable,
    start_reader: Callable[[int], str] = read_start_marker,
) -> RuntimeProcessSnapshot:
    arguments = argument_reader(pid)
    return RuntimeProcessSnapshot(
        pid=pid,
        executable_path=executable_resolver(pid),
        start_marker=start_reader(pid),
        arguments_sha256=hash_arguments(arguments),
        host_agent_flag_count=arguments.count(HOST_AGENT_FLAG),
    )


def capture_process_identity(
    pid: int,
    role: str,
    *,
    runtime_observer: Callable[[int], RuntimeProcessSnapshot] = observe_runtime_process,
) -> ProcessIdentity:
    if role not in ("host-agent", "viewer"):
        raise SampleError("unknown FarPane process role")
    runtime = runtime_observer(pid)
    executable = hash_open_executable(runtime.executable_path)
    bundle = read_bundle_identity(runtime.executable_path)
    expected_flag_count = 1 if role == "host-agent" else 0
    if runtime.host_agent_flag_count != expected_flag_count:
        raise SampleError(f"pid={pid} does not have the exact {role} argument role")
    return ProcessIdentity(
        pid=pid,
        role=role,
        executable=executable,
        bundle=bundle,
        start_marker=runtime.start_marker,
        arguments_sha256=runtime.arguments_sha256,
        host_agent_flag_count=runtime.host_agent_flag_count,
    )


def validate_role_pair(host_agent: ProcessIdentity, viewer: ProcessIdentity) -> None:
    if host_agent.role != "host-agent" or viewer.role != "viewer":
        raise SampleError("FarPane process role ordering is invalid")
    if host_agent.pid == viewer.pid:
        raise SampleError("HostAgent and Viewer must use distinct PIDs")
    if host_agent.host_agent_flag_count != 1 or viewer.host_agent_flag_count != 0:
        raise SampleError("FarPane role flag evidence is invalid")
    if host_agent.executable.path != viewer.executable.path:
        raise SampleError("HostAgent and Viewer do not use the same executable path")
    if host_agent.executable.sha256 != viewer.executable.sha256:
        raise SampleError("HostAgent and Viewer executable SHA-256 differs")
    if host_agent.bundle != viewer.bundle:
        raise SampleError("HostAgent and Viewer app build identity differs")


def require_runtime_matches(
    identity: ProcessIdentity,
    snapshot: RuntimeProcessSnapshot,
) -> None:
    if (
        identity.pid != snapshot.pid
        or identity.executable.path != snapshot.executable_path
        or identity.start_marker != snapshot.start_marker
        or identity.arguments_sha256 != snapshot.arguments_sha256
        or identity.host_agent_flag_count != snapshot.host_agent_flag_count
    ):
        raise SampleError(f"{identity.role} process identity changed during sampling")


def require_process_identity_unchanged(
    before: ProcessIdentity,
    after: ProcessIdentity,
) -> None:
    if before != after:
        raise SampleError(f"{before.role} process identity changed during sampling")


def parse_process_stats(cpu_rss_text: str, thread_text: str) -> ProcessStats:
    fields = cpu_rss_text.split()
    if len(fields) != 2:
        raise SampleError("process CPU/RSS evidence is malformed")
    try:
        cpu = float(fields[0])
        rss = int(fields[1])
    except ValueError as error:
        raise SampleError("process CPU/RSS evidence is not numeric") from error
    threads = max(0, len([line for line in thread_text.splitlines()[1:] if line.strip()]))
    if not (0 <= cpu < 100_000) or rss <= 0 or threads <= 0:
        raise SampleError("process CPU/RSS/thread evidence is outside the accepted bound")
    return ProcessStats(cpu_percent=cpu, rss_kb=rss, threads=threads)


def collect_process_stats(
    pid: int,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> ProcessStats:
    cpu_rss = checked_stdout(
        [str(PS_PATH), "-p", str(pid), "-o", "%cpu=,rss="],
        runner=runner,
        error_message=f"cannot sample CPU/RSS for pid={pid}",
    )
    thread_rows = checked_stdout(
        [str(PS_PATH), "-M", "-p", str(pid)],
        runner=runner,
        error_message=f"cannot sample threads for pid={pid}",
    )
    return parse_process_stats(cpu_rss, thread_rows)


def aggregate_stats(values: Iterable[ProcessStats]) -> ProcessStats:
    rows = list(values)
    if not rows:
        return ProcessStats(0.0, 0, 0)
    return ProcessStats(
        round(sum(row.cpu_percent for row in rows), 3),
        sum(row.rss_kb for row in rows),
        sum(row.threads for row in rows),
    )


def list_named_pids(
    name: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[int, ...]:
    try:
        completed = runner(
            [str(PGREP_PATH), "-x", name],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ()
    if completed.returncode not in (0, 1):
        raise SampleError(f"cannot enumerate shared process {name}")
    pids: list[int] = []
    for line in completed.stdout.splitlines():
        value = line.strip()
        if not value:
            continue
        if not is_positive_decimal(value) or int(value) <= 1:
            raise SampleError(f"shared process {name} returned an invalid PID")
        pids.append(int(value))
    return tuple(sorted(set(pids)))


def parse_top_snapshot(text: str) -> tuple[dict[int, float], tuple[float, float, float]]:
    energies: dict[int, float] = {}
    system_cpu: tuple[float, float, float] | None = None
    for line in text.splitlines():
        cpu_match = re.search(
            r"CPU usage:\s*([0-9.]+)% user,\s*([0-9.]+)% sys,\s*([0-9.]+)% idle",
            line,
        )
        if cpu_match:
            system_cpu = tuple(float(value) for value in cpu_match.groups())  # type: ignore[assignment]
        fields = line.split()
        if len(fields) == 2 and fields[0].isdigit():
            try:
                value = float(fields[1])
            except ValueError:
                continue
            if value >= 0:
                energies[int(fields[0])] = value
    if system_cpu is None:
        raise SampleError("top output has no system CPU authority")
    return energies, system_cpu


def collect_top_snapshot(
    pids: Iterable[int],
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[dict[int, float], tuple[float, float, float]]:
    command = [str(TOP_PATH), "-l", "2", "-s", "0"]
    for pid in sorted(set(pids)):
        command.extend(("-pid", str(pid)))
    command.extend(("-stats", "pid,power"))
    output = checked_stdout(
        command,
        runner=runner,
        error_message="cannot collect top CPU/relative-energy evidence",
    )
    return parse_top_snapshot(output)


def energy_value(energies: dict[int, float], pids: Iterable[int]) -> float | None:
    selected = tuple(pids)
    if not selected:
        return 0.0
    if any(pid not in energies for pid in selected):
        return None
    return round(sum(energies[pid] for pid in selected), 3)


def read_assertion_counts(text: str, pid: int) -> AssertionCounts:
    pattern = re.compile(rf"\bpid\s+{pid}\b")
    rows = [line for line in text.splitlines() if pattern.search(line)]
    return AssertionCounts(
        total=len(rows),
        user_idle_system_sleep=sum(
            "PreventUserIdleSystemSleep" in line for line in rows
        ),
        user_idle_display_sleep=sum(
            "PreventUserIdleDisplaySleep" in line for line in rows
        ),
    )


def parse_memory_free(text: str) -> float:
    match = re.search(r"System-wide memory free percentage:\s*([0-9.]+)%", text)
    if not match:
        raise SampleError("memory pressure output has no free percentage")
    value = float(match.group(1))
    if not 0 <= value <= 100:
        raise SampleError("memory free percentage is outside the accepted bound")
    return value


def parse_thermal(text: str) -> str:
    match = re.search(r"Thermal_Pressure_Level:\s*([^\n]+)", text)
    if not match:
        return "unknown"
    value = match.group(1).strip().lower()
    return value if re.fullmatch(r"[a-z0-9_-]{1,32}", value) else "unknown"


def parse_power_source(text: str) -> str:
    if re.search(r"drawing from ['\"]Battery Power['\"]", text):
        return "battery"
    if re.search(r"drawing from ['\"]AC Power['\"]", text):
        return "ac"
    return "unknown"


def format_energy(value: float | None) -> str:
    return "na" if value is None else f"{value:.3f}"


def output_paths(prefix: Path) -> tuple[Path, Path, Path]:
    return (
        prefix.with_name(prefix.name + ".samples.csv"),
        prefix.with_name(prefix.name + ".json"),
        prefix.with_name(prefix.name + ".log"),
    )


def require_outputs_absent(paths: Iterable[Path]) -> None:
    for path in paths:
        if path.exists() or path.is_symlink():
            raise SampleError(f"refusing to overwrite existing artifact: {path}")


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        raise SampleError("sample evidence cannot be hashed") from error
    return digest.hexdigest()


def write_json_temporary(parent: Path, document: dict[str, Any]) -> Path:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".farpane-combined-role-metadata-", suffix=".tmp", dir=parent
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


def publish_triplet_no_replace(
    csv_temporary: Path,
    csv_path: Path,
    metadata: dict[str, Any],
    metadata_path: Path,
    log_temporary: Path,
    log_path: Path,
) -> None:
    final_paths = (csv_path, metadata_path, log_path)
    require_outputs_absent(final_paths)
    metadata_temporary = write_json_temporary(metadata_path.parent, metadata)
    temporary_paths = (csv_temporary, metadata_temporary, log_temporary)
    published: list[tuple[Path, Path]] = []
    try:
        for temporary in temporary_paths:
            os.chmod(temporary, 0o644)
        for temporary, final in zip(temporary_paths, final_paths):
            os.link(temporary, final)
            published.append((temporary, final))
    except OSError as error:
        for temporary, final in reversed(published):
            try:
                temporary_metadata = temporary.stat()
                final_metadata = final.stat()
                if (temporary_metadata.st_dev, temporary_metadata.st_ino) == (
                    final_metadata.st_dev,
                    final_metadata.st_ino,
                ):
                    final.unlink()
            except OSError:
                pass
        raise SampleError("failed to publish combined-role evidence atomically") from error
    finally:
        metadata_temporary.unlink(missing_ok=True)


def system_identity() -> dict[str, str]:
    return {
        "machineModel": checked_stdout(
            [str(SYSCTL_PATH), "-n", "hw.model"],
            error_message="cannot resolve machine model",
        ),
        "architecture": platform.machine(),
        "macOSVersion": checked_stdout(
            [str(SW_VERS_PATH), "-productVersion"],
            error_message="cannot resolve macOS version",
        ),
    }


def public_process_identity(identity: ProcessIdentity) -> dict[str, Any]:
    return {
        "pid": identity.pid,
        "role": identity.role,
        "processName": identity.executable.process_name,
        "executableSHA256": identity.executable.sha256,
        "bundleIdentifier": identity.bundle.bundle_identifier,
        "buildIdentifier": identity.bundle.build_identifier,
        "shortVersion": identity.bundle.short_version,
        "startMarker": identity.start_marker,
        "argumentsSHA256": identity.arguments_sha256,
        "hostAgentFlagCount": identity.host_agent_flag_count,
    }


def build_metadata(
    request: SampleRequest,
    host_agent: ProcessIdentity,
    viewer: ProcessIdentity,
    machine: dict[str, str],
    started_at: str,
    completed_at: str,
    started_monotonic_nanoseconds: int,
    completed_monotonic_nanoseconds: int,
    sample_count: int,
    csv_path: Path,
    csv_sha256: str,
    log_path: Path,
    log_sha256: str,
    energy_impact_available: bool,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "schemaVersion": SCHEMA_VERSION,
        "scenario": request.scenario,
        "sampleMode": request.sample_mode,
        "requestedDurationSeconds": request.duration_seconds,
        "sampleCadenceTargetMilliseconds": 1_000,
        "sampleCount": sample_count,
        "completed": sample_count == request.duration_seconds,
        "window": {
            "startedAt": started_at,
            "completedAt": completed_at,
            "startedMonotonicNanoseconds": started_monotonic_nanoseconds,
            "completedMonotonicNanoseconds": completed_monotonic_nanoseconds,
            "monotonicDurationSeconds": round(
                (completed_monotonic_nanoseconds - started_monotonic_nanoseconds)
                / 1_000_000_000,
                3,
            ),
        },
        "machine": machine,
        "roles": {
            "hostAgent": public_process_identity(host_agent),
            "viewer": public_process_identity(viewer),
            "distinctPIDs": host_agent.pid != viewer.pid,
            "sameExecutablePath": host_agent.executable.path == viewer.executable.path,
            "sameExecutableSHA256": (
                host_agent.executable.sha256 == viewer.executable.sha256
            ),
            "sameBuildIdentifier": (
                host_agent.bundle.build_identifier
                == viewer.bundle.build_identifier
            ),
        },
        "resourceAuthority": {
            "roleProcessScope": "exact-pid-per-second",
            "combinedProcessScope": "host-agent-plus-viewer-only",
            "sharedSystemScope": [
                "WindowServer",
                "videotoolboxd",
                "VTEncoderXPCService",
            ],
            "sharedSystemScopeAssignedToRole": False,
            "energyImpactAvailable": energy_impact_available,
            "energyImpactUnit": "top-relative-not-joules",
        },
        "artifacts": {
            "samples": {"path": csv_path.name, "sha256": csv_sha256},
            "log": {"path": log_path.name, "sha256": log_sha256},
        },
        "claims": {
            "hostRuntimeStateBound": False,
            "viewerStreamingReportBound": False,
            "combinedBudgetThresholdEvaluated": False,
            "section15_2Item10Complete": False,
        },
    }


def run_checked_text(command: list[str]) -> str:
    return checked_stdout(command, error_message=f"command failed: {command[0]}")


def collect_shared_stats(pids: tuple[int, ...]) -> ProcessStats:
    rows: list[ProcessStats] = []
    for pid in pids:
        try:
            rows.append(collect_process_stats(pid))
        except SampleError:
            # Shared helpers may legitimately exit between pgrep and ps. Their
            # cost remains global/shared and must never invalidate either exact
            # FarPane role identity.
            continue
    return aggregate_stats(rows)


def sample_row(
    request: SampleRequest,
    host_agent: ProcessIdentity,
    viewer: ProcessIdentity,
    started_monotonic_nanoseconds: int,
) -> tuple[list[Any], bool]:
    host_runtime = observe_runtime_process(host_agent.pid)
    viewer_runtime = observe_runtime_process(viewer.pid)
    require_runtime_matches(host_agent, host_runtime)
    require_runtime_matches(viewer, viewer_runtime)

    shared = {
        "windowserver": list_named_pids("WindowServer"),
        "videotoolboxd": list_named_pids("videotoolboxd"),
        "vt_encoder_xpc": list_named_pids("VTEncoderXPCService"),
    }
    all_pids = (
        host_agent.pid,
        viewer.pid,
        *shared["windowserver"],
        *shared["videotoolboxd"],
        *shared["vt_encoder_xpc"],
    )
    energies, system_cpu = collect_top_snapshot(all_pids)
    host_stats = collect_process_stats(host_agent.pid)
    viewer_stats = collect_process_stats(viewer.pid)
    combined_stats = aggregate_stats((host_stats, viewer_stats))
    shared_stats = {
        name: collect_shared_stats(pids) for name, pids in shared.items()
    }

    host_energy = energy_value(energies, (host_agent.pid,))
    viewer_energy = energy_value(energies, (viewer.pid,))
    if host_energy is None or viewer_energy is None:
        energy_available = False
        combined_energy = None
    else:
        energy_available = True
        combined_energy = round(host_energy + viewer_energy, 3)
    shared_energy = {
        name: energy_value(energies, pids) for name, pids in shared.items()
    }

    memory_free = parse_memory_free(
        run_checked_text([str(MEMORY_PRESSURE_PATH), "-Q"])
    )
    thermal = parse_thermal(run_checked_text([str(PMSET_PATH), "-g", "therm"]))
    power_source = parse_power_source(
        run_checked_text([str(PMSET_PATH), "-g", "batt"])
    )
    assertion_text = run_checked_text([str(PMSET_PATH), "-g", "assertions"])
    host_assertions = read_assertion_counts(assertion_text, host_agent.pid)
    viewer_assertions = read_assertion_counts(assertion_text, viewer.pid)

    now_monotonic_nanoseconds = time.monotonic_ns()
    elapsed = (
        now_monotonic_nanoseconds - started_monotonic_nanoseconds
    ) / 1_000_000_000
    row: list[Any] = [
        f"{elapsed:.3f}",
        now_monotonic_nanoseconds,
        request.scenario,
        host_agent.pid,
        f"{host_stats.cpu_percent:.3f}",
        host_stats.rss_kb,
        host_stats.threads,
        format_energy(host_energy),
        viewer.pid,
        f"{viewer_stats.cpu_percent:.3f}",
        viewer_stats.rss_kb,
        viewer_stats.threads,
        format_energy(viewer_energy),
        f"{combined_stats.cpu_percent:.3f}",
        combined_stats.rss_kb,
        combined_stats.threads,
        format_energy(combined_energy),
    ]
    for name in ("windowserver", "videotoolboxd", "vt_encoder_xpc"):
        stats = shared_stats[name]
        row.extend((
            f"{stats.cpu_percent:.3f}",
            stats.rss_kb,
            stats.threads,
            format_energy(shared_energy[name]),
        ))
    row.extend((
        f"{system_cpu[0]:.3f}",
        f"{system_cpu[1]:.3f}",
        f"{system_cpu[2]:.3f}",
        f"{memory_free:.3f}",
        thermal,
        power_source,
        host_assertions.total,
        host_assertions.user_idle_system_sleep,
        host_assertions.user_idle_display_sleep,
        viewer_assertions.total,
        viewer_assertions.user_idle_system_sleep,
        viewer_assertions.user_idle_display_sleep,
    ))
    if len(row) != len(CSV_HEADER):
        raise SampleError("internal CSV column count is inconsistent")
    return row, energy_available


def create_text_temporary(parent: Path, prefix: str) -> tuple[Path, TextIO]:
    descriptor, temporary_name = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=parent)
    return Path(temporary_name), os.fdopen(descriptor, "w", encoding="utf-8", newline="")


def sample(request: SampleRequest) -> tuple[Path, Path, Path]:
    csv_path, metadata_path, log_path = output_paths(request.output_prefix)
    require_outputs_absent((csv_path, metadata_path, log_path))
    host_agent = capture_process_identity(request.host_agent_pid, "host-agent")
    viewer = capture_process_identity(request.viewer_pid, "viewer")
    validate_role_pair(host_agent, viewer)
    machine = system_identity()

    csv_temporary, csv_output = create_text_temporary(
        csv_path.parent, ".farpane-combined-role-samples-"
    )
    log_temporary, log_output = create_text_temporary(
        log_path.parent, ".farpane-combined-role-log-"
    )
    started_at = utc_now()
    started_monotonic_nanoseconds = time.monotonic_ns()
    sample_count = 0
    energy_impact_available = True
    try:
        writer = csv.writer(csv_output, lineterminator="\n")
        writer.writerow(CSV_HEADER)
        log_output.write(
            f"sampler={SCHEMA} scenario={request.scenario} "
            f"mode={request.sample_mode}\n"
        )
        log_output.write(
            f"host_agent_pid={host_agent.pid} viewer_pid={viewer.pid} "
            f"build={host_agent.bundle.build_identifier}\n"
        )
        log_output.write(
            "role_resources=exact-pid shared_resources=WindowServer,"
            "videotoolboxd,VTEncoderXPCService energy=top-relative-not-joules\n"
        )
        for sample_index in range(request.duration_seconds):
            row, sample_energy_available = sample_row(
                request,
                host_agent,
                viewer,
                started_monotonic_nanoseconds,
            )
            writer.writerow(row)
            csv_output.flush()
            sample_count += 1
            energy_impact_available = (
                energy_impact_available and sample_energy_available
            )
            target = started_monotonic_nanoseconds + (sample_index + 1) * 1_000_000_000
            remaining = (target - time.monotonic_ns()) / 1_000_000_000
            if remaining > 0:
                time.sleep(remaining)

        completed_monotonic_nanoseconds = time.monotonic_ns()
        completed_at = utc_now()
        if (
            completed_monotonic_nanoseconds - started_monotonic_nanoseconds
            < request.duration_seconds * 1_000_000_000
        ):
            raise SampleError("sampler did not cover the requested monotonic window")
        host_after = capture_process_identity(request.host_agent_pid, "host-agent")
        viewer_after = capture_process_identity(request.viewer_pid, "viewer")
        require_process_identity_unchanged(host_agent, host_after)
        require_process_identity_unchanged(viewer, viewer_after)
        validate_role_pair(host_after, viewer_after)
        log_output.write(
            f"sample_count={sample_count} completed=true "
            f"section_15_2_item_10_complete=false\n"
        )
        for output in (csv_output, log_output):
            output.flush()
            os.fsync(output.fileno())
            output.close()
        metadata = build_metadata(
            request,
            host_agent,
            viewer,
            machine,
            started_at,
            completed_at,
            started_monotonic_nanoseconds,
            completed_monotonic_nanoseconds,
            sample_count,
            csv_path,
            hash_file(csv_temporary),
            log_path,
            hash_file(log_temporary),
            energy_impact_available,
        )
        publish_triplet_no_replace(
            csv_temporary,
            csv_path,
            metadata,
            metadata_path,
            log_temporary,
            log_path,
        )
        return csv_path, metadata_path, log_path
    finally:
        if not csv_output.closed:
            csv_output.close()
        if not log_output.closed:
            log_output.close()
        csv_temporary.unlink(missing_ok=True)
        log_temporary.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 6:
        usage()
        return 2
    sample_mode = os.environ.get(
        "FARPANE_HOST_COMBINED_SAMPLE_MODE", "acceptance"
    )
    try:
        request = validate_request(
            sys.argv[1],
            sys.argv[2],
            sys.argv[3],
            sys.argv[4],
            sys.argv[5],
            sample_mode,
        )
        csv_path, metadata_path, log_path = sample(request)
    except SampleError as error:
        print(f"combined-role sampling refused: {error}", file=sys.stderr)
        return 2
    print(
        f"samples={csv_path} metadata={metadata_path} log={log_path} "
        "section_15_2_item_10_complete=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
