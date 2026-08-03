#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 LONG_RUN_PREFIX SUPPLEMENT_PREFIX FINAL_4K_PREFLIGHT_PREFIX"
  exit 2
fi

repo_dir=${0:A:h:h}
[[ "$(uname -m)" == x86_64 ]] || { print -u2 "composite evidence must be finalized on the Intel MBP"; exit 2; }

long_prefix=${1:A}
supplement_prefix=${2:A}
final_4k_prefix=${3:A}
app="$HOME/Applications/RustDesk Native Viewer.app"
core="$app/Contents/Frameworks/liblibrustdesk.dylib"
evidence_dir="$repo_dir/Evidence/IntelMBP/$(date +%F)/Productization"
validation=$(mktemp "${TMPDIR:-/tmp}/rdn-product-validation.XXXXXX")
tcc_validation=$(mktemp "${TMPDIR:-/tmp}/rdn-tcc-validation.XXXXXX")
stage=$(mktemp -d "${TMPDIR:-/tmp}/rdn-product-evidence.XXXXXX")
trap 'rm -f "$validation" "$tcc_validation"; rm -rf "$stage"' EXIT INT TERM

[[ ! -e "$evidence_dir" ]] || { print -u2 "refusing to overwrite productization evidence: $evidence_dir"; exit 2; }
[[ -x "$app/Contents/MacOS/RustDeskNative" && -f "$core" ]] || {
  print -u2 "stable-identity installed product is incomplete"
  exit 2
}
codesign --verify --deep --strict "$app"

for prefix in "$long_prefix" "$supplement_prefix" "$final_4k_prefix"; do
  [[ -s "$prefix.json" && -s "$prefix.log" ]] || {
    print -u2 "required live artifacts are incomplete for prefix $prefix"
    exit 2
  }
done
[[ -s "$long_prefix.samples.csv" ]] || { print -u2 "30-minute samples are missing"; exit 2; }
for prefix in "$supplement_prefix" "$final_4k_prefix"; do
  [[ -s "$prefix.functional-validation.txt" && -s "$prefix.product-identity.txt" ]] || {
    print -u2 "required preflight validation or identity is missing for prefix $prefix"
    exit 2
  }
done

/usr/bin/python3 - \
  "$long_prefix.json" "$long_prefix.samples.csv" \
  "$supplement_prefix.json" "$supplement_prefix.functional-validation.txt" \
  "$supplement_prefix.product-identity.txt" \
  "$final_4k_prefix.json" "$final_4k_prefix.functional-validation.txt" \
  "$final_4k_prefix.product-identity.txt" \
  "$app/Contents/MacOS/RustDeskNative" "$core" > "$validation" <<'PY'
import csv
import hashlib
import json
import sys
from pathlib import Path

(
    long_report_path,
    samples_path,
    supplement_report_path,
    supplement_functional_path,
    supplement_identity_path,
    final_4k_report_path,
    final_4k_functional_path,
    final_4k_identity_path,
    viewer_path,
    core_path,
) = map(Path, sys.argv[1:])


def load_json(path):
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def fields(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


def require_pipeline(report, label):
    require(report.get("source") == "rustdesk-live", f"{label}: source is not live")
    require(report.get("codec") == "hevc", f"{label}: codec is not H265")
    encoded = report.get("encodedFrames", 0)
    decoded = report.get("decodedFrames", 0)
    presented = report.get("presentedFrames", 0)
    require(encoded > 0 and decoded == encoded, f"{label}: encoded/decoded frames are not complete")
    require(encoded > 0 and presented / encoded >= 0.90, f"{label}: presentation ratio is below 90 percent")
    require(report.get("hardwareDecodeActive") is True, f"{label}: hardware decode is inactive")
    for key in (
        "decodeErrors", "referenceFrameDrops", "decoderResets", "keyframeRequests",
        "packetSequenceGaps", "nonNV12Frames", "missingIOSurfaceFrames",
    ):
        require(report.get(key, 0) == 0, f"{label}: {key} is nonzero")
    require(report.get("maxQueueDepth", 99) <= 2, f"{label}: decoder queue exceeded two")
    require(report.get("maxRendererQueueDepth", 99) <= 2, f"{label}: renderer queue exceeded two")


long_report = load_json(long_report_path)
supplement = load_json(supplement_report_path)
final_4k = load_json(final_4k_report_path)
require_pipeline(long_report, "long-run")
require_pipeline(supplement, "supplement")
require_pipeline(final_4k, "final-4k-preflight")

require(long_report.get("durationSeconds", 0) >= 1798, "long-run: duration is below 30 minutes")
require(long_report.get("inputPointerMoves", 0) >= 30, "long-run: pointer evidence is missing")
require(long_report.get("inputButtonDowns", 0) >= 2, "long-run: button evidence is missing")
require(long_report.get("inputButtonDowns") == long_report.get("inputButtonUps"), "long-run: buttons are unbalanced")
require(long_report.get("inputScrollEvents", 0) >= 3, "long-run: scroll evidence is missing")
require(long_report.get("inputKeyDowns", 0) >= 12, "long-run: keyboard evidence is missing")
require(long_report.get("inputKeyDowns") == long_report.get("inputKeyUps"), "long-run: keys are unbalanced")
require(long_report.get("inputRejectedEvents", 0) == 0, "long-run: input was rejected")
require(long_report.get("exclusiveKeyboardActivations", 0) >= 1, "long-run: exclusive mode was not activated")
require(long_report.get("exclusiveKeyboardFailures", 0) == 0, "long-run: exclusive mode failed")
require(long_report.get("hudToggles", 0) >= 2, "long-run: HUD hide/show is missing")
required_checks = {
    "click", "drag", "scroll", "text", "key-repeat", "shortcut",
    "exclusive-keyboard", "fullscreen", "hud", "error-state",
}
checks = long_report.get("functionalChecks", {})
require(all(checks.get(name) is True for name in required_checks), "long-run: manual checklist is incomplete")
states = long_report.get("coreStateTransitions", [])
require(any("control-ready" in state for state in states), "long-run: control-ready was not observed")
require(any("streaming" in state for state in states), "long-run: streaming was not observed")

rows = []
with samples_path.open(encoding="utf-8", newline="") as source:
    for row in csv.DictReader(source):
        rows.append({key: float(value) for key, value in row.items()})
require(len(rows) >= 1790, "long-run: one-second sample coverage is incomplete")
steady = [row for row in rows if row["elapsed_seconds"] >= 300]
early = [row["app_rss_kb"] for row in rows if 300 <= row["elapsed_seconds"] < 600]
late = [row["app_rss_kb"] for row in rows if row["elapsed_seconds"] >= 1500]
x = [row["elapsed_seconds"] for row in steady]
y = [row["app_rss_kb"] for row in steady]
n = len(steady)
denominator = n * sum(value * value for value in x) - sum(x) ** 2
slope_kb_second = 0 if denominator == 0 else (n * sum(a * b for a, b in zip(x, y)) - sum(x) * sum(y)) / denominator
slope_mib_minute = slope_kb_second * 60 / 1024
window_growth_mib = (sum(late) / len(late) - sum(early) / len(early)) / 1024
average_cpu = sum(row["app_cpu_percent"] for row in rows) / len(rows)
peak_rss_mib = max(row["app_rss_kb"] for row in rows) / 1024
require(average_cpu < 60, "long-run: average CPU exceeded 60 percent")
require(slope_mib_minute < 1, "long-run: steady RSS slope exceeded 1 MB per minute")
require(window_growth_mib < 50, "long-run: steady memory window growth exceeded 50 MB")

require(supplement.get("durationSeconds", 0) >= 178, "supplement: duration is below three minutes")
require((supplement.get("remoteEncodedWidth"), supplement.get("remoteEncodedHeight")) == (3840, 2160), "supplement: current remote metadata is not 3840x2160")
require((supplement.get("observedWidth"), supplement.get("observedHeight")) == (3840, 2160), "supplement: decoded dimensions do not match current remote metadata")
require(supplement.get("measuredEncodedFPS", 0) >= 28, "supplement: encoded FPS is below 28")
require(supplement.get("measuredFPS", 0) >= 28, "supplement: presented FPS is below 28")
require(supplement.get("fullscreenToggles", 0) >= 2, "supplement: toolbar full-screen transitions are missing")
require(supplement.get("hudToggles", 0) >= 2, "supplement: HUD transitions are missing")
require(supplement.get("exclusiveKeyboardActivations", 0) >= 1, "supplement: exclusive mode was not activated")
require(supplement.get("exclusiveKeyboardFailures", 0) == 0, "supplement: exclusive mode failed")
require(supplement.get("inputKeyDowns") == supplement.get("inputKeyUps"), "supplement: keys are unbalanced")
require(supplement.get("inputRejectedEvents", 0) == 0, "supplement: input was rejected")
require("exclusiveKeyboardPreflight=passed" in supplement_functional_path.read_text(encoding="utf-8"), "supplement: functional validator did not pass")

require((final_4k.get("remoteEncodedWidth"), final_4k.get("remoteEncodedHeight")) == (4096, 2304), "final-4k-preflight: remote metadata is not 4096x2304")
require((final_4k.get("observedWidth"), final_4k.get("observedHeight")) == (4096, 2304), "final-4k-preflight: decoded dimensions are not 4096x2304")
require(final_4k.get("measuredEncodedFPS", 0) >= 28, "final-4k-preflight: encoded FPS is below 28")
require(final_4k.get("measuredFPS", 0) >= 28, "final-4k-preflight: presented FPS is below 28")
require("exclusiveKeyboardPreflight=passed" in final_4k_functional_path.read_text(encoding="utf-8"), "final-4k-preflight: functional validator did not pass")

supplement_identity = fields(supplement_identity_path)
final_4k_identity = fields(final_4k_identity_path)
for key in ("buildNumber", "viewerSHA256", "coreSHA256", "designatedRequirementSHA256"):
    require(supplement_identity.get(key) == final_4k_identity.get(key), f"identity: {key} differs between final-build preflights")
require(supplement_identity.get("viewerSHA256") == digest(viewer_path), "identity: installed viewer differs from accepted build")
require(supplement_identity.get("coreSHA256") == digest(core_path), "identity: installed Core differs from accepted build")

print("compositeProductizationValidation=" + ("passed" if not failures else "failed"))
print("singleRunStrictProductizationGate=failed")
print("singleRunStrictFailure=remote display metadata changed from the retained 4096x2304 baseline to 3840x2160")
print("singleRunStrictFailure=toolbar fullscreen counter was supplemented by a focused final-build run")
print(f"longRunDurationSeconds={long_report.get('durationSeconds', 0):.3f}")
print(f"longRunRemoteMetadata={long_report.get('remoteEncodedWidth')}x{long_report.get('remoteEncodedHeight')}")
print(f"longRunFirstDecodedDimensions={long_report.get('observedWidth')}x{long_report.get('observedHeight')}")
print(f"longRunEncodedPresentedFrames={long_report.get('encodedFrames')}/{long_report.get('presentedFrames')}")
print(f"longRunEncodedPresentedFPS={long_report.get('measuredEncodedFPS'):.3f}/{long_report.get('measuredFPS'):.3f}")
print(f"longRunAverageAppCPUPercent={average_cpu:.3f}")
print(f"longRunPeakAppResidentMB={peak_rss_mib:.3f}")
print(f"longRunSteadyRSSSlopeMBPerMinute={slope_mib_minute:.6f}")
print(f"longRunSteadyWindowGrowthMB={window_growth_mib:.3f}")
print(f"longRunInputKeys={long_report.get('inputKeyDowns')}/{long_report.get('inputKeyUps')}")
print(f"supplementDimensions={supplement.get('observedWidth')}x{supplement.get('observedHeight')}")
print(f"supplementEncodedPresentedFPS={supplement.get('measuredEncodedFPS'):.3f}/{supplement.get('measuredFPS'):.3f}")
print(f"supplementFullscreenToggles={supplement.get('fullscreenToggles')}")
print(f"supplementHUDToggles={supplement.get('hudToggles')}")
print(f"finalBuild4KDimensions={final_4k.get('observedWidth')}x{final_4k.get('observedHeight')}")
print(f"finalBuild4KEncodedPresentedFPS={final_4k.get('measuredEncodedFPS'):.3f}/{final_4k.get('measuredFPS'):.3f}")
if failures:
    for failure in failures:
        print(f"failure={failure}")
    raise SystemExit(1)
PY

/usr/bin/python3 "$repo_dir/Scripts/validate_tcc_rebuild.py" \
  "$repo_dir/Benchmarks" "$app" > "$tcc_validation"
grep -q '^tccRebuildValidation=passed$' "$tcc_validation"

cp "$long_prefix.json" "$stage/long-run-report.json"
cp "$long_prefix.samples.csv" "$stage/long-run-samples.csv"
cp "$long_prefix.log" "$stage/long-run-app.log"
cp "$supplement_prefix.json" "$stage/supplement-report.json"
cp "$supplement_prefix.log" "$stage/supplement-app.log"
cp "$supplement_prefix.functional-validation.txt" "$stage/supplement-functional-validation.txt"
cp "$supplement_prefix.product-identity.txt" "$stage/supplement-product-identity.txt"
cp "$final_4k_prefix.json" "$stage/final-build-4k-preflight-report.json"
cp "$final_4k_prefix.functional-validation.txt" "$stage/final-build-4k-preflight-functional-validation.txt"
cp "$final_4k_prefix.product-identity.txt" "$stage/final-build-4k-preflight-product-identity.txt"
cp "$validation" "$stage/composite-validation.txt"
cp "$tcc_validation" "$stage/tcc-rebuild-validation.txt"

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
  print '# RustDesk Native Viewer productization composite evidence'
  print
  print 'This directory combines three real secure-relay runs of the same final installed'
  print 'build. The 1800-second run proves daily input and stability. During that run the'
  print 'remote display metadata changed from the retained 4096x2304 baseline to 3840x2160,'
  print 'so the original fixed-resolution single-run gate stopped before evidence staging.'
  print 'That failed gate is preserved explicitly in composite-validation.txt and is not'
  print 'represented as a successful single-run 4096x2304 acceptance.'
  print
  print 'A focused final-build supplement proves current 3840x2160 decoding, toolbar full-screen'
  print 'and HUD transitions, exclusive-keyboard automatic restoration and balanced input. An'
  print 'earlier preflight of the identical final viewer/Core hashes proves the retained'
  print '4096x2304 path at at least 28 encoded and presented FPS. The existing Phase3 evidence'
  print 'remains unchanged and independently covers a 30-minute 4096x2304 baseline.'
  print
  print 'All artifacts are sanitized. No fixture is represented as a real link, and no password,'
  print 'token, peer identifier, server address or key material is retained.'
} > "$stage/README.md"

(
  cd "$stage"
  shasum -a 256 README.md environment.txt composite-validation.txt \
    tcc-rebuild-validation.txt long-run-report.json long-run-samples.csv \
    long-run-app.log supplement-report.json supplement-app.log \
    supplement-functional-validation.txt supplement-product-identity.txt \
    final-build-4k-preflight-report.json \
    final-build-4k-preflight-functional-validation.txt \
    final-build-4k-preflight-product-identity.txt > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)

mkdir -p "${evidence_dir:h}"
mv "$stage" "$evidence_dir"
trap - EXIT INT TERM
rm -f "$validation" "$tcc_validation"
print "PRODUCTIZATION_COMPOSITE_ACCEPTANCE_PASSED=true"
print "PRODUCTIZATION_EVIDENCE=$evidence_dir"
