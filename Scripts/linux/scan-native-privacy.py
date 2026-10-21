#!/usr/bin/env python3
"""Check extracted payloads or tar/ZIP/DEB archives, including binary contents."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Linux/packaging'))
from native_privacy import Scanner, rules

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('paths', nargs='+', type=Path)
parser.add_argument('--patterns', type=Path)
args = parser.parse_args()
scanner = Scanner(rules(args.patterns))
for path in args.paths:
    scanner.path(path)
print(json.dumps(scanner.report(), indent=2))
raise SystemExit(bool(scanner.hits))
