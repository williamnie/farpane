#!/usr/bin/env python3
"""Resolve private ASan allocation stacks against the exact runtime ELF files.

Run inside the pinned native_display_test image. This is allocation attribution,
not an ASan application-instruction audit or a product PSS/CPU measurement.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def parse(text):
    reports = []
    for marker in re.finditer(r'(?m)^FARPANE_ALLOCATION_PROFILE_BEGIN=(\d+)\n', text):
        second = int(marker[1])
        end = f'FARPANE_ALLOCATION_PROFILE_END={second}\n'
        assert text[marker.end():].count(end) == 1
        body = text[marker.end():].split(end, 1)[0]
        total = re.search(r'Live Heap Allocations: (\d+) bytes in (\d+) chunks; quarantined: (\d+) bytes', body)
        assert total, second
        contexts = []
        for entry in re.finditer(r'(?m)^(\d+) byte\(s\) \((\d+)%\) in (\d+) allocation\(s\)\n(.*?)(?=\n\d+ byte\(s\)|\Z)', body, re.S):
            frames = []
            for line in entry[4].splitlines():
                if not line.strip():
                    continue
                frame = re.fullmatch(r'\s+#(\d+) (0x[0-9a-f]+)  \((/[^\n]+?)\+(0x[0-9a-f]+)\) \(BuildId: ([0-9a-f]+)\)', line)
                # Retain unknown/truncated frames explicitly, never drop a row
                # and silently inflate the apparent coverage.
                frames.append(dict(index=int(frame[1]), address=frame[2], object=frame[3],
                                   offset=frame[4], build_id=frame[5]) if frame else {'unresolved': line})
            contexts.append({'bytes': int(entry[1]), 'allocations': int(entry[3]), 'frames': frames})
        shown = sum(context['bytes'] for context in contexts)
        chunks = sum(context['allocations'] for context in contexts)
        assert 0 <= shown <= int(total[1]) and 0 <= chunks <= int(total[2])
        reports.append(dict(seconds=second, live_requested_bytes=int(total[1]), live_chunks=int(total[2]),
                            quarantined_bytes=int(total[3]), shown_bytes=shown, shown_chunks=chunks,
                            omitted_bytes=int(total[1])-shown, omitted_chunks=int(total[2])-chunks,
                            coverage=shown/int(total[1]), contexts=contexts))
    assert reports
    return reports


def analyze(run, artifact):
    assert Path('/.dockerenv').is_file()
    run = run.resolve(strict=True)
    artifact = artifact.resolve(strict=True)
    assert run.is_relative_to('/workspace/Build/Linux') and artifact.is_relative_to('/workspace/Build/Linux/artifacts')
    assert json.loads((run/'test-binaries.json').read_text())['farpane'] == digest(artifact/'farpane')
    reports = parse((run/'home-gui.log').read_text())
    assert [r['seconds'] for r in reports] in ([8, 20], [20])
    objects = defaultdict(dict)
    for report in reports:
        for context in report['contexts']:
            for frame in context['frames']:
                if 'object' in frame:
                    objects[frame['object']][frame['offset']] = frame['build_id']
    symbols, files = {}, {}
    for name, offsets in sorted(objects.items()):
        path = Path(name)
        if name == '/opt/farpane-native-test/releases/native-smoke-1/farpane':
            path = artifact/'farpane'
        else:
            assert any(path.is_relative_to(root) for root in ('/usr/lib', '/lib', '/lib64', run)), name
        assert path.is_file(), path
        notes = subprocess.check_output(['readelf', '-n', str(path)], text=True)
        build_id = re.search(r'Build ID: ([0-9a-f]+)', notes)
        assert build_id and set(offsets.values()) == {build_id[1]}, (name, build_id, set(offsets.values()))
        addresses = sorted(offsets, key=lambda x: int(x,16))
        lines = subprocess.check_output(['addr2line', '-f', '-C', '-e', str(path), *addresses], text=True).splitlines()
        assert len(lines) == len(addresses)*2, name
        for i, offset in enumerate(addresses):
            # Stripped DSOs may yield the nearest exported symbol, even when
            # the address belongs to an unrelated hidden function. Keep this
            # as a hint; only object + verified Build ID + offset are exact.
            symbols[(name, offset)] = {'function_hint': lines[i*2], 'location': lines[i*2+1],
                                      'source_location_resolved': not lines[i*2+1].startswith('??')}
        files[name] = {'resolved_path': str(path), 'build_id': build_id[1], 'sha256': digest(path), 'addresses': len(addresses)}
    for report in reports:
        origins = Counter()
        for context in report['contexts']:
            for frame in context['frames']:
                if 'object' in frame:
                    frame.update(symbols[(frame['object'], frame['offset'])])
            first = next((f for f in context['frames'] if 'object' in f and 'libasan.so' not in f['object']), None)
            name = first['object'] if first else 'unresolved'
            context['first_non_asan_object'] = name
            origins[name] += context['bytes']
        report['bytes_by_first_non_asan_object'] = dict(origins.most_common())
    result = dict(schema=1, measurement='ASan-interposed-live-requested-allocations',
                  product_pss_cpu_measurement=False, application_instruction_instrumentation=False,
                  all_process_memory_covered=False, gui_sha256=digest(artifact/'farpane'),
                  reports=reports, symbol_files=files,
                  caveat='First non-ASan frame identifies an allocation call site, not final ownership. '
                         'addr2line function hints without source locations may be nearest exported symbols, not exact functions. '
                         'Direct mappings, file pages, GPU storage, allocator metadata and omitted contexts are separate.')
    (run/'allocation-analysis.json').write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    print(json.dumps({'symbol_files':len(files), 'reports':[{k:v for k,v in r.items() if k!='contexts'} for r in reports]}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--artifact', type=Path, required=True)
    args = parser.parse_args()
    analyze(args.run, args.artifact)
