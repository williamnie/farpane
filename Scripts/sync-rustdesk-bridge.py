#!/usr/bin/env python3
"""Copy or verify the complete canonical bridge, including its topical Rust files."""

import argparse
from pathlib import Path
import shutil

REPOSITORY = Path(__file__).resolve().parent.parent
CANONICAL = REPOSITORY / "CoreBridge/RustDeskPatch"
ENTRIES = ("rdn_bridge.rs", "rdn_host_bridge.rs", "rdn_host_file_transfer.rs")


def sources(root=CANONICAL):
    files = [root / name for name in ENTRIES]
    for name in (Path(entry).stem for entry in ENTRIES):
        files.extend(sorted((root / name).rglob("*.rs")))
    return files


def sync(destination, *, check=False, root=CANONICAL):
    mismatches = []
    for source in sources(root):
        relative = source.relative_to(root)
        target = destination / relative
        if check:
            if not target.is_file() or source.read_bytes() != target.read_bytes():
                mismatches.append(relative.as_posix())
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    return mismatches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--destination", type=Path, default=REPOSITORY / "Vendor/rustdesk/src")
    args = parser.parse_args()
    mismatches = sync(args.destination, check=args.check)
    for path in mismatches:
        print(f"RustDesk generated bridge differs from canonical source: {path}")
    return bool(mismatches)


if __name__ == "__main__":
    raise SystemExit(main())
