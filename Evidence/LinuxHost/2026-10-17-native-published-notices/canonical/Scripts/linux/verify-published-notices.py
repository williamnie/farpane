#!/usr/bin/env python3
"""Verify published source matches and notices already shipped in a candidate."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Linux/packaging'))
import native_published_notices

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    args = parser.parse_args()
    print(json.dumps(native_published_notices.verify(args.artifact), indent=2))
