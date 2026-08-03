#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
duration=${1:-2100}

if ! awk -v duration="$duration" 'BEGIN { exit !(duration > 0) }'; then
  print -u2 "usage: $0 [positive-duration-seconds]"
  exit 2
fi

output_dir="$repo_dir/Build/Benchmarks"
executable="$output_dir/Phase2Motion"
mkdir -p "$output_dir"

swiftc \
  -framework AppKit \
  -framework QuartzCore \
  "$repo_dir/Benchmarks/Phase2Motion.swift" \
  -o "$executable"

exec /usr/bin/caffeinate -dimsu "$executable" "$duration"
