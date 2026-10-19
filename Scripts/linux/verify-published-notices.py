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
    parser.add_argument('--source-snapshot', type=Path,
                        help='Revalidate archived package proofs using a frozen extracted source snapshot')
    parser.add_argument('--source-manifest-sha256',
                        help='Expected SHA-256 of that snapshot manifest; required with --source-snapshot')
    args = parser.parse_args()
    if bool(args.source_snapshot) != bool(args.source_manifest_sha256):
        parser.error('--source-snapshot and --source-manifest-sha256 must be supplied together')
    result = (native_published_notices.verify_frozen(args.artifact, args.source_snapshot,
                                                   args.source_manifest_sha256)
              if args.source_snapshot else native_published_notices.verify(args.artifact))
    print(json.dumps(result, indent=2))
