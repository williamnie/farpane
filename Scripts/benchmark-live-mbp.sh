#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

if (( $# != 5 )); then
  print -u2 "usage: $0 APP_OR_EXECUTABLE CORE_DYLIB DURATION GPU OUTPUT_PREFIX"
  print -u2 "required environment: RDN_SERVER RDN_SERVER_PUBLIC_KEY RDN_PEER_ID; optional RDN_PASSWORD"
  exit 2
fi
: "${RDN_SERVER:?RDN_SERVER is required}"
: "${RDN_SERVER_PUBLIC_KEY:?RDN_SERVER_PUBLIC_KEY is required}"
: "${RDN_PEER_ID:?RDN_PEER_ID is required}"

app_input=$1
core_library=$2
duration=$3
gpu=$4
prefix=$5
duration_whole=${duration%.*}
smoke_mode=${RDN_PHASE2_SMOKE:-0}
preflight_mode=${RDN_PHASE2_4K_PREFLIGHT:-0}
validate_existing=${RDN_VALIDATE_EXISTING:-0}
case "$preflight_mode" in
  0|1) ;;
  *) print -u2 "RDN_PHASE2_4K_PREFLIGHT must be 0 or 1"; exit 2 ;;
esac
case "$validate_existing" in
  0|1) ;;
  *) print -u2 "RDN_VALIDATE_EXISTING must be 0 or 1"; exit 2 ;;
esac
case "${RDN_FORCE_RELAY:-0}" in
  0|false) force_relay=false ;;
  1|true) force_relay=true ;;
  *) print -u2 "RDN_FORCE_RELAY must be 0, 1, false, or true"; exit 2 ;;
esac
if (( duration_whole < 1800 )) && [[ "$smoke_mode" != 1 && "$preflight_mode" != 1 ]]; then
  print -u2 "live Phase 2 acceptance requires duration >= 1800 seconds"
  exit 2
fi

if [[ -d "$app_input" ]]; then
  executable="$app_input/Contents/MacOS/RustDeskNative"
else
  executable="$app_input"
fi
[[ -x "$executable" ]] || { print -u2 "executable not found: $executable"; exit 2; }
[[ -f "$core_library" ]] || { print -u2 "core library not found: $core_library"; exit 2; }

mkdir -p "${prefix:h}"
json="$prefix.json"
csv="$prefix.samples.csv"
log="$prefix.log"
validation="$prefix.validation.txt"
if [[ "$validate_existing" == 1 ]]; then
  [[ -s "$json" && -s "$csv" && -s "$log" ]] || {
    print -u2 "existing live benchmark artifacts are incomplete for prefix $prefix"
    exit 2
  }
else
  print 'elapsed_seconds,app_cpu_percent,app_rss_kb,vtdecoder_cpu_percent,vtdecoder_rss_kb' > "$csv"

  SECONDS=0
  "$executable" \
    --core "$core_library" \
    --server-env RDN_SERVER \
    --key-env RDN_SERVER_PUBLIC_KEY \
    --peer-id-env RDN_PEER_ID \
    --password-env RDN_PASSWORD \
    --force-relay "$force_relay" \
    --duration "$duration" --gpu "$gpu" --fullscreen true --output "$json" > "$log" 2>&1 &
  app_pid=$!
  unset RDN_SERVER RDN_SERVER_PUBLIC_KEY RDN_PEER_ID RDN_PASSWORD
  /usr/bin/caffeinate -dimsu -w "$app_pid" &
  caffeinate_pid=$!

  cleanup() {
    if kill -0 "$app_pid" 2>/dev/null; then kill -TERM "$app_pid" 2>/dev/null || true; fi
    if kill -0 "$caffeinate_pid" 2>/dev/null; then kill -TERM "$caffeinate_pid" 2>/dev/null || true; fi
  }
  trap cleanup EXIT INT TERM
  typeset -F 6 next_sample sleep_for
  next_sample=$EPOCHREALTIME
  while kill -0 "$app_pid" 2>/dev/null; do
    app_stats=$(ps -p "$app_pid" -o %cpu=,rss= | awk '{$1=$1; print $1 "," $2}')
    vt_stats=$(ps -axo comm=,%cpu=,rss= | awk '
      /VTDecoderXPCService/ { cpu += $(NF-1); rss += $NF }
    END { printf "%.1f,%d", cpu, rss }
  ')
    print "${SECONDS},${app_stats:-0,0},${vt_stats:-0,0}" >> "$csv"
    next_sample=$(( next_sample + 1.0 ))
    sleep_for=$(( next_sample - EPOCHREALTIME ))
    if (( sleep_for > 0 )); then
      sleep "$sleep_for"
    else
      next_sample=$EPOCHREALTIME
    fi
  done
  wait "$app_pid"
  wait "$caffeinate_pid" 2>/dev/null || true
  trap - EXIT INT TERM
fi

[[ -s "$json" ]] || { print -u2 "live benchmark did not produce $json"; tail -100 "$log" >&2; exit 1; }
value() {
  /usr/bin/python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    value = json.load(report_file)[sys.argv[2]]
print(str(value).lower() if isinstance(value, bool) else value)
' "$json" "$1"
}

source_mode=$(value source)
actual_duration=$(value durationSeconds)
encoded=$(value encodedPackets)
encoded_frames=$(value encodedFrames)
encoded_fps=$(value measuredEncodedFPS)
h265=$(value h265Packets)
non_h265=$(value nonH265Packets)
annex_b=$(value annexBPackets)
avcc=$(value avccPackets)
mixed=$(value mixedPackets)
unknown=$(value unknownFormatPackets)
decoded=$(value decodedFrames)
presented=$(value presentedFrames)
errors=$(value decodeErrors)
reference_frame_drops=$(value referenceFrameDrops)
backpressure_waits=$(value backpressureWaits)
max_backpressure_wait_ms=$(value maxBackpressureWaitMS)
decoder_resets=$(value decoderResets)
keyframe_requests=$(value keyframeRequests)
hardware=$(value hardwareDecodeActive)
non_nv12=$(value nonNV12Frames)
missing_surface=$(value missingIOSurfaceFrames)
max_queue=$(value maxQueueDepth)
max_renderer_queue=$(value maxRendererQueueDepth)
remote_width=$(value remoteEncodedWidth)
remote_height=$(value remoteEncodedHeight)
observed_width=$(value observedWidth)
observed_height=$(value observedHeight)
drawable_width=$(value drawableWidth)
drawable_height=$(value drawableHeight)
measured_fps=$(value measuredFPS)
max_presentation_gap_ms=$(value maxPresentationGapMS)
final_presentation_staleness_ms=$(value finalPresentationStalenessMS)
max_receiving_staleness_ms=$(value maxPresentationStalenessWhileReceivingMS)
final_encoded_staleness_ms=$(value finalEncodedToPresentationStalenessMS)
average_decode_ms=$(value averageDecodeMS)
average_render_ms=$(value averageRenderMS)
network_delay_ms=$(value coreNetworkDelayMS)
vps=$(value packetsWithVPS)
sps=$(value packetsWithSPS)
pps=$(value packetsWithPPS)
steady_growth=$(value steadyStateMemoryGrowthMB)
states=$(/usr/bin/python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    states = json.load(report_file)["coreStateTransitions"]
print(json.dumps(states, separators=(",", ":")))
' "$json")

if [[ "$source_mode" != rustdesk-live ]] ||
   (( ${actual_duration%.*} < ${duration%.*} - 2 )) ||
   (( encoded == 0 || encoded_frames == 0 || h265 != encoded || non_h265 != 0 )) ||
   (( annex_b > 0 && avcc > 0 )) ||
   (( annex_b == 0 && avcc == 0 )) ||
   (( mixed != 0 || unknown != 0 )) ||
   (( decoded == 0 || presented == 0 || errors > 10 || reference_frame_drops > 10 )) ||
   [[ "$hardware" != true ]] ||
   (( non_nv12 != 0 || missing_surface != 0 || max_queue > 2 || max_renderer_queue > 2 )) ||
   (( remote_width <= 0 || remote_height <= 0 || observed_width != remote_width || observed_height != remote_height )) ||
   (( drawable_width <= 0 || drawable_height <= 0 || network_delay_ms < 0 )) ||
   (( vps == 0 || sps == 0 || pps == 0 )) ||
   (( (errors > 0 || reference_frame_drops > 0) && (decoder_resets == 0 || keyframe_requests < decoder_resets) )) ||
   [[ "$states" != *'streaming'* ]] ||
   ! awk -v encoded_fps="$encoded_fps" -v presented_fps="$measured_fps" -v decode_ms="$average_decode_ms" -v render_ms="$average_render_ms" -v wait_ms="$max_backpressure_wait_ms" -v receiving_stale="$max_receiving_staleness_ms" -v final_encoded_stale="$final_encoded_staleness_ms" 'BEGIN { exit !(encoded_fps > 0 && presented_fps > 0 && decode_ms > 0 && render_ms > 0 && wait_ms < 1000 && receiving_stale < 3000 && final_encoded_stale < 3000) }' ||
   ! awk -v encoded="$encoded_frames" -v presented="$presented" 'BEGIN { exit !(presented / encoded >= 0.90) }' ||
   ! awk -v growth="$steady_growth" 'BEGIN { exit !(growth < 128.0) }'; then
  print -u2 "live pipeline invariant failed; inspect $json, $csv and $log"
  exit 1
fi

if (( duration_whole >= 1800 )) || [[ "$preflight_mode" == 1 ]]; then
  if (( remote_width != 4096 || remote_height != 2304 )) ||
     ! awk -v encoded_fps="$encoded_fps" -v presented_fps="$measured_fps" 'BEGIN { exit !(encoded_fps >= 28 && presented_fps >= 28) }' ||
     ! awk -v growth="$steady_growth" 'BEGIN { exit !(growth < 50.0) }'; then
    print -u2 "live 4K performance invariant failed; inspect $json, $csv and $log"
    exit 1
  fi
fi

if (( duration_whole < 1800 )); then
  print "LIVE_SMOKE_MODE=true"
  print "LIVE_BENCHMARK_JSON=$json"
  print "LIVE_SAMPLES_CSV=$csv"
  print "LIVE_APP_LOG=$log"
  cat "$json"
  exit 0
fi

if ! awk -F, -v expected="${duration%.*}" '
  NR == 1 { next }
  {
    elapsed = $1 + 0
    app_cpu += $2 + 0
    app_rss = $3 + 0
    vt_cpu += $4 + 0
    vt_rss = $5 + 0
    samples += 1
    peak_app_rss = app_rss > peak_app_rss ? app_rss : peak_app_rss
    peak_vt_rss = vt_rss > peak_vt_rss ? vt_rss : peak_vt_rss
    if (elapsed >= 300) {
      steady_samples += 1
      sum_x += elapsed
      sum_y += app_rss
      sum_xx += elapsed * elapsed
      sum_xy += elapsed * app_rss
    }
    if (elapsed >= 300 && elapsed < 600) {
      early_rss += app_rss
      early_samples += 1
    }
    if (elapsed >= expected - 300) {
      late_rss += app_rss
      late_samples += 1
    }
  }
  END {
    denominator = steady_samples * sum_xx - sum_x * sum_x
    slope_kb_second = denominator == 0 ? 0 : (steady_samples * sum_xy - sum_x * sum_y) / denominator
    slope_mib_minute = slope_kb_second * 60 / 1024
    early_mean = early_samples ? early_rss / early_samples : 0
    late_mean = late_samples ? late_rss / late_samples : 0
    window_growth_mib = (late_mean - early_mean) / 1024
    printf "sampleCount=%d\n", samples
    printf "averageAppCPUPercent=%.3f\n", samples ? app_cpu / samples : 0
    printf "averageVTDecoderCPUPercent=%.3f\n", samples ? vt_cpu / samples : 0
    printf "peakAppResidentMB=%.3f\n", peak_app_rss / 1024
    printf "peakVTDecoderResidentMB=%.3f\n", peak_vt_rss / 1024
    printf "steadyRSSSlopeMBPerMinute=%.6f\n", slope_mib_minute
    printf "steadyWindowGrowthMB=%.3f\n", window_growth_mib
    printf "sampleCoverageRequired=%d\n", expected - 10
    printf "memorySlopeLimitMBPerMinute=1.000\n"
    printf "appCPULimitPercent=60.000\n"
    printf "vtDecoderCPULimitPercent=10.000\n"
    printf "memoryWindowGrowthLimitMB=50.000\n"
    failed = samples < expected - 10 || steady_samples == 0 || early_samples == 0 || late_samples == 0 || app_cpu / samples > 60.0 || vt_cpu / samples > 10.0 || slope_mib_minute >= 1.0 || window_growth_mib >= 50.0
    exit failed
  }
' "$csv" > "$validation"; then
  print -u2 "live sample stability invariant failed; inspect $validation and $csv"
  cat "$validation" >&2
  exit 1
fi

print "LIVE_BENCHMARK_JSON=$json"
print "LIVE_SAMPLES_CSV=$csv"
print "LIVE_APP_LOG=$log"
print "LIVE_VALIDATION_SUMMARY=$validation"
cat "$json"
cat "$validation"
