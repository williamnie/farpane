#!/bin/zsh
set -euo pipefail

# Reproducible "normal operation" canvas for the H0.4 host baseline:
# TextEdit text growth + window bounds churn. Uses application scripting only
# (no CGEvent injection, no TCC dependency), so it runs on the controlled
# machine while a remote session is connected.
#
# usage: baseline-canvas-normal.sh [DURATION_SECONDS]

duration=${1:-520}
para='The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump! '

osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
SECONDS=0
i=0
while (( SECONDS < duration )); do
  i=$((i+1))
  osascript -e "tell application \"TextEdit\" to set text of document 1 to (text of document 1 & \"$para\")" >/dev/null 2>&1 || true
  if (( i % 4 == 0 )); then
    osascript -e 'tell application "TextEdit" to set bounds of window 1 to {120, 120, 1560, 960}' >/dev/null 2>&1 || true
  else
    osascript -e 'tell application "TextEdit" to set bounds of window 1 to {160, 100, 1600, 1000}' >/dev/null 2>&1 || true
  fi
  if (( i % 40 == 0 )); then
    osascript -e 'tell application "TextEdit" to close document 1 saving no' -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
  fi
  sleep 0.25
done
osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
print "normal canvas done after ${SECONDS}s ($i iterations)"
