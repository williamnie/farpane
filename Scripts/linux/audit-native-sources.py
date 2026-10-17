#!/usr/bin/env python3
"""Collect local pinned native dependency notices; no builds or network access."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_sources

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-metadata', required=True, type=Path)
    parser.add_argument('--gui-metadata', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'Build/Linux/source-audit')
    args = parser.parse_args()
    print(json.dumps(native_sources.inventory(args.core_metadata, args.gui_metadata, args.output), indent=2))
