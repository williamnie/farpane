#!/bin/zsh
set -euo pipefail

if (( $# != 7 )); then
  print -u2 "usage: $0 APP_OR_EXECUTABLE FIXTURE WIDTH HEIGHT DURATION GPU OUTPUT_PREFIX"
  exit 2
fi

app_input=$1
fixture=$2
width=$3
height=$4
duration=$5
gpu=$6
prefix=$7
sample_interval=1

if [[ -d "$app_input" ]]; then
  executable="$app_input/Contents/MacOS/RustDeskNative"
else
  executable="$app_input"
fi
if [[ ! -x "$executable" ]]; then
  print -u2 "executable not found: $executable"
  exit 2
fi
if [[ ! -f "$fixture" ]]; then
  print -u2 "fixture not found: $fixture"
  exit 2
fi

mkdir -p "${prefix:h}"
json="$prefix.json"
csv="$prefix.samples.csv"
log="$prefix.log"
print 'elapsed_seconds,app_cpu_percent,app_rss_kb,vtdecoder_cpu_percent,vtdecoder_rss_kb' > "$csv"

SECONDS=0
"$executable" \
  --fixture "$fixture" --width "$width" --height "$height" --fps 30 \
  --duration "$duration" --gpu "$gpu" --fullscreen true --output "$json" > "$log" 2>&1 &
app_pid=$!

cleanup() {
  if kill -0 "$app_pid" 2>/dev/null; then kill -TERM "$app_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

while kill -0 "$app_pid" 2>/dev/null; do
  elapsed=$SECONDS
  app_stats=$(ps -p "$app_pid" -o %cpu=,rss= | awk '{$1=$1; print $1 "," $2}')
  vt_stats=$(ps -axo comm=,%cpu=,rss= | awk '
    /VTDecoderXPCService/ { cpu += $(NF-1); rss += $NF }
    END { printf "%.1f,%d", cpu, rss }
  ')
  print "${elapsed},${app_stats:-0,0},${vt_stats:-0,0}" >> "$csv"
  sleep "$sample_interval"
done
wait "$app_pid"
trap - EXIT INT TERM

if [[ ! -s "$json" ]]; then
  print -u2 "benchmark did not produce $json"
  cat "$log" >&2
  exit 1
fi

actual_width=$(plutil -extract observedWidth raw "$json")
actual_height=$(plutil -extract observedHeight raw "$json")
decode_errors=$(plutil -extract decodeErrors raw "$json")
non_nv12=$(plutil -extract nonNV12Frames raw "$json")
missing_iosurface=$(plutil -extract missingIOSurfaceFrames raw "$json")
hardware_decode=$(plutil -extract hardwareDecodeActive raw "$json")
if [[ "$actual_width" != "$width" || "$actual_height" != "$height" ||
      "$decode_errors" != 0 || "$non_nv12" != 0 || "$missing_iosurface" != 0 ||
      "$hardware_decode" != true ]]; then
  print -u2 "pipeline invariant failed: expected=${width}x${height} actual=${actual_width}x${actual_height} errors=$decode_errors non_nv12=$non_nv12 missing_iosurface=$missing_iosurface hardware=$hardware_decode"
  exit 1
fi

print "BENCHMARK_JSON=$json"
print "SAMPLES_CSV=$csv"
print "APP_LOG=$log"
cat "$json"
