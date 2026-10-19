"""Observe a real private native Host while its two video sessions run."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from native_host_smoke import RELEASE

assert Path('/.dockerenv').is_file() and os.geteuid() == 0
assert not Path('/dev/dri').exists() and not os.environ.get('DISPLAY')
output = Path(sys.argv[1])
uid, gid = map(int, sys.argv[2:])
output.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('observer', '/workspace/Scripts/linux/observe-native-activity.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
core = RELEASE / 'libexec/farpane-core'
endpoint = Path(f'/tmp/FarPane-{uid}/ipc')
samples, failures, descriptors = [], [], []
checks = []
with (output / 'viewer.log').open('w') as log:
    child = subprocess.Popen([sys.executable, '-B', '/workspace/Linux/tests/native_viewer_smoke.py',
                              str(output / 'viewer'), str(uid), str(gid)],
                             stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 60
        rejected_identity = False
        while child.poll() is None:
            assert time.monotonic() < deadline, 'Private session deadline exceeded'
            try:
                sample = observer.observe(uid, core, endpoint)
                samples.append(sample)
                descriptors.append(len(list(Path('/proc/self/fd').iterdir())))
                if not rejected_identity:
                    for wrong_uid, wrong_core in ((uid + 1, core), (uid, RELEASE / 'farpane')):
                        try:
                            observer.observe(wrong_uid, wrong_core, endpoint)
                        except ValueError:
                            pass
                        else:
                            raise AssertionError('Mismatched peer identity was accepted')
                    rejected_identity = True
            except (OSError, ValueError) as error:
                # Missing/not-ready/exited is recorded as unknown, never zero.
                failures.append(type(error).__name__)
            time.sleep(.05)
        assert child.returncode == 0, 'Private video fixture failed; inspect viewer.log'
        assert rejected_identity
        checks.append('actual_peer_uid_and_executable_mismatch_rejected')
        assert samples and samples[0]['idle']
        checks.append('live_idle_host_accepted')
        active = [i for i, s in enumerate(samples) if s['activity']['inbound'] > 0]
        assert active and all(not samples[i]['idle'] for i in active)
        assert any(s['activity']['media_owners'] > 0 for s in samples)
        checks.append('real_inbound_video_and_media_owners_block_probe')
        assert any(s['idle'] for s in samples[max(active)+1:]), 'No fully drained idle sample after video'
        checks.append('idle_only_after_real_media_resources_drain')
        assert max(descriptors) == min(descriptors), 'Observation leaked a socket or pidfd'
        checks.append('repeated_observations_retain_no_descriptors')
        try:
            observer.observe(uid, core, endpoint)
        except (OSError, ValueError):
            pass
        else:
            raise AssertionError('Exited Host was reported idle')
        checks.append('exited_host_is_unknown_not_idle')
        result = {'result': 'pass', 'checks': checks, 'samples': samples,
                  'unknown_observations': failures, 'observer_fd_count': descriptors[0],
                  'gpu': False, 'display': 'two-private-xvfb', 'real_systemd': False}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'samples'}), flush=True)
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
