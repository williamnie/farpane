#!/usr/bin/python3
import plistlib
import sys
from pathlib import Path


def parse_fields(path):
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def select_builds(records, current_build):
    rebuild = next(
        (record for record in records if record[1].get("buildNumber") == current_build),
        None,
    )
    if rebuild is None:
        raise ValueError("current installed build does not have a successful preflight")
    baseline = next(
        (
            record
            for record in records
            if record[1].get("buildNumber") != rebuild[1].get("buildNumber")
            and record[1].get("codeDirectoryHash") != rebuild[1].get("codeDirectoryHash")
            and record[1].get("designatedRequirementSHA256")
            == rebuild[1].get("designatedRequirementSHA256")
        ),
        None,
    )
    if baseline is None:
        raise ValueError(
            "no successful earlier build with the same signing requirement was found"
        )
    return baseline, rebuild


def successful_preflights(benchmarks):
    passed = []
    for identity in sorted(
        benchmarks.glob("exclusive-keyboard-preflight-*-180s.product-identity.txt"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    ):
        prefix = identity.name.removesuffix(".product-identity.txt")
        functional = benchmarks / f"{prefix}.functional-validation.txt"
        report = benchmarks / f"{prefix}.json"
        if not functional.is_file() or not report.is_file():
            continue
        if (
            "exclusiveKeyboardPreflight=passed"
            not in functional.read_text(encoding="utf-8")
        ):
            continue
        passed.append((prefix, parse_fields(identity)))
    return passed


def main(argv):
    if len(argv) != 3:
        raise SystemExit(f"usage: {argv[0]} BENCHMARKS_DIR INSTALLED_APP")
    benchmarks = Path(argv[1])
    app = Path(argv[2])
    records = successful_preflights(benchmarks)
    if not records:
        raise SystemExit("no successful product preflight found")
    with (app / "Contents/Info.plist").open("rb") as plist_file:
        current_build = str(plistlib.load(plist_file)["CFBundleVersion"])
    try:
        baseline, rebuild = select_builds(records, current_build)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    print("tccRebuildValidation=passed")
    print(f"baselinePrefix={baseline[0]}")
    print(f"baselineBuildNumber={baseline[1]['buildNumber']}")
    print(f"rebuildPrefix={rebuild[0]}")
    print(f"rebuildBuildNumber={rebuild[1]['buildNumber']}")
    print(
        "designatedRequirementSHA256="
        f"{rebuild[1]['designatedRequirementSHA256']}"
    )
    print("appCodeDirectoryChanged=true")
    print("reauthorizationRequired=false")


if __name__ == "__main__":
    main(sys.argv)
