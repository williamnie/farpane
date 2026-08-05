#!/bin/zsh
set -euo pipefail

# H0.4 controlled-side (host) CPU baseline sampler for the OFFICIAL RustDesk app.
# Samples RustDesk / WindowServer / videotoolboxd per-process CPU and RSS once
# per second, plus thermal pressure and power source, and records machine
# metadata. Run one invocation per scenario; the operator drives the desktop
# input (see docs/host-mode-h0.md §4 for scenario definitions).
#
# usage: baseline-official-host.sh SCENARIO DURATION OUTPUT_PREFIX
#   SCENARIO: static | normal | scroll | video
#   DURATION: seconds (design doc uses 600)
#   OUTPUT_PREFIX: e.g. Evidence/HostBaseline/2026-08-05/macmini-static

if (( $# != 3 )); then
  print -u2 "usage: $0 SCENARIO(static|normal|scroll|video) DURATION OUTPUT_PREFIX"
  exit 2
fi

scenario=$1
duration=$2
prefix=$3

case "$scenario" in
  static|normal|scroll|video) ;;
  *) print -u2 "unknown scenario: $scenario"; exit 2 ;;
esac

host_pid=$(pgrep -x RustDesk | head -n1 || true)
if [[ -z "$host_pid" ]]; then
  print -u2 "official RustDesk process not found (expected process name 'RustDesk')"
  exit 2
fi
ws_pid=$(pgrep -x WindowServer | head -n1 || true)

mkdir -p "${prefix:h}"
csv="$prefix.samples.csv"
meta="$prefix.json"
log="$prefix.log"

host_version=$(defaults read /Applications/RustDesk.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)
machine_model=$(sysctl -n hw.model)
cpu_brand=$(sysctl -n machdep.cpu.brand_string)
macos_version=$(sw_vers -productVersion)
resolution=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/{print $2; exit}')

{
  print "baseline=official-rustdesk-host scenario=$scenario"
  print "machine_model=$machine_model cpu=$cpu_brand macos=$macos_version"
  print "rustdesk_version=$host_version host_pid=$host_pid"
  print "resolution=${resolution:-unknown}"
} > "$log"

print 'elapsed_seconds,scenario,rustdesk_cpu_percent,rustdesk_rss_kb,windowserver_cpu_percent,windowserver_rss_kb,videotoolboxd_cpu_percent,videotoolboxd_rss_kb,vt_encoder_xpc_cpu_percent,vt_encoder_xpc_rss_kb,thermal_pressure,power_source' > "$csv"

sample_once() {
  local elapsed=$1
  local rd ws vt enc
  rd=$(ps -p "$host_pid" -o %cpu=,rss= 2>/dev/null | awk '{$1=$1; printf "%.1f,%d", $1, $2}')
  ws=$(ps -p "${ws_pid:-0}" -o %cpu=,rss= 2>/dev/null | awk '{$1=$1; printf "%.1f,%d", $1, $2}')
  vt=$(ps aux | awk '$11 ~ /videotoolboxd$/ { cpu += $3; rss += $6 } END { printf "%.1f,%d", cpu, rss }')
  enc=$(ps aux | awk '$11 ~ /VTEncoderXPCService$/ { cpu += $3; rss += $6 } END { printf "%.1f,%d", cpu, rss }')
  local thermal power
  thermal=$(pmset -g therm 2>/dev/null | awk -F': ' '/Thermal_Pressure_Level/{print $2; exit}')
  [[ -z "$thermal" ]] && thermal=nominal
  power=$(pmset -g batt 2>/dev/null | awk -F"'" '/drawing from/{print $2; exit}')
  print "${elapsed},${scenario},${rd:-0,0},${ws:-0,0},${vt:-0,0},${enc:-0,0},${thermal:-unknown},${power:-unknown}" >> "$csv"
}

print "sampling pid=$host_pid scenario=$scenario for ${duration}s -> $csv"
SECONDS=0
while (( SECONDS < duration )); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    print -u2 "RustDesk process exited at ${SECONDS}s; aborting"
    exit 1
  fi
  sample_once "$SECONDS"
  sleep 1
done

cat > "$meta" <<EOF
{
  "baseline": "official-rustdesk-host",
  "scenario": "$scenario",
  "durationSeconds": $duration,
  "machineModel": "$machine_model",
  "cpuBrand": "$cpu_brand",
  "macOSVersion": "$macos_version",
  "rustdeskVersion": "$host_version",
  "hostPid": $host_pid,
  "resolution": "${resolution:-unknown}",
  "collectedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
print "done: $csv $meta $log"
