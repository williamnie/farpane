#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

# H2 system-side sampler for a running FarPane Host session.
#
# Usage:
#   sample-farpane-host-performance.sh SCENARIO DURATION OUTPUT_PREFIX HOST_PID
#
# The caller must pass the exact Host PID. This intentionally avoids selecting
# an arbitrary FarPane process when Host and Viewer are both running.
#
# A qualifying run is 600 seconds, or 1800 seconds for a `stability-*`
# profile. Short runs are available only as explicit smoke tests:
#   FARPANE_HOST_SAMPLE_MODE=smoke ...

if (( $# != 4 )); then
  print -u2 "usage: $0 SCENARIO DURATION OUTPUT_PREFIX HOST_PID"
  exit 2
fi

scenario=$1
duration=$2
prefix=$3
host_pid=$4
sample_mode=${FARPANE_HOST_SAMPLE_MODE:-acceptance}
allow_non_farpane=${FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE:-0}

case "$scenario" in
  idle|host-ready-no-screen-route|static|static-1080p30|static-4k30|1080p30|4k30-normal|4k30-video|stability|stability-1080p30|stability-4k30|recovery|battery-idle|battery-active|host-ready-viewer|host-viewer-dual) ;;
  *) print -u2 "unknown scenario: $scenario"; exit 2 ;;
esac
case "$sample_mode" in
  acceptance|smoke) ;;
  *) print -u2 "FARPANE_HOST_SAMPLE_MODE must be acceptance or smoke"; exit 2 ;;
esac
case "$allow_non_farpane" in
  0|1) ;;
  *) print -u2 "FARPANE_HOST_SAMPLE_ALLOW_NON_FARPANE must be 0 or 1"; exit 2 ;;
esac
if [[ ! "$duration" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "duration must be a positive integer number of seconds"
  exit 2
fi
if [[ ! "$host_pid" =~ '^[1-9][0-9]*$' ]] || (( host_pid <= 1 )); then
  print -u2 "HOST_PID must be a process ID greater than 1"
  exit 2
fi
if [[ "$sample_mode" == acceptance ]]; then
  minimum_duration=600
  [[ "$scenario" == stability || "$scenario" == stability-* ]] && minimum_duration=1800
  if (( duration < minimum_duration )); then
    print -u2 "$scenario acceptance requires duration >= $minimum_duration seconds; use FARPANE_HOST_SAMPLE_MODE=smoke only for preflight"
    exit 2
  fi
fi
if ! kill -0 "$host_pid" 2>/dev/null; then
  print -u2 "Host process is not running: pid=$host_pid"
  exit 2
fi

host_command=$(ps -p "$host_pid" -o comm= 2>/dev/null | awk '{$1=$1; print}')
host_process_name=${host_command:t}
if [[ -z "$host_process_name" ]]; then
  print -u2 "cannot resolve process name for pid=$host_pid"
  exit 2
fi
case "$host_process_name" in
  FarPane|RustDeskNative) ;;
  *)
    if [[ "$allow_non_farpane" != 1 || "$sample_mode" != smoke ]]; then
      print -u2 "pid=$host_pid is '$host_process_name', not FarPane/RustDeskNative"
      exit 2
    fi
    ;;
esac

csv="$prefix.samples.csv"
meta="$prefix.json"
log="$prefix.log"
for artifact in "$csv" "$meta" "$log"; do
  if [[ -e "$artifact" ]]; then
    print -u2 "refusing to overwrite existing artifact: $artifact"
    exit 2
  fi
done
mkdir -p "${prefix:h}"

machine_model=$(sysctl -n hw.model)
machine_arch=$(uname -m)
macos_version=$(sw_vers -productVersion)
resolution=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/{print $2; exit}')
[[ -n "$resolution" ]] || resolution=unknown

print 'elapsed_seconds,scenario,host_cpu_percent,host_rss_kb,host_threads,host_energy_impact,windowserver_cpu_percent,windowserver_rss_kb,windowserver_threads,windowserver_energy_impact,videotoolboxd_cpu_percent,videotoolboxd_rss_kb,videotoolboxd_threads,videotoolboxd_energy_impact,vt_encoder_xpc_cpu_percent,vt_encoder_xpc_rss_kb,vt_encoder_xpc_threads,vt_encoder_xpc_energy_impact,system_cpu_user_percent,system_cpu_sys_percent,system_cpu_idle_percent,memory_free_percent,thermal_pressure,power_source,host_sleep_assertion_count,host_user_idle_sleep_assertion_count,host_display_sleep_assertion_count' > "$csv"

collect_process_stats() {
  local -a pids=("$@")
  local -a rows=()
  local pid stats threads
  for pid in "${pids[@]}"; do
    [[ -n "$pid" ]] || continue
    stats=$(ps -p "$pid" -o %cpu=,rss= 2>/dev/null | awk '{$1=$1; if (NF == 2) printf "%s,%s", $1, $2}')
    [[ -n "$stats" ]] || continue
    threads=$(ps -M -p "$pid" 2>/dev/null | awk 'NR > 1 { count += 1 } END { print count + 0 }')
    rows+=("$stats,$threads")
  done
  if (( ${#rows} == 0 )); then
    print '0.0,0,0'
    return
  fi
  printf '%s\n' "${rows[@]}" | awk -F, '{ cpu += $1; rss += $2; threads += $3 } END { printf "%.1f,%d,%d", cpu, rss, threads }'
}

collect_energy_impact() {
  local pid_csv=$1
  if [[ "$energy_impact_available" != true || -z "$pid_csv" ]]; then
    print 'na'
    return
  fi
  print -r -- "$top_snapshot" | awk -v ids="$pid_csv" '
    BEGIN {
      count = split(ids, pid_list, ",")
      for (item = 1; item <= count; item += 1) wanted[pid_list[item]] = 1
    }
    $1 in wanted { latest[$1] = $NF }
    END {
      for (pid in wanted) {
        if (pid in latest) {
          total += latest[pid]
          found += 1
        }
      }
      if (found == 0) print "0.0"; else printf "%.1f\n", total
    }
  '
}

start_time=$EPOCHREALTIME
typeset -F 6 next_sample sleep_for elapsed
next_sample=$start_time
sample_count=0
energy_impact_available=false
latest_thermal=unknown
latest_power_source=unknown

finalize_metadata() {
  local sampler_exit_status=$1
  [[ -e "$meta" ]] && return 0
  local actual_duration collected_at completed=false meta_tmp
  actual_duration=$(( EPOCHREALTIME - start_time ))
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if (( sampler_exit_status == 0 && sample_count == duration )); then
    completed=true
  fi
  meta_tmp=$(mktemp "${meta:h}/.farpane-system.XXXXXX")
  cat > "$meta_tmp" <<EOF
{
  "schemaVersion": 3,
  "sampler": "farpane-host-system",
  "scenario": "$scenario",
  "sampleMode": "$sample_mode",
  "requestedDurationSeconds": $duration,
  "actualDurationSeconds": $actual_duration,
  "sampleCount": $sample_count,
  "completed": $completed,
  "samplerExitStatus": $sampler_exit_status,
  "hostProcessName": "$host_process_name",
  "hostPid": $host_pid,
  "hostRole": "combined-host-agent-native-app",
  "machineModel": "$machine_model",
  "architecture": "$machine_arch",
  "macOSVersion": "$macos_version",
  "resolution": "$resolution",
  "energyImpactAvailable": $energy_impact_available,
  "energyImpactUnit": "top-relative-not-joules",
  "sleepAssertionAuthority": "pmset-pid-and-type",
  "requiredActiveAssertionType": "PreventUserIdleSystemSleep",
  "forbiddenNativeHostAssertionType": "PreventUserIdleDisplaySleep",
  "thermalPressure": "$latest_thermal",
  "powerSource": "$latest_power_source",
  "collectedAt": "$collected_at"
}
EOF
  if ! ln "$meta_tmp" "$meta"; then
    rm -f "$meta_tmp"
    return 1
  fi
  rm -f "$meta_tmp"
  {
    print "sample_count=$sample_count actual_duration_seconds=$actual_duration"
    print "completed=$completed sampler_exit_status=$sampler_exit_status"
    print "artifacts=$csv $meta"
  } >> "$log"
}

trap 'finalize_metadata $?' EXIT

{
  print "sampler=farpane-host-system scenario=$scenario mode=$sample_mode"
  print "host_process=$host_process_name host_pid=$host_pid"
  print "machine_model=$machine_model arch=$machine_arch macos=$macos_version resolution=$resolution"
  print "energy_impact=top POWER relative metric; not joules or whole-system physical energy"
} > "$log"

print "sampling pid=$host_pid scenario=$scenario mode=$sample_mode for ${duration}s -> $csv"
for (( sample_index = 0; sample_index < duration; sample_index += 1 )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    print -u2 "Host process exited after $sample_count samples; aborting"
    exit 1
  fi

  ws_pids=("${(@f)$(pgrep -x WindowServer 2>/dev/null || true)}")
  vt_pids=("${(@f)$(pgrep -x videotoolboxd 2>/dev/null || true)}")
  encoder_pids=("${(@f)$(pgrep -x VTEncoderXPCService 2>/dev/null || true)}")
  ws_pids=("${(@)ws_pids:#}")
  vt_pids=("${(@)vt_pids:#}")
  encoder_pids=("${(@)encoder_pids:#}")

  typeset -A seen_pids=()
  sampled_pids=()
  for pid in "$host_pid" "${ws_pids[@]}" "${vt_pids[@]}" "${encoder_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    if [[ -z "${seen_pids[$pid]-}" ]]; then
      seen_pids[$pid]=1
      sampled_pids+=("$pid")
    fi
  done
  top_pid_args=()
  for pid in "${sampled_pids[@]}"; do
    top_pid_args+=(-pid "$pid")
  done
  top_snapshot=$(top -l 2 -s 0 "${top_pid_args[@]}" -stats pid,power 2>/dev/null || true)
  system_cpu=$(print -r -- "$top_snapshot" | awk '/CPU usage:/ { gsub(/%/, "", $3); gsub(/%/, "", $5); gsub(/%/, "", $7); latest = $3 "," $5 "," $7 } END { print latest }')
  if [[ -z "$system_cpu" ]]; then
    print -u2 "could not read system CPU from top"
    exit 1
  fi
  if print -r -- "$top_snapshot" | awk '/^PID[[:space:]]+POWER/ { found = 1 } END { exit !found }'; then
    energy_impact_available=true
  else
    energy_impact_available=false
  fi

  host_stats=$(collect_process_stats "$host_pid")
  if [[ "$host_stats" == '0.0,0,0' ]]; then
    print -u2 "could not sample Host process pid=$host_pid"
    exit 1
  fi
  ws_stats=$(collect_process_stats "${ws_pids[@]}")
  vt_stats=$(collect_process_stats "${vt_pids[@]}")
  encoder_stats=$(collect_process_stats "${encoder_pids[@]}")

  host_energy=$(collect_energy_impact "$host_pid")
  ws_energy=$(collect_energy_impact "${(j:,:)ws_pids}")
  vt_energy=$(collect_energy_impact "${(j:,:)vt_pids}")
  encoder_energy=$(collect_energy_impact "${(j:,:)encoder_pids}")

  memory_free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/, "", $2); print $2; exit}')
  if [[ -z "$memory_free" ]]; then
    print -u2 "could not read system memory pressure"
    exit 1
  fi
  latest_thermal=$(pmset -g therm 2>/dev/null | awk -F': ' '/Thermal_Pressure_Level/{print $2; exit}')
  [[ -n "$latest_thermal" ]] || latest_thermal=unknown
  power_text=$(pmset -g batt 2>/dev/null | awk -F"'" '/drawing from/{print $2; exit}')
  case "$power_text" in
    'AC Power') latest_power_source=ac ;;
    'Battery Power') latest_power_source=battery ;;
    *) latest_power_source=unknown ;;
  esac
  assertion_snapshot=$(pmset -g assertions 2>/dev/null || true)
  assertion_count=$(print -r -- "$assertion_snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) { count += 1 } END { print count + 0 }')
  user_idle_assertion_count=$(print -r -- "$assertion_snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) && index($0, "PreventUserIdleSystemSleep") { count += 1 } END { print count + 0 }')
  display_assertion_count=$(print -r -- "$assertion_snapshot" | awk -v needle="pid $host_pid" 'index($0, needle) && index($0, "PreventUserIdleDisplaySleep") { count += 1 } END { print count + 0 }')

  elapsed=$(( EPOCHREALTIME - start_time ))
  printf '%.3f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d\n' \
    "$elapsed" "$scenario" "$host_stats" "$host_energy" "$ws_stats" "$ws_energy" \
    "$vt_stats" "$vt_energy" "$encoder_stats" "$encoder_energy" "$system_cpu,$memory_free,$latest_thermal,$latest_power_source" \
    "$assertion_count" "$user_idle_assertion_count" "$display_assertion_count" >> "$csv"
  sample_count=$(( sample_count + 1 ))

  next_sample=$(( next_sample + 1.0 ))
  sleep_for=$(( next_sample - EPOCHREALTIME ))
  if (( sleep_for > 0 && sample_index + 1 < duration )); then
    sleep "$sleep_for"
  elif (( sleep_for <= 0 )); then
    next_sample=$EPOCHREALTIME
  fi
done

# The first sample is taken at t=0. Keep the sampler alive until the requested
# wall-clock duration has elapsed so N samples cannot be mislabeled as an
# N-second acceptance window when they only span N-1 seconds.
sleep_for=$(( next_sample - EPOCHREALTIME ))
if (( sleep_for > 0 )); then
  sleep "$sleep_for"
fi

finalize_metadata 0
print "done: $csv $meta $log"
