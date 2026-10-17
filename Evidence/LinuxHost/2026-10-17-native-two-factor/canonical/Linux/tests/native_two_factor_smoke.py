"""Real TOTP challenges against a private Host, using the unchanged GUI bundle.

The secret and identity are disposable container fixtures. Password entry uses
the existing integration driver; OTP submission/cancel use external XTest.
"""
import base64
import ctypes as C
import ctypes.util
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from native_host_smoke import cli, RELEASE, RUNTIME
from native_lifecycle_smoke import Display, children, colored_pixels

# RFC 4226/6238 public SHA1 fixture, never a real device secret.
SECRET = b'12345678901234567890'


def otp(at):
    digest = hmac.new(SECRET, struct.pack('!Q', int(at) // 30), hashlib.sha1).digest()
    offset = digest[-1] & 15
    return f'{(int.from_bytes(digest[offset:offset+4], "big") & 0x7fffffff) % 1000000:06}'


def seed(settings, output):
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    assert settings.resolve().is_relative_to(RUNTIME) and not children(os.getpid())
    # machine-uid 0.3.0 reads these in order; the container's own files are
    # used without mounting or reading the host machine identity.
    identity = next(p for p in (Path('/var/lib/dbus/machine-id'), Path('/etc/machine-id')) if p.is_file())
    key = identity.read_text().strip().encode()[:32].ljust(32, b'\0')
    # Match password_security's v1 randomized nonce envelope.
    sodium = C.CDLL(ctypes.util.find_library('sodium'))
    assert sodium.sodium_init() >= 0
    sodium.crypto_secretbox_easy.argtypes = [C.c_void_p, C.c_void_p, C.c_ulonglong,
                                            C.c_void_p, C.c_void_p]
    nonce = os.urandom(24)
    encrypted = C.create_string_buffer(len(SECRET) + 16)
    assert sodium.crypto_secretbox_easy(encrypted, SECRET, len(SECRET), nonce, key) == 0
    encoded = b'00' + base64.b64encode(b'\x01' + nonce + encrypted.raw)
    info = json.dumps({'name': 'private-two-factor-fixture', 'secret': list(encoded),
                       'digits': 6, 'created_at': int(time.time() * 1000)})
    text = settings.read_text()
    assert '[options]\n' in text and '\n2fa =' not in text
    settings.write_text(text.replace('[options]\n', '[options]\n2fa = ' + json.dumps(info) + '\n', 1))
    (output / 'fixture.json').write_text(json.dumps({
        'synthetic_identity_only': True, 'secret': 'public RFC SHA1 test vector',
        'cipher': 'secretbox v1 envelope; private container machine identity',
        'digits': 6, 'step_seconds': 30, 'network': 'private loopback',
        'system_time_changed': False, 'host_configuration_accessed': False}, indent=2) + '\n')
    assert otp(59) == '287082', 'TOTP generator failed the published 8-digit vector modulo 1e6'


def exercise(output, start, agent, initial, secrets):
    assert os.geteuid() != 0 and Path('/.dockerenv').is_file()
    screen, remote = Display(':92'), Display(':91')
    pattern = remote.x.XCreateSimpleWindow(remote.display, remote.root, 60, 100, 480, 260, 0, 0, 0)
    remote.x.XMapRaised(remote.display, pattern)
    rounds, workers = [], set()
    try:
        for index, scenario in enumerate(('cancel', 'wrong-then-correct')):
            directory = output / scenario
            directory.mkdir()
            color = (0x21906a, 0x8030a0)[index]
            remote.x.XSetWindowBackground(remote.display, pattern, color)
            remote.x.XClearWindow(remote.display, pattern)
            remote.x.XSync(remote.display, 0)
            env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
                       FARPANE_VIEWER_SMOKE_DIR=str(directory), FARPANE_SECRET_ROUND='save',
                       # Reuse the existing 120-second integration window;
                       # this driver disconnects explicitly after its checks.
                       FARPANE_NATIVE_TEST_MODE='recovery')
            gui = start('two-factor-' + scenario, [str(RELEASE / 'farpane')], env)
            def progress():
                try:
                    return json.loads((directory / 'viewer-progress.json').read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    return {}
            def wait(predicate, message, timeout=25):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    assert gui.poll() is None and agent.poll() is None, message + ': GUI/Host exited'
                    state = progress()
                    if state.get('password_attempts') == 1:
                        assert secrets.lookup(initial['server']) is None, 'Wrong password saved'
                        (directory / 'wrong-password-not-stored').touch()
                    value = predicate()
                    if value:
                        return value
                    time.sleep(.04)
                screen.capture(directory / 'failure.png')
                raise AssertionError(message)
            wait(lambda: progress().get('challenge') == 2, 'Real Host did not require TOTP')
            state = progress()
            assert state['password_attempts'] == 2 and state['frames'] == 0 and not state['presented']
            assert state['authentication_visible'] and secrets.lookup(initial['server']) is None
            worker = children(gui.pid)
            assert len(worker) == 1 and worker[0] not in workers
            workers.add(worker[0])
            tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'], text=True)
            match = re.search(r'(0x[0-9a-f]+) "FarPane"', tree)
            assert match
            screen.focus(int(match[1], 16))
            time.sleep(.2)  # Allow the real GTK frame clock to paint the challenge.
            screen.capture(directory / 'challenge.png')
            assert colored_pixels(screen.capture(), color) < 1000
            (directory / 'challenge.json').write_text(json.dumps(state, indent=2) + '\n')
            if scenario == 'cancel':
                screen.click((80, 28))
            else:
                before = sum(e['event']['type'] == 'authentication_challenge' for e in state['events'])
                # Guarantee a wrong numeric code throughout the retry interval,
                # including the Host's permitted +/- one TOTP time step.
                valid = {otp(time.time() + delta) for delta in range(-60, 91, 30)}
                wrong = next(f'{n:06}' for n in range(1000000) if f'{n:06}' not in valid)
                screen.type(wrong)
                screen.key(0xff0d, True); screen.key(0xff0d, False)
                wait(lambda: progress().get('challenge') == 2 and
                     sum(e['event']['type'] == 'authentication_challenge' for e in progress()['events']) > before,
                     'Wrong TOTP did not return a retry challenge')
                state = progress()
                assert state['frames'] == 0 and not state['presented']
                assert secrets.lookup(initial['server']) is None, 'Password stored before TOTP success'
                (directory / 'wrong-code.json').write_text(json.dumps(state, indent=2) + '\n')
                screen.capture(directory / 'wrong-code.png')
                if os.environ.get('FARPANE_TWO_FACTOR_MALFORMED') == '1':
                    for invalid in ('letters', '12345678901234567'):
                        screen.type(invalid)
                        screen.key(0xff0d, True); screen.key(0xff0d, False)
                        time.sleep(.4)
                        state = progress()
                        (directory / ('invalid-' + str(len(invalid)) + '.json')).write_text(
                            json.dumps(state, indent=2) + '\n')
                        screen.capture(directory / ('invalid-' + str(len(invalid)) + '.png'))
                        assert state['challenge'] == 2 and state['authentication_visible'], \
                            'Malformed verification code hid the retry form'
                        assert not state['presented'] and secrets.lookup(initial['server']) is None
                        # Replace the rejected text using the ordinary entry.
                        screen.key(0xffe3, True)
                        screen.key(ord('a'), True); screen.key(ord('a'), False)
                        screen.key(0xffe3, False)
                        screen.key(0xff08, True); screen.key(0xff08, False)
                code = otp(time.time())
                screen.type(code)
                screen.key(0xff0d, True); screen.key(0xff0d, False)
                wait(lambda: progress().get('presented'), 'Valid TOTP did not produce a frame')
                pixels = wait(lambda: (n if (n := colored_pixels(screen.capture(), color)) > 15000 else 0),
                              'Authenticated remote pixels were not displayed')
                state = progress()
                assert state['challenge'] == 0 and not state['authentication_visible']
                wait(lambda: secrets.lookup(initial['server']) == 'native-viewer-smoke',
                     'Permanent password was not saved after complete authentication')
                assert cli({'type': 'snapshot'})['inbound'][0]['authorized']
                screen.capture(directory / 'streaming.png')
                (directory / 'streaming.json').write_text(json.dumps(state, indent=2) + '\n')
                screen.click((80, 28))
            assert gui.wait(timeout=12) == 0
            assert agent.poll() is None and not Path(f'/proc/{worker[0]}').exists()
            deadline = time.monotonic() + 5
            while cli({'type': 'snapshot'})['inbound']:
                assert time.monotonic() < deadline, 'Host retained terminated connection'
                time.sleep(.05)
            result = json.loads((directory / 'viewer.json').read_text())
            assert result['worker_reaped'] and result['presented'] == (index == 1)
            assert (result['frames'] > 0) == (index == 1)
            secrets.verify(index == 1)
            after = cli({'type': 'snapshot'})
            assert after['revision'] == initial['revision'] + index
            for key in ('local_id', 'host_enabled', 'authentication', 'permanent_password_set',
                        'temporary_password', 'server', 'sharing', 'gpu_enabled'):
                assert after[key] == initial[key], key
            assert 'CRITICAL' not in (output / ('two-factor-' + scenario + '.log')).read_text()
            record = {'scenario': scenario, 'worker_pid': worker[0], 'worker_reaped': True,
                      'presented': result['presented'], 'frames': result['frames'],
                      'host_survived': True, 'totp_saved_as_password': False,
                      'matching_remote_pixels': pixels if index == 1 else 0}
            rounds.append(record)
            print(json.dumps(record), flush=True)
        report = {'result': 'pass', 'checks': ['real-host-totp-challenge', 'cancel-before-totp-no-video',
                  'cancel-reaps-worker', 'wrong-numeric-code-retry', 'correct-code-real-presentation',
                  'no-password-save-before-totp', 'save-password-not-otp', 'auth-panel-cleared',
                  'host-identity-preserved'], 'rounds': rounds, 'gpu_tested': False,
                  'real_desktop_tested': False, 'test_runner_rebuilds_product': False,
                  'malformed_code_retry_tested': os.environ.get('FARPANE_TWO_FACTOR_MALFORMED') == '1',
                  'host_2fa_enrollment_ui_tested': False}
        (output / 'two-factor-result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report), flush=True)
    finally:
        remote.x.XDestroyWindow(remote.display, pattern)
        screen.close(); remote.close()


def exercise_file_auth(output, agent, initial, secrets):
    """Continue the normal upload/download/consent test after real TOTP input."""
    from native_files_smoke import exercise_files
    screen = Display(':92')
    exercised = False
    def driver(directory, gui, progress):
        nonlocal exercised
        if exercised or progress.get('challenge') != 2:
            return
        assert progress['authentication_visible'] and progress['password_attempts'] == 2
        assert secrets.lookup(initial['server']) is None
        def read():
            try:
                return json.loads((directory / 'files-progress.json').read_text())
            except json.JSONDecodeError:
                return {}
        def count(row):
            return sum(e['event']['type'] == 'authentication_challenge' for e in row.get('events', []))
        def wait(predicate, message):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                assert gui.poll() is None and agent.poll() is None
                row = read()
                if predicate(row):
                    return row
                time.sleep(.04)
            screen.capture(directory / 'two-factor-failure.png')
            raise AssertionError(message)
        tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'], text=True)
        match = re.search(r'(0x[0-9a-f]+) "FarPane 文件', tree)
        assert match
        screen.focus(int(match[1], 16))
        time.sleep(.2)
        screen.capture(directory / 'two-factor-challenge.png')
        previous = count(progress)
        valid = {otp(time.time() + delta) for delta in range(-60, 91, 30)}
        wrong = next(f'{n:06}' for n in range(1000000) if f'{n:06}' not in valid)
        screen.type(wrong)
        screen.key(0xff0d, True); screen.key(0xff0d, False)
        progress = wait(lambda r: r.get('challenge') == 2 and count(r) > previous,
                        'File connection did not retry wrong TOTP')
        assert not any(e['event']['type'] == 'directory' for e in progress['events'])
        for invalid in ('letters', '12345678901234567'):
            before = count(progress)
            screen.type(invalid)
            screen.key(0xff0d, True); screen.key(0xff0d, False)
            progress = wait(lambda r: '验证码须为数字' in r.get('status', ''),
                            'File verification format hint missing')
            assert progress['challenge'] == 2 and progress['authentication_visible']
            assert count(progress) == before and secrets.lookup(initial['server']) is None
            assert not any(e['event']['type'] == 'directory' for e in progress['events'])
            time.sleep(.2)
            screen.capture(directory / ('two-factor-invalid-' + str(len(invalid)) + '.png'))
            (directory / ('two-factor-invalid-' + str(len(invalid)) + '.json')).write_text(
                json.dumps(progress, indent=2) + '\n')
            screen.key(0xffe3, True)
            screen.key(ord('a'), True); screen.key(ord('a'), False)
            screen.key(0xffe3, False)
            screen.key(0xff08, True); screen.key(0xff08, False)
        screen.type(otp(time.time()))
        screen.key(0xff0d, True); screen.key(0xff0d, False)
        progress = wait(lambda r: any(e['event']['type'] == 'directory' for e in r.get('events', [])),
                        'Correct TOTP did not allow directory listing')
        assert not progress['authentication_visible']
        (directory / 'two-factor-authenticated.json').write_text(json.dumps(progress, indent=2) + '\n')
        exercised = True
    try:
        exercise_files(output, agent, auth_driver=driver)
        assert exercised, 'File challenge was bypassed'
        secrets.verify(True)
        result = {'result': 'pass', 'real_host_totp': True, 'wrong_code_retry': True,
                  'malformed_code_form_retained': True, 'oversized_code_form_retained': True,
                  'no_listing_before_totp': True, 'saved_password_not_otp': True,
                  'ordinary_file_roundtrip_and_consent_checks': True,
                  'gui_and_worker_exited': True, 'host_survived': agent.poll() is None,
                  'gpu_tested': False, 'real_desktop_tested': False}
        (output / 'two-factor-files-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    finally:
        screen.close()
