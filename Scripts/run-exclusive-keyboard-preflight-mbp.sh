#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
if [[ "$(uname -m)" != x86_64 ]]; then
  print -u2 "Exclusive keyboard preflight must run on the Intel MBP"
  exit 2
fi
: "${RDN_PASSWORD:?Set RDN_PASSWORD securely in this MBP shell}"

app="$repo_dir/Build/RustDeskNative.app"
core="$repo_dir/Build/CoreBridge/x86_64/liblibrustdesk.dylib"
prefix="$repo_dir/Benchmarks/exclusive-keyboard-preflight-$(date +%Y%m%d-%H%M%S)-180s"
functional_validation="$prefix.functional-validation.txt"

[[ -x "$app/Contents/MacOS/RustDeskNative" ]] || {
  print -u2 "signed app bundle not found: $app"
  print -u2 "build it with Scripts/build-universal.sh before granting permissions"
  exit 2
}
[[ -f "$core" ]] || { print -u2 "Core dylib not found: $core"; exit 2; }

print "Run the real Hermes exclusive-keyboard preflight for three minutes."
print "If macOS requests Accessibility or Input Monitoring, grant it locally, close"
print "this diagnostic run, relaunch the preflight, and validate only on the clean run."
print "Verify Command-Space and Command-Tab affect only the remote Mac mini, then"
print "press Control-Option-Shift-Escape and confirm local control returns immediately."
print "Also verify remote IME input, ordinary typing, and no stuck modifier keys."
print "Before the run ends, mark only exclusive-keyboard in 验收记录 after visible feedback."

RDN_PHASE2_SMOKE=1 RDN_FORCE_RELAY=1 \
  "$repo_dir/Scripts/benchmark-live-from-rustdesk-config-mbp.sh" \
  "$app" "$core" 180 automatic "$prefix"

/usr/bin/python3 - "$prefix.json" > "$functional_validation" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    report = json.load(report_file)

checks = report.get("functionalChecks", {})
failures = []

def require(condition, message):
    if not condition:
        failures.append(message)

require(
    report.get("exclusiveKeyboardActivations", 0) >= 1,
    "exclusive keyboard mode was not activated",
)
require(
    report.get("exclusiveKeyboardFailures", 0) == 0,
    "exclusive keyboard reported a permission or event-tap failure",
)
require(
    checks.get("exclusive-keyboard") is True,
    "exclusive-keyboard remote-feedback check was not confirmed",
)
require(report.get("inputKeyDowns", 0) >= 8, "too few accepted key events")
require(
    report.get("inputKeyDowns", 0) == report.get("inputKeyUps", 0),
    "key down/up counts are unbalanced",
)
require(
    report.get("inputRejectedEvents", 0) == 0,
    "the core rejected one or more input events",
)

for key in (
    "exclusiveKeyboardActivations",
    "exclusiveKeyboardFailures",
    "inputKeyDowns",
    "inputKeyUps",
    "inputRejectedEvents",
):
    print(f"{key}={report.get(key, 0)}")
print(
    "functionalCheck.exclusive-keyboard="
    f"{str(checks.get('exclusive-keyboard') is True).lower()}"
)
print(f"exclusiveKeyboardPreflight={'passed' if not failures else 'failed'}")
if failures:
    for failure in failures:
        print(f"failure={failure}")
    raise SystemExit(1)
PY

cat "$functional_validation"
print "EXCLUSIVE_KEYBOARD_PREFLIGHT_PASSED=true"
print "EXCLUSIVE_KEYBOARD_PREFLIGHT_PREFIX=$prefix"
