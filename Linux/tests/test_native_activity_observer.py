"""Unknown, stale, malformed and partial observations must never mean idle."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import socket
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('observer', Path(__file__).resolve().parents[2] /
                                             'Scripts/linux/observe-native-activity.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
runner_spec = importlib.util.spec_from_file_location('gpu_runner', Path(__file__).resolve().parents[2] /
                                                    'Scripts/linux/run-native-gpu-test.py')
runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner)


class ActivityTest(unittest.TestCase):
    def activity(self, **change):
        return dict(schema=1, process_start=42, generation=1, observed_ms=5000,
                    inbound=0, pending_approvals=0, file_jobs=0, media_owners=0) | change

    def test_only_fresh_same_owner_zero_counters_are_idle(self):
        self.assertEqual(observer.validate_activity(self.activity(), 42, 8000), 0)
        for field in observer.COUNTS:
            with self.subTest(field=field):
                self.assertGreater(observer.validate_activity(self.activity(**{field: 1}), 42, 5000), 0)

    def test_unknown_stale_future_and_wrong_owner_are_errors(self):
        for value, start, now in [(None, 42, 5000), ({}, 42, 5000),
                                  (self.activity(), 43, 5000), (self.activity(), 42, 8001),
                                  (self.activity(), 42, 4999),
                                  (self.activity(schema=2), 42, 5000),
                                  (self.activity(generation=0), 42, 5000),
                                  (self.activity(extra=0), 42, 5000)]:
            with self.subTest(value=value, start=start, now=now), self.assertRaises(ValueError):
                observer.validate_activity(value, start, now)

    def test_counts_reject_bool_negative_float_and_overflow(self):
        for field in observer.COUNTS:
            for value in (False, -1, 0.0, '0', 1 << 32):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    observer.validate_activity(self.activity(**{field: value}), 42, 5000)

    def frame(self, body):
        width = next(n for n in range(1, 5) if len(body) < (1 << (8*n-2)))
        return ((len(body) << 2) | (width-1)).to_bytes(width, 'little') + body

    def receive(self, payload, close=True):
        left, right = socket.socketpair()
        with left, right:
            right.sendall(payload)
            if close:
                right.shutdown(socket.SHUT_WR)
            return observer.read_frame(left, time.monotonic() + .03)

    def test_wire_roundtrip_then_activity_validation(self):
        value = self.receive(self.frame(json.dumps({'t': 'NativeActivity', 'c': self.activity()}).encode()))
        self.assertEqual(observer.validate_activity(value, 42, 5000), 0)

    def test_missing_unsupported_and_malformed_wire_are_errors(self):
        for payload in (b'', b'\x01', self.frame(b'not-json'),
                        self.frame(b'{"t":"VideoConnCount","c":0}'),
                        self.frame(b'{"t":"NativeActivity","c":null,"extra":0}'),
                        self.frame(b'[]'), b'\x00', ((4097 << 2)|1).to_bytes(2, 'little')):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.receive(payload)

    def test_partial_peer_cannot_extend_absolute_deadline(self):
        began = time.monotonic()
        with self.assertRaises((ValueError, TimeoutError)):
            self.receive(b'\x10{', close=False)
        self.assertLess(time.monotonic() - began, .5)

    def test_watch_deadline_cannot_be_extended_by_always_readable_input(self):
        with (mock.patch.object(observer.sys, 'argv', ['observer', '--uid', '1000',
                                                     '--release', '/opt/farpane/releases/test', '--watch']),
              mock.patch.object(observer.os, 'geteuid', return_value=0),
              mock.patch.object(observer, 'installed_core', return_value=Path('/fixture/core')),
              mock.patch.object(observer.time, 'monotonic', side_effect=[0, 121]),
              mock.patch.object(observer.select, 'select') as wait,
              self.assertRaises(ValueError)):
            observer.main()
        wait.assert_not_called()

    def test_watch_eof_exits_and_partial_request_never_queries_host(self):
        for request in (b'', b'o'):
            with (mock.patch.object(observer.sys, 'argv', ['observer', '--uid', '1000',
                                                         '--release', '/opt/farpane/releases/test', '--watch']),
                  mock.patch.object(observer.os, 'geteuid', return_value=0),
                  mock.patch.object(observer, 'installed_core', return_value=Path('/fixture/core')),
                  mock.patch.object(observer.time, 'monotonic', return_value=0),
                  mock.patch.object(observer.select, 'select', return_value=([1], [], [])),
                  mock.patch.object(observer.os, 'read', return_value=request),
                  mock.patch.object(observer, 'observe') as query):
                if request:
                    with self.assertRaises(ValueError):
                        observer.main()
                else:
                    observer.main()
                query.assert_not_called()


class RunnerGuardTest(unittest.TestCase):
    def exercise(self, observations, starts_container):
        class Monitor:
            last = None
            closed = False
            def __enter__(self):
                self.values = iter(observations)
                return self
            def count(self):
                value = next(self.values)
                if isinstance(value, Exception):
                    raise value
                return value
            def __exit__(self, *_):
                self.closed = True
        monitor = Monitor()
        process = mock.Mock()
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Build/Linux').mkdir(parents=True)
            (root / 'Linux').mkdir()
            (root / 'Linux/dependencies.lock.json').write_text(json.dumps({
                'native_display_test': {'image': 'fixture-image'}}))
            with (mock.patch.object(runner, 'ROOT', root),
                  mock.patch.object(runner.sys, 'argv', ['gpu-runner', '--viewer']),
                  mock.patch.object(runner, 'ActivityMonitor', return_value=monitor),
                  mock.patch.object(runner.subprocess, 'Popen', return_value=process) as spawn,
                  mock.patch.object(runner.subprocess, 'run') as cleanup,
                  contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError)):
                runner.main()
            self.assertTrue(monitor.closed)
            if starts_container:
                spawn.assert_called_once()
                command = spawn.call_args.args[0]
                self.assertEqual(command[:3], ['docker', 'run', '--rm'])
                name = command[command.index('--name')+1]
                self.assertTrue(name.startswith('farpane-native-gpu-probe-'))
                cleanup.assert_called_once_with(['docker', 'rm', '-f', name], check=False, timeout=10)
                process.wait.assert_called_once_with(timeout=10)
            else:
                spawn.assert_not_called()
                cleanup.assert_not_called()

    def test_busy_or_unknown_before_start_never_launches_container(self):
        for value in (1, RuntimeError('unknown')):
            with self.subTest(value=value):
                self.exercise([value], False)

    def test_busy_or_unknown_during_probe_stops_only_owned_container(self):
        for value in (1, RuntimeError('unknown')):
            with self.subTest(value=value):
                self.exercise([0, value], True)

    def test_native_observer_failure_never_falls_back_to_legacy_query(self):
        monitor = runner.ActivityMonitor()
        with mock.patch.object(runner, 'legacy_connection_count') as legacy, self.assertRaises(RuntimeError):
            monitor.count()
        legacy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
