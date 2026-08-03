#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
fixture_dir="$repo_dir/Fixtures"
mkdir -p "$fixture_dir"

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  print -u2 "ffmpeg and ffprobe are required"
  exit 1
fi

generate_fixture() {
  local width=$1
  local height=$2
  local bitrate=$3
  local output="$fixture_dir/hevc-${width}x${height}-30.hevc"
  local temporary
  temporary=$(mktemp "$fixture_dir/.fixture.XXXXXX.hevc")

  ffmpeg -y -hide_banner -loglevel warning \
    -f lavfi -i "testsrc2=size=${width}x${height}:rate=30" \
    -t 2 -pix_fmt yuv420p \
    -c:v hevc_videotoolbox -profile:v main -realtime 1 -prio_speed 1 \
    -g 30 -bf 0 -b:v "$bitrate" \
    -bsf:v 'hevc_metadata=aud=insert:tick_rate=30/1:num_ticks_poc_diff_one=1:colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1' \
    -f hevc "$temporary"
  mv "$temporary" "$output"

  ffprobe -v error -f hevc -select_streams v:0 -count_frames \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,color_range,color_space,r_frame_rate,nb_read_frames \
    -of json "$output" > "$output.metadata.json"
  (cd "$fixture_dir" && shasum -a 256 "${output:t}" > "${output:t}.sha256")
}

generate_fixture 2048 1152 12M
generate_fixture 4096 2304 40M

print "Generated and verified fixtures:"
for metadata in "$fixture_dir"/*.metadata.json; do
  print "  $metadata"
  cat "$metadata"
done
