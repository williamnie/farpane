#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
if [[ "$(uname -m)" != x86_64 ]]; then
  print -u2 "Phase 3 acceptance must run on the Intel MBP"
  exit 2
fi
: "${RDN_PASSWORD:?Set RDN_PASSWORD securely in this MBP shell}"

app="$repo_dir/.build/release/RustDeskNative"
core="$repo_dir/Build/CoreBridge/x86_64/liblibrustdesk.dylib"
prefix_base="$repo_dir/Benchmarks/phase3-live-4k-relay-acceptance-1800s"
prefix="$prefix_base"
attempt=1
while [[ -e "$prefix.json" || -e "$prefix.samples.csv" || -e "$prefix.log" ||
         -e "$prefix.validation.txt" || -e "$prefix.functional-validation.txt" ]]; do
  (( attempt += 1 ))
  prefix="${prefix_base}-attempt${attempt}"
done
functional_validation="$prefix.functional-validation.txt"
evidence_dir="$repo_dir/Evidence/IntelMBP/$(date +%F)/Phase3"

[[ -x "$app" ]] || { print -u2 "release executable not found: $app"; exit 2; }
[[ -f "$core" ]] || { print -u2 "Core dylib not found: $core"; exit 2; }
[[ ! -e "$evidence_dir" ]] || { print -u2 "refusing to overwrite Phase 3 evidence: $evidence_dir"; exit 2; }

for artifact in "$prefix.json" "$prefix.samples.csv" "$prefix.log" \
  "$prefix.validation.txt" "$functional_validation"; do
  if [[ -e "$artifact" ]]; then
    print -u2 "refusing to overwrite existing Phase 3 artifact: $artifact"
    exit 2
  fi
done

print "Phase 3 acceptance will run for 30 minutes through the configured secure Hermes relay."
print "Before this run, launch the Viewer without arguments once and verify the blank-form error is sanitized."
print "During the run, verify real remote feedback for click, drag, scroll, English/Chinese text, key repeat and a modifier shortcut."
print "Enter and leave full screen, hide and show the HUD, then use 验收记录 to mark only observed successes."

RDN_FORCE_RELAY=1 \
  "$repo_dir/Scripts/benchmark-live-from-rustdesk-config-mbp.sh" \
  "$app" "$core" 1800 automatic "$prefix"

/usr/bin/python3 - "$prefix.json" > "$functional_validation" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    report = json.load(report_file)

required_checks = {
    "click", "drag", "scroll", "text", "key-repeat", "shortcut",
    "fullscreen", "hud", "error-state"
}
checks = report.get("functionalChecks", {})
failures = []

def require(condition, message):
    if not condition:
        failures.append(message)

require(report.get("inputPointerMoves", 0) >= 30, "too few accepted pointer moves")
require(report.get("inputButtonDowns", 0) >= 2, "click/drag button-down evidence missing")
require(
    report.get("inputButtonDowns", 0) == report.get("inputButtonUps", 0),
    "button down/up counts are unbalanced",
)
require(report.get("inputScrollEvents", 0) >= 3, "scroll evidence missing")
require(report.get("inputKeyDowns", 0) >= 5, "basic text/shortcut key evidence missing")
require(
    report.get("inputKeyDowns", 0) == report.get("inputKeyUps", 0),
    "key down/up counts are unbalanced",
)
require(report.get("inputRejectedEvents", 0) == 0, "the core rejected one or more input events")
require(report.get("fullscreenToggles", 0) >= 2, "full-screen enter/exit evidence missing")
require(report.get("hudToggles", 0) >= 2, "HUD hide/show evidence missing")
require(all(checks.get(name) is True for name in required_checks), "manual remote-feedback checklist is incomplete")
states = report.get("coreStateTransitions", [])
require(any("control-ready" in state for state in states), "remote input permission was not observed")
require(any("streaming" in state for state in states), "streaming state was not observed")

for name in sorted(required_checks):
    print(f"functionalCheck.{name}={str(checks.get(name) is True).lower()}")
for key in (
    "inputPointerMoves", "inputButtonDowns", "inputButtonUps", "inputScrollEvents",
    "inputKeyDowns", "inputKeyUps", "inputRejectedEvents", "fullscreenToggles", "hudToggles",
):
    print(f"{key}={report.get(key, 0)}")
print(f"functionalValidation={'passed' if not failures else 'failed'}")
if failures:
    for failure in failures:
        print(f"failure={failure}")
    raise SystemExit(1)
PY

cat "$functional_validation"
stage=$(mktemp -d "${TMPDIR:-/tmp}/rdn-phase3-evidence.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$prefix.json" "$stage/report.json"
cp "$prefix.samples.csv" "$stage/samples.csv"
cp "$prefix.log" "$stage/app.log"
cp "$prefix.validation.txt" "$stage/pipeline-validation.txt"
cp "$functional_validation" "$stage/functional-validation.txt"
{
  print "acceptanceDate=$(date +%F)"
  print "machineArchitecture=$(uname -m)"
  print "macOSVersion=$(sw_vers -productVersion)"
  print "xcodeVersion=$(xcodebuild -version | tr '\n' ' ')"
  print "swiftVersion=$(swift --version | head -1)"
  print "rustVersion=$(rustc --version)"
  print "rustDeskCommit=$(git -C "$repo_dir/Vendor/rustdesk" rev-parse HEAD)"
  print "viewerSHA256=$(shasum -a 256 "$app" | awk '{print $1}')"
  print "coreSHA256=$(shasum -a 256 "$core" | awk '{print $1}')"
} > "$stage/environment.txt"
{
  print '# Phase 3 Intel acceptance evidence'
  print
  print 'This directory contains the successful 30-minute real Hermes relay run from'
  print 'the Intel MacBook Pro to the 4096x2304 Mac mini. Functional checks in the'
  print 'report were marked only after visible remote feedback. No fixture result is'
  print 'represented as live evidence, and connection credentials are not recorded.'
  print
  print '`pipeline-validation.txt` covers the H265/VideoToolbox/Metal performance and'
  print 'stability gates. `functional-validation.txt` covers pointer, buttons, wheel,'
  print 'keyboard, full screen, HUD, sanitized error UI and remote-feedback checks.'
} > "$stage/README.md"
(
  cd "$stage"
  shasum -a 256 README.md environment.txt report.json samples.csv app.log \
    pipeline-validation.txt functional-validation.txt > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
mkdir -p "${evidence_dir:h}"
mv "$stage" "$evidence_dir"
trap - EXIT INT TERM
print "PHASE3_ACCEPTANCE_PASSED=true"
print "PHASE3_FUNCTIONAL_VALIDATION=$functional_validation"
print "PHASE3_EVIDENCE=$evidence_dir"
