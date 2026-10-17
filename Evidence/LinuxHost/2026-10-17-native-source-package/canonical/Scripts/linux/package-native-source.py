#!/usr/bin/env python3
"""Package canonical/pinned native sources using already available offline caches."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_source_bundle

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--vendor-config', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'Build/Linux/source-bundles')
    parser.add_argument('--source-build', type=Path, help='Bind source delivery to an isolated source build instead of the product cache')
    args = parser.parse_args()
    print(json.dumps(native_source_bundle.package(args.reference, args.vendor, args.vendor_config,
                                                args.output, args.source_build), indent=2))
