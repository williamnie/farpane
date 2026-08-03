#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
if [[ "$(uname -m)" != x86_64 ]]; then
  print -u2 "Productization acceptance must run on the Intel MBP"
  exit 2
fi
if ifconfig awdl0 2>/dev/null | head -1 | grep -q '<[^>]*UP'; then
  print -u2 "AWDL is active; disable awdl0 before the final latency/stability run, then retry"
  exit 2
fi
: "${RDN_PASSWORD:?Set RDN_PASSWORD securely in this MBP shell}"

app="$HOME/Applications/FarPane.app"
core="$app/Contents/Frameworks/liblibrustdesk.dylib"
prefix_base="$repo_dir/Benchmarks/productization-live-4k-relay-acceptance-1800s"
prefix="$prefix_base"
attempt=1
while [[ -e "$prefix.json" || -e "$prefix.samples.csv" || -e "$prefix.log" ||
         -e "$prefix.validation.txt" || -e "$prefix.functional-validation.txt" ]]; do
  (( attempt += 1 ))
  prefix="${prefix_base}-attempt${attempt}"
done
functional_validation="$prefix.functional-validation.txt"
tcc_validation="$prefix.tcc-rebuild-validation.txt"
evidence_dir="$repo_dir/Evidence/IntelMBP/$(date +%F)/Productization"

[[ -x "$app/Contents/MacOS/RustDeskNative" ]] || { print -u2 "installed product app not found: $app"; exit 2; }
[[ -f "$core" ]] || { print -u2 "bundled universal Core not found: $core"; exit 2; }
[[ ! -e "$evidence_dir" ]] || { print -u2 "refusing to overwrite productization evidence: $evidence_dir"; exit 2; }
codesign --verify --deep --strict "$app"
requirement=$(codesign -d -r- "$app" 2>&1 | tail -1)
[[ "$requirement" != *"cdhash"* ]] || { print -u2 "installed app has an unstable CDHash requirement"; exit 2; }

print "Productization acceptance will run for 30 minutes on the installed stable-identity app."
print "Before starting, launch the app normally and confirm the generic connection form and sanitized validation error."
print "During the run, cover click, drag, scroll, local Chinese/English text, key repeat, common shortcuts,"
print "exclusive Command-Space/Command-Tab plus ⌃⌥⇧Esc, full screen and HUD."
print "Use 验收记录 to save only feedback observed on the real remote Mac."

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
    "exclusive-keyboard", "fullscreen", "hud", "error-state",
}
checks = report.get("functionalChecks", {})
failures = []

def require(condition, message):
    if not condition:
        failures.append(message)

require(report.get("inputPointerMoves", 0) >= 30, "too few accepted pointer moves")
require(report.get("inputButtonDowns", 0) >= 2, "click/drag evidence missing")
require(report.get("inputButtonDowns", 0) == report.get("inputButtonUps", 0), "button events are unbalanced")
require(report.get("inputScrollEvents", 0) >= 3, "scroll evidence missing")
require(report.get("inputKeyDowns", 0) >= 12, "keyboard evidence missing")
require(report.get("inputKeyDowns", 0) == report.get("inputKeyUps", 0), "key events are unbalanced")
require(report.get("inputRejectedEvents", 0) == 0, "Core rejected input events")
require(report.get("exclusiveKeyboardActivations", 0) >= 1, "exclusive keyboard was not activated")
require(report.get("exclusiveKeyboardFailures", 0) == 0, "exclusive keyboard reported a failure")
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
    "inputKeyDowns", "inputKeyUps", "inputRejectedEvents",
    "exclusiveKeyboardActivations", "exclusiveKeyboardFailures",
    "fullscreenToggles", "hudToggles",
):
    print(f"{key}={report.get(key, 0)}")
print(f"functionalValidation={'passed' if not failures else 'failed'}")
if failures:
    for failure in failures:
        print(f"failure={failure}")
    raise SystemExit(1)
PY

/usr/bin/python3 "$repo_dir/Scripts/validate_tcc_rebuild.py" \
  "$repo_dir/Benchmarks" "$app" > "$tcc_validation"

cat "$functional_validation"
cat "$tcc_validation"
stage=$(mktemp -d "${TMPDIR:-/tmp}/rdn-product-evidence.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$prefix.json" "$stage/report.json"
cp "$prefix.samples.csv" "$stage/samples.csv"
cp "$prefix.log" "$stage/app.log"
cp "$prefix.validation.txt" "$stage/pipeline-validation.txt"
cp "$functional_validation" "$stage/functional-validation.txt"
cp "$tcc_validation" "$stage/tcc-rebuild-validation.txt"

/usr/bin/python3 - "$repo_dir/Benchmarks" "$tcc_validation" "$stage" <<'PY'
import shutil
import sys
from pathlib import Path

benchmarks = Path(sys.argv[1])
validation = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
stage = Path(sys.argv[3])
values = dict(line.split("=", 1) for line in validation if "=" in line)
for role in ("baseline", "rebuild"):
    prefix = values[f"{role}Prefix"]
    for suffix, output in (
        ("json", "report.json"),
        ("functional-validation.txt", "functional-validation.txt"),
        ("product-identity.txt", "product-identity.txt"),
    ):
        shutil.copy2(benchmarks / f"{prefix}.{suffix}", stage / f"tcc-{role}-{output}")
PY

{
  print "acceptanceDate=$(date +%F)"
  print "machineArchitecture=$(uname -m)"
  print "macOSVersion=$(sw_vers -productVersion)"
  print "xcodeVersion=$(xcodebuild -version | tr '\n' ' ')"
  print "swiftVersion=$(swift --version | head -1)"
  print "rustVersion=$(rustc --version)"
  print "bundleIdentifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"
  print "buildNumber=$(/usr/bin/plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
  print "viewerSHA256=$(shasum -a 256 "$app/Contents/MacOS/RustDeskNative" | awk '{print $1}')"
  print "coreSHA256=$(shasum -a 256 "$core" | awk '{print $1}')"
  print "rustDeskCommit=$(git -C "$repo_dir/Vendor/rustdesk" rev-parse HEAD)"
} > "$stage/environment.txt"
{
  print '# FarPane productization evidence'
  print
  print 'This directory contains a successful 30-minute real secure-relay run from'
  print 'the stable-identity installed Intel app to the 4096x2304 Mac mini. It also'
  print 'contains two successful exclusive-keyboard preflights from different viewer'
  print 'builds with the same designated signing requirement and no repeated TCC grant.'
  print 'No fixture is represented as live evidence and no connection credential is retained.'
} > "$stage/README.md"
(
  cd "$stage"
  shasum -a 256 * > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
mkdir -p "${evidence_dir:h}"
mv "$stage" "$evidence_dir"
trap - EXIT INT TERM
print "PRODUCTIZATION_ACCEPTANCE_PASSED=true"
print "PRODUCTIZATION_EVIDENCE=$evidence_dir"
