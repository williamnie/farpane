#!/usr/bin/env python3
"""只保留已安装 FarPane 的应用注册；不删除副本、不重置系统权限。"""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess


BUNDLE_ID = "io.rustdesknative.viewer"
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)


def registered_paths(dump: str) -> list[Path]:
    paths = []
    for block in re.split(r"\n-{10,}\n", dump):
        identifier = re.search(r"^identifier:\s+(\S+)\s*$", block, re.MULTILINE)
        if not identifier or identifier.group(1) != BUNDLE_ID:
            continue
        match = re.search(
            r"^path:\s+(.+?)\s+\(0x[0-9a-fA-F]+\)\s*$", block, re.MULTILINE
        )
        if not match or not Path(match.group(1)).is_absolute():
            raise ValueError("Cannot safely parse a FarPane registration path")
        path = Path(match.group(1)).resolve()
        if path not in paths:
            paths.append(path)
    return paths


def register_installed_app(installed: Path, run=subprocess.run) -> list[Path]:
    installed = installed.resolve()
    info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Installed bundle is not FarPane")
    run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    before = run([LSREGISTER, "-dump"], check=True, capture_output=True, text=True)
    duplicates = [path for path in registered_paths(before.stdout) if path != installed]
    for path in duplicates:
        # 旧记录可能已被系统并发移除，以最后一次数据库核验为准。
        run([LSREGISTER, "-u", str(path)], check=False, capture_output=True, text=True)
    run([LSREGISTER, "-f", str(installed)], check=True)
    after = run([LSREGISTER, "-dump"], check=True, capture_output=True, text=True)
    if registered_paths(after.stdout) != [installed]:
        raise RuntimeError("FarPane registration did not converge to the installed app")
    return duplicates


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installed_app", type=Path)
    args = parser.parse_args()
    duplicates = register_installed_app(args.installed_app)
    for path in duplicates:
        print(f"UNREGISTERED_APP={path}")
    print(f"REGISTERED_APP={args.installed_app.resolve()}")


if __name__ == "__main__":
    main()
