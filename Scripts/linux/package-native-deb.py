#!/usr/bin/env python3
"""Wrap a verified native bundle in a Debian test candidate; no installation."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_deb

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'Build/Linux/debian')
    args = parser.parse_args()
    print(json.dumps(native_deb.build(args.artifact, args.version, args.output), indent=2))
