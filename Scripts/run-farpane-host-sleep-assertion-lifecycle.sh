#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

# Capture one real FarPane Host assertion lifecycle:
#   ready with no Viewer -> active remote screen -> disconnected and ready.
#
# Launch the Host app with the matching route output before this runner:
#   FARPANE_HOST_TELEMETRY_OUTPUT="/absolute/prefix.route.json" \
#     /path/to/FarPane.app/Contents/MacOS/RustDeskNative
#
# Usage:
#   run-farpane-host-sleep-assertion-lifecycle.sh PHASE_SECONDS OUTPUT_PREFIX HOST_PID
#
# The default acceptance mode requires at least 10 seconds per stable phase.
# One-second local orchestration checks must explicitly use:
#   FARPANE_HOST_ASSERTION_MODE=smoke

if (( $# != 3 )); then
  print -u2 "usage: $0 PHASE_SECONDS OUTPUT_PREFIX HOST_PID"
  exit 2
fi

repo_dir=${0:A:h:h}
validator="$repo_dir/Scripts/validate-farpane-host-sleep-assertion-lifecycle.py"
phase_seconds=$1
prefix=${2:A}
host_pid=$3
sample_mode=${FARPANE_HOST_ASSERTION_MODE:-acceptance}
transition_timeout=${FARPANE_HOST_ASSERTION_TRANSITION_TIMEOUT_SECONDS:-180}
route_wait_seconds=${FARPANE_HOST_ASSERTION_ROUTE_WAIT_SECONDS:-180}
allow_non_farpane=${FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE:-0}

case "$sample_mode" in
  acceptance|smoke) ;;
  *) print -u2 "FARPANE_HOST_ASSERTION_MODE must be acceptance or smoke"; exit 2 ;;
esac
case "$allow_non_farpane" in
  0|1) ;;
  *) print -u2 "FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE must be 0 or 1"; exit 2 ;;
esac
if [[ "$allow_non_farpane" == 1 && "$sample_mode" != smoke ]]; then
  print -u2 "non-FarPane process sampling is permitted only in smoke mode"
  exit 2
fi
if [[ ! "$phase_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "PHASE_SECONDS must be a positive integer"
  exit 2
fi
if [[ "$sample_mode" == acceptance ]] && (( phase_seconds < 10 )); then
  print -u2 "acceptance requires PHASE_SECONDS >= 10; use smoke only for orchestration checks"
  exit 2
fi
for value_name in transition_timeout route_wait_seconds; do
  value=${(P)value_name}
  if [[ ! "$value" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "$value_name must be a positive integer"
    exit 2
  fi
done
if [[ ! "$host_pid" =~ '^[1-9][0-9]*$' ]] || (( host_pid <= 1 )); then
  print -u2 "HOST_PID must be a process ID greater than 1"
  exit 2
fi
if [[ ! -x "$validator" ]]; then
  print -u2 "lifecycle validator is not executable: $validator"
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

samples_csv="$prefix.sleep-assertions.samples.csv"
lifecycle_json="$prefix.sleep-assertions.json"
lifecycle_log="$prefix.sleep-assertions.log"
run_json="$prefix.sleep-assertions.run.json"
route_json="$prefix.route.json"
for artifact in "$samples_csv" "$lifecycle_json" "$lifecycle_log" "$run_json" "$route_json"; do
  if [[ -e "$artifact" ]]; then
    print -u2 "refusing to overwrite existing artifact: $artifact"
    exit 2
  fi
done
mkdir -p "${prefix:h}"

print 'elapsed_seconds,phase,host_sleep_assertion_count,host_user_idle_sleep_assertion_count,host_display_sleep_assertion_count,host_system_sleep_assertion_count' > "$samples_csv"
start_time=$EPOCHREALTIME
typeset -F 6 elapsed next_sample sleep_for
sample_count=0
last_total=0
last_user_idle=0
last_display=0
last_system_sleep=0

{
  print "runner=farpane-host-sleep-assertion-lifecycle mode=$sample_mode"
  print "host_process=$host_process_name host_pid=$host_pid phase_seconds=$phase_seconds"
  print "transition_timeout_seconds=$transition_timeout route_wait_seconds=$route_wait_seconds"
  print "route_evidence_required=$route_json"
} > "$lifecycle_log"

record_assertions() {
  local phase=$1
  local snapshot
  snapshot=$(pmset -g assertions 2>/dev/null || true)
  last_total=$(print -r -- "$snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) { count += 1 } END { print count + 0 }')
  last_user_idle=$(print -r -- "$snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) && index($0, "PreventUserIdleSystemSleep") { count += 1 } END { print count + 0 }')
  last_display=$(print -r -- "$snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) && index($0, "PreventUserIdleDisplaySleep") { count += 1 } END { print count + 0 }')
  last_system_sleep=$(print -r -- "$snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) && index($0, "PreventSystemSleep") { count += 1 } END { print count + 0 }')
  elapsed=$(( EPOCHREALTIME - start_time ))
  printf '%.3f,%s,%d,%d,%d,%d\n' \
    "$elapsed" "$phase" "$last_total" "$last_user_idle" "$last_display" "$last_system_sleep" >> "$samples_csv"
  sample_count=$(( sample_count + 1 ))
}

sample_phase() {
  local phase=$1
  local count=$2
  local index
  next_sample=$EPOCHREALTIME
  for (( index = 0; index < count; index += 1 )); do
    if ! kill -0 "$host_pid" 2>/dev/null; then
      print -u2 "Host process exited during phase=$phase"
      return 1
    fi
    record_assertions "$phase"
    next_sample=$(( next_sample + 1.0 ))
    sleep_for=$(( next_sample - EPOCHREALTIME ))
    if (( sleep_for > 0 && index + 1 < count )); then
      sleep "$sleep_for"
    elif (( sleep_for <= 0 )); then
      next_sample=$EPOCHREALTIME
    fi
  done
}

wait_for_active() {
  local index
  for (( index = 0; index < transition_timeout; index += 1 )); do
    record_assertions waiting-active
    if (( last_user_idle >= 1 )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_ready_after() {
  local index
  for (( index = 0; index < transition_timeout; index += 1 )); do
    record_assertions waiting-ready-after
    if (( last_user_idle == 0 && last_display == 0 && last_system_sleep == 0 )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

print "phase ready-before: keep Viewer disconnected for ${phase_seconds}s"
sample_phase ready-before "$phase_seconds"

print "connect FarPane Viewer now and wait until the Host picture is visible"
active_observed=false
ready_after_observed=false
if wait_for_active; then
  active_observed=true
  print "active assertion observed; keep Viewer connected for ${phase_seconds}s"
  sample_phase active "$phase_seconds"

  print "disconnect FarPane Viewer now"
  if wait_for_ready_after; then
    ready_after_observed=true
    print "assertions returned to zero; keep Viewer disconnected for ${phase_seconds}s"
    sample_phase ready-after "$phase_seconds"
  else
    print -u2 "timed out waiting for Host assertions to return to zero"
  fi
else
  print -u2 "timed out waiting for an active Host user-idle assertion"
fi

if [[ "$active_observed" == true && ! -e "$route_json" ]]; then
  print "waiting for production route-stop evidence: $route_json"
  for (( route_index = 0; route_index < route_wait_seconds; route_index += 1 )); do
    [[ -e "$route_json" ]] && break
    if ! kill -0 "$host_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
fi
route_evidence_observed=false
[[ -e "$route_json" ]] && route_evidence_observed=true

actual_duration=$(( EPOCHREALTIME - start_time ))
collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$lifecycle_json" <<EOF
{
  "schema": "farpane-host-sleep-assertion-lifecycle",
  "schemaVersion": 1,
  "sampleMode": "$sample_mode",
  "phaseSeconds": $phase_seconds,
  "transitionTimeoutSeconds": $transition_timeout,
  "routeWaitSeconds": $route_wait_seconds,
  "sampleCount": $sample_count,
  "actualDurationSeconds": $actual_duration,
  "hostProcessName": "$host_process_name",
  "activeObserved": $active_observed,
  "readyAfterObserved": $ready_after_observed,
  "routeEvidenceObserved": $route_evidence_observed,
  "assertionAuthority": "pmset-pid-and-type",
  "collectedAt": "$collected_at"
}
EOF

{
  print "sample_count=$sample_count actual_duration_seconds=$actual_duration"
  print "active_observed=$active_observed ready_after_observed=$ready_after_observed route_evidence_observed=$route_evidence_observed"
  print "artifacts=$samples_csv $lifecycle_json $run_json"
} >> "$lifecycle_log"

"$validator" "$phase_seconds" "$lifecycle_json" "$samples_csv" "$route_json" "$run_json"
