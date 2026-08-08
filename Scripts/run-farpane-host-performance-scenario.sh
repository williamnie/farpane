#!/bin/zsh
set -euo pipefail

# H2.4 real-session active/static/stability performance runner.
#
# The FarPane app must already be running with this exact output configured:
#   FARPANE_HOST_TELEMETRY_OUTPUT="/absolute/prefix.route.json" /path/to/FarPane.app/Contents/MacOS/RustDeskNative
# Start this runner only after the remote Viewer is showing the Host picture.
# It samples the exact Host PID, then waits for the operator to disconnect so
# the production route-stop telemetry writer can publish the route evidence.
#
# Usage:
#   run-farpane-host-performance-scenario.sh SCENARIO DURATION OUTPUT_PREFIX HOST_PID
#
# SCENARIO is static-1080p30, static-4k30, 1080p30, 4k30-normal,
# 4k30-video, stability-1080p30, or stability-4k30. Acceptance runs require
# at least 600 seconds, or 1800 seconds for stability. Static profiles require
# the desktop to remain untouched; stability profiles require the target
# product workflow for the full sampling window. A short preflight must set:
#   FARPANE_HOST_SCENARIO_MODE=smoke

if (( $# != 4 )); then
  print -u2 "usage: $0 SCENARIO(static-1080p30|static-4k30|1080p30|4k30-normal|4k30-video|stability-1080p30|stability-4k30) DURATION OUTPUT_PREFIX HOST_PID"
  exit 2
fi

repo_dir=${0:A:h:h}
sampler="$repo_dir/Scripts/sample-farpane-host-performance.sh"
validator="$repo_dir/Scripts/validate-farpane-host-performance.py"
scenario=$1
duration=$2
prefix=${3:A}
host_pid=$4
sample_mode=${FARPANE_HOST_SCENARIO_MODE:-acceptance}
route_wait_seconds=${FARPANE_HOST_ROUTE_WAIT_SECONDS:-180}
allow_non_farpane=${FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE:-0}

case "$scenario" in
  static-1080p30|static-4k30|1080p30|4k30-normal|4k30-video|stability-1080p30|stability-4k30) ;;
  *)
    print -u2 "unknown scenario: $scenario"
    exit 2
    ;;
esac
case "$sample_mode" in
  acceptance|smoke) ;;
  *)
    print -u2 "FARPANE_HOST_SCENARIO_MODE must be acceptance or smoke"
    exit 2
    ;;
esac
case "$allow_non_farpane" in
  0|1) ;;
  *)
    print -u2 "FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE must be 0 or 1"
    exit 2
    ;;
esac
if [[ "$allow_non_farpane" == 1 && "$sample_mode" != smoke ]]; then
  print -u2 "non-FarPane process sampling is permitted only in smoke mode"
  exit 2
fi
if [[ ! "$duration" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "duration must be a positive integer number of seconds"
  exit 2
fi
if [[ "$sample_mode" == acceptance ]]; then
  minimum_duration=600
  [[ "$scenario" == stability-* ]] && minimum_duration=1800
  if (( duration < minimum_duration )); then
    print -u2 "$scenario acceptance requires duration >= $minimum_duration seconds; use FARPANE_HOST_SCENARIO_MODE=smoke only for preflight"
    exit 2
  fi
fi
if [[ ! "$route_wait_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "FARPANE_HOST_ROUTE_WAIT_SECONDS must be a positive integer"
  exit 2
fi
if [[ ! "$host_pid" =~ '^[1-9][0-9]*$' ]] || (( host_pid <= 1 )); then
  print -u2 "HOST_PID must be a process ID greater than 1"
  exit 2
fi
if [[ ! -x "$sampler" ]]; then
  print -u2 "system sampler is not executable: $sampler"
  exit 2
fi
if [[ ! -x "$validator" ]]; then
  print -u2 "performance validator is not executable: $validator"
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

route_json="$prefix.route.json"
system_prefix="$prefix.system"
system_csv="$system_prefix.samples.csv"
system_json="$system_prefix.json"
system_log="$system_prefix.log"
run_json="$prefix.run.json"
for artifact in "$route_json" "$system_csv" "$system_json" "$system_log" "$run_json"; do
  if [[ -e "$artifact" ]]; then
    print -u2 "refusing to overwrite existing artifact: $artifact"
    exit 2
  fi
done
mkdir -p "${prefix:h}"

print "scenario=$scenario mode=$sample_mode duration=${duration}s host_pid=$host_pid"
print "expected_route_evidence=$route_json"
case "$scenario" in
  static-*)
    print "sampling starts now; keep the remote FarPane session connected and the Host desktop untouched for the full window"
    ;;
  stability-*)
    print "sampling starts now; keep the remote FarPane session connected and repeat the target product workflow for the full window"
    ;;
  *)
    print "sampling starts now; keep the remote FarPane session connected for the full window"
    ;;
esac

set +e
FARPANE_HOST_SAMPLE_MODE=$sample_mode \
FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE=$allow_non_farpane \
  "$sampler" "$scenario" "$duration" "$system_prefix" "$host_pid"
sampler_status=$?
set -e
if (( sampler_status != 0 )); then
  print -u2 "system sampling failed with status=$sampler_status; preserving partial evidence"
fi

if (( sampler_status == 0 )) && [[ ! -e "$route_json" ]]; then
  print "system sampling finished; disconnect the remote Viewer so route-stop telemetry is written"
  for (( wait_index = 0; wait_index < route_wait_seconds; wait_index += 1 )); do
    [[ -e "$route_json" ]] && break
    if ! kill -0 "$host_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
fi

set +e
"$validator" "$scenario" "$duration" "$route_json" "$system_json" "$system_csv" "$run_json"
validator_status=$?
set -e
if (( validator_status != 0 )); then
  exit "$validator_status"
fi
if (( sampler_status != 0 )); then
  exit 1
fi
