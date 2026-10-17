#!/usr/bin/env python3
"""Build, test and package a verified Linux native source archive; never deploy."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
from native_ci import pipeline

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--archive', type=Path)
    source.add_argument('--source-url')
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--builder-image', default='farpane-native-source-builder:ubuntu2404')
    parser.add_argument('--runtime-image', default='farpane-native-ci-runtime:ubuntu2404')
    parser.add_argument('--reuse-images', action='store_true', help='Explicit local validation with existing images')
    parser.add_argument('--reuse-build', type=Path, help='Validate a completed build; report that compilation was skipped')
    parser.add_argument('--reuse-sdk', type=Path)
    parser.add_argument('--offline-tools', action='store_true')
    pipeline(parser.parse_args())
