#!/usr/bin/env python3
"""Count first-party code consistently, optionally comparing with a Git revision.

Includes runtime code, native adapters, scripts and tests. Excludes dependency
patches (upstream diff/context), vendored/generated builds, docs and evidence.
Reports physical and nonblank lines; formatting changes affect both metrics.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = {".swift", ".rs", ".c", ".h", ".py", ".sh", ".metal"}
DIRECTORIES = {"Sources", "CoreBridge", "Scripts", "Tests", "Benchmarks"}


def git(*args, **kwargs):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], **kwargs)


def included(path):
    return (path == "Package.swift" or path.split("/")[0] in DIRECTORIES) and Path(path).suffix in EXTENSIONS


def contents(revision):
    if revision:
        revision = git("rev-parse", "--verify", "--end-of-options", revision).decode().strip()
        names = git("ls-tree", "-r", "--name-only", revision).decode().splitlines()
        names = [name for name in names if included(name)]
        data = git("cat-file", "--batch", input="".join(f"{revision}:{name}\n" for name in names).encode())
        offset = 0
        for name in names:
            header_end = data.index(b"\n", offset)
            size = int(data[offset:header_end].split()[-1])
            offset = header_end + 1
            yield name, data[offset:offset + size]
            offset += size + 1
    else:
        names = git("ls-files", "--cached", "--others", "--exclude-standard").decode().splitlines()
        for name in sorted(set(names)):
            if included(name) and (ROOT / name).is_file():
                yield name, (ROOT / name).read_bytes()


def measure(revision=None):
    groups = defaultdict(lambda: {"files": 0, "lines": 0, "nonblank": 0})
    for name, data in contents(revision):
        group = groups[name.split("/")[0]]
        lines = data.splitlines()
        group["files"] += 1
        group["lines"] += len(lines)
        group["nonblank"] += sum(bool(line.strip()) for line in lines)
    return {"total": {key: sum(group[key] for group in groups.values())
                      for key in ("files", "lines", "nonblank")}, "groups": dict(groups)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Git revision to compare with the working tree")
    args = parser.parse_args()
    result = {"current": measure()}
    if args.base:
        result["base"] = measure(args.base)
        result["reductionPercent"] = {
            key: round(100 * (1 - result["current"]["total"][key] / result["base"]["total"][key]), 2)
            for key in ("lines", "nonblank")
        }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
