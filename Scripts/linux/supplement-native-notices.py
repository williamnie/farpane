#!/usr/bin/env python3
"""Collect pinned local notice followups for a frozen native material inventory."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_notice_supplements

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audit', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'Build/Linux/source-audit')
    args = parser.parse_args()
    print(json.dumps(native_notice_supplements.collect(args.audit, args.output), indent=2))
