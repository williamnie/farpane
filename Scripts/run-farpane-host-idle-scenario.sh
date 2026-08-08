#!/bin/zsh
set -euo pipefail

# H2.4.7b Host-ready/no-screen-route idle performance runner.
#
# Launch the FarPane App first with a new absolute runtime-state output:
#   FARPANE_HOST_STATE_OUTPUT="/absolute/idle-source.jsonl" /path/to/RustDeskNative
# Wait until the App reports that Host is ready, and do not connect a Viewer.
#
# Usage:
#   run-farpane-host-idle-scenario.sh DURATION OUTPUT_PREFIX HOST_PID STATE_JSONL
#
# Acceptance requires at least 600 seconds. Short preflight runs must set:
#   FARPANE_HOST_IDLE_MODE=smoke

if (( $# != 4 )); then
  print -u2 "usage: $0 DURATION OUTPUT_PREFIX HOST_PID STATE_JSONL"
  exit 2
fi

repo_dir=${0:A:h:h}
sampler="$repo_dir/Scripts/sample-farpane-host-performance.sh"
validator="$repo_dir/Scripts/validate-farpane-host-idle.py"
scenario=host-ready-no-screen-route
duration=$1
prefix=${2:A}
host_pid=$3
state_source=$4
sample_mode=${FARPANE_HOST_IDLE_MODE:-acceptance}
allow_non_farpane=${FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE:-0}

case "$sample_mode" in
  acceptance|smoke) ;;
  *) print -u2 "FARPANE_HOST_IDLE_MODE must be acceptance or smoke"; exit 2 ;;
esac
case "$allow_non_farpane" in
  0|1) ;;
  *) print -u2 "FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE must be 0 or 1"; exit 2 ;;
esac
if [[ "$allow_non_farpane" == 1 && "$sample_mode" != smoke ]]; then
  print -u2 "non-FarPane process sampling is permitted only in smoke mode"
  exit 2
fi
if [[ ! "$duration" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "duration must be a positive integer number of seconds"
  exit 2
fi
if [[ "$sample_mode" == acceptance && duration -lt 600 ]]; then
  print -u2 "idle acceptance requires duration >= 600 seconds; use FARPANE_HOST_IDLE_MODE=smoke only for preflight"
  exit 2
fi
if [[ ! "$host_pid" =~ '^[1-9][0-9]*$' ]] || (( host_pid <= 1 )); then
  print -u2 "HOST_PID must be a process ID greater than 1"
  exit 2
fi
if [[ "$state_source" != /* || "${state_source:e:l}" != jsonl ]]; then
  print -u2 "STATE_JSONL must be an absolute .jsonl path"
  exit 2
fi
if [[ ! -f "$state_source" || ! -r "$state_source" ]]; then
  print -u2 "runtime-state source is missing or unreadable"
  exit 2
fi
if [[ ! -x "$sampler" || ! -x "$validator" ]]; then
  print -u2 "idle runner dependency is not executable"
  exit 2
fi
if ! kill -0 "$host_pid" 2>/dev/null; then
  print -u2 "Host process is not running: pid=$host_pid"
  exit 2
fi

host_command=$(ps -p "$host_pid" -o comm= 2>/dev/null | awk '{$1=$1; print}')
host_process_name=${host_command:t}
case "$host_process_name" in
  FarPane|RustDeskNative) ;;
  *)
    if [[ "$allow_non_farpane" != 1 ]]; then
      print -u2 "pid=$host_pid is '$host_process_name', not FarPane/RustDeskNative"
      exit 2
    fi
    ;;
esac

state_slice="$prefix.state.jsonl"
system_prefix="$prefix.system"
system_csv="$system_prefix.samples.csv"
system_json="$system_prefix.json"
system_log="$system_prefix.log"
run_json="$prefix.run.json"
for artifact in "$state_slice" "$system_csv" "$system_json" "$system_log" "$run_json"; do
  if [[ -e "$artifact" ]]; then
    print -u2 "refusing to overwrite existing artifact: $artifact"
    exit 2
  fi
done
if [[ "${state_source:A}" == "${state_slice:A}" ]]; then
  print -u2 "runtime-state source and bounded state artifact must differ"
  exit 2
fi
mkdir -p "${prefix:h}"

state_offset=$(stat -f %z "$state_source")
state_identity=$(stat -f '%d:%i' "$state_source")
window_start_unix_ms=$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')

print "scenario=$scenario mode=$sample_mode duration=${duration}s host_pid=$host_pid"
print "sampling starts now; keep Host enabled and ready, and do not connect a Viewer for the full window"

set +e
FARPANE_HOST_SAMPLE_MODE=$sample_mode \
FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE=$allow_non_farpane \
  "$sampler" "$scenario" "$duration" "$system_prefix" "$host_pid"
sampler_status=$?
set -e
window_end_unix_ms=$(python3 -c 'import time; print(time.time_ns() // 1_000_000)')
if (( sampler_status != 0 )); then
  print -u2 "system sampling failed with status=$sampler_status; preserving partial evidence"
fi

state_tmp=$(mktemp "${prefix:h}/.farpane-idle-state.XXXXXX")
state_slice_status=0
current_state_identity=$(stat -f '%d:%i' "$state_source" 2>/dev/null || true)
current_state_size=$(stat -f %z "$state_source" 2>/dev/null || print 0)
if [[ "$current_state_identity" != "$state_identity" || "$current_state_size" -lt "$state_offset" ]]; then
  print -u2 "runtime-state source was replaced or truncated during sampling"
  state_slice_status=1
else
  if ! tail -c +$(( state_offset + 1 )) "$state_source" > "$state_tmp"; then
    print -u2 "runtime-state source could not be sliced after sampling"
    state_slice_status=1
    : > "$state_tmp"
  fi
fi
if ! ln "$state_tmp" "$state_slice"; then
  rm -f "$state_tmp"
  print -u2 "failed to publish bounded runtime-state evidence"
  exit 2
fi
rm -f "$state_tmp"

set +e
"$validator" "$duration" "$state_slice" "$system_json" "$system_csv" \
  "$window_start_unix_ms" "$window_end_unix_ms" "$run_json"
validator_status=$?
set -e
if (( validator_status != 0 )); then
  exit "$validator_status"
fi
if (( sampler_status != 0 || state_slice_status != 0 )); then
  exit 1
fi
