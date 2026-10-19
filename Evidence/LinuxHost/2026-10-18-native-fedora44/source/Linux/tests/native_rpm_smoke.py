"""Actual RPM transactions and GUI sessions in a disposable Fedora container."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

assert os.geteuid() == 0 and Path('/.dockerenv').is_file()
assert not Path('/dev/dri').exists()
assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
sys.path.insert(0, '/workspace/Linux/packaging')
import native_bundle
from native_install import Store

output = Path(sys.argv[1])
uid, gid = int(sys.argv[2]), int(sys.argv[3])
packages = [Path(p).resolve(strict=True) for p in sys.argv[4:]]
assert len(packages) == 2 and all(p.is_relative_to(Path('/workspace/Build/Linux/rpm')) for p in packages)
assert output.is_relative_to(Path('/workspace/Build/Linux/native-rpm-smoke'))
output.mkdir(parents=True)
os.chown(output, uid, gid)
(output / 'os-release.txt').write_bytes(Path('/etc/os-release').read_bytes())
package_name = 'farpane-native-candidate'
prefix = Path('/usr/lib64') / package_name
payload = prefix / 'payload'
store = Store()
assert not store.base.exists() and not prefix.exists()
checks = []


def run(*args, ok=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    with (output / 'rpm.log').open('a') as stream:
        stream.write(json.dumps({'argv': args, 'exit': result.returncode}) + '\n')
        stream.write(result.stdout + result.stderr)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
    return result.stdout


def verify_installed():
    assert run('rpm', '--verify', package_name) == ''
    manifest = native_bundle.verify(payload)
    metadata = json.loads((prefix / 'candidate.json').read_text())
    assert metadata['artifact_id'] == manifest['artifact_id']
    assert not metadata['automatic_stage'] and not metadata['automatic_activation']
    for name, digest in metadata['installer_sources'].items():
        assert native_bundle.digest(prefix / 'control' / name) == digest
    assert not list(prefix.rglob('__pycache__'))
    return manifest


for package in packages:
    assert run('rpm', '-qp', '--scripts', str(package)) == ''
    provides = run('rpm', '-qp', '--provides', str(package)).splitlines()
    assert len(provides) == 2 and all(p.startswith(package_name) for p in provides)

# Dependency enforcement is left on. The runtime image contains no RustDesk,
# system FFmpeg, compiler or extra application build dependencies.
run('rpm', '--install', str(packages[0]))
manifest = verify_installed()
assert not store.base.exists()
assert not Path('/etc/systemd/system/farpane.service').exists()
checks.append('real_rpm_install_enforces_dependencies_without_staging_or_activation')
run('/usr/bin/farpane-maintenance', '--help')
run('/usr/bin/farpane-user-integration', '--help')
checks.append('standalone_maintenance_tools_and_exact_payload_sources')

# A private pre-existing installation and unrelated service, never host paths.
store.units.mkdir(parents=True, exist_ok=True)
store.initialize()
old = store.base / 'releases/farpane-retained-test'
old.mkdir()
shutil.copy2('/bin/bash', old / 'farpane')
(store.base / 'current').symlink_to('releases/' + old.name)
unit = store.units / 'farpane.service'
unit.write_text('# private pre-existing service sentinel\n')
unrelated = store.units / 'rustdesk.service'
unrelated.write_text('# private unrelated service sentinel\n')
config = Path('/run/farpane-native-test/retained-configuration')
config.write_text('synthetic preserved configuration\n')
before = {p: p.read_bytes() for p in (unit, unrelated, config, old / 'farpane')}
sentinel = subprocess.Popen([str(old / 'farpane'), '--noprofile', '--norc', '-c', 'read sentinel_line'],
                            stdin=subprocess.PIPE)


def preserved():
    assert store.current() == old.name and sentinel.poll() is None
    assert before == {p: p.read_bytes() for p in before}


try:
    run('/usr/bin/farpane-maintenance', 'stage', str(payload))
    staged = store.base / '.staged' / manifest['artifact_id']
    assert native_bundle.verify(staged) == manifest
    preserved()
    checks.append('explicit_staging_preserves_current_process_units_and_configuration')

    # An RPM upgrade is independent of an unfinished activation transaction.
    # Explicit staging must still refuse until the transaction is resolved.
    store.journal.write_text('private pending-transaction fixture\n')
    run('rpm', '--upgrade', str(packages[1]))
    upgraded_manifest = verify_installed()
    assert manifest['artifact_id'] != upgraded_manifest['artifact_id']
    assert store.journal.read_text() == 'private pending-transaction fixture\n'
    version = run('rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}', package_name)
    assert version == run('rpm', '-qp', '--qf', '%{VERSION}-%{RELEASE}', str(packages[1]))
    upgraded_staged = store.base / '.staged' / upgraded_manifest['artifact_id']
    assert not upgraded_staged.exists()
    run('/usr/bin/farpane-maintenance', 'stage', str(payload), ok=False)
    assert not upgraded_staged.exists()
    preserved()
    checks.append('rpm_upgrade_preserves_pending_transaction_and_explicit_stage_refuses')
    store.journal.unlink()
    run('/usr/bin/farpane-maintenance', 'stage', str(payload))
    assert native_bundle.verify(upgraded_staged) == upgraded_manifest
    assert native_bundle.verify(staged) == manifest
    preserved()
    checks.append('explicit_upgrade_staging_retains_both_verified_candidates')

    import native_viewer_smoke
    from native_host_smoke import RELEASE
    def stage_installed_payload():
        assert native_bundle.verify(payload) == upgraded_manifest
        shutil.copytree(payload, RELEASE, symlinks=True)
        assert native_bundle.verify(RELEASE) == upgraded_manifest
    native_viewer_smoke.stage_release = stage_installed_payload
    os.environ['FARPANE_NATIVE_TEST_MODE'] = 'video'
    try:
        native_viewer_smoke.setup(output / 'viewer', uid, gid)
    except SystemExit as result:
        assert result.code == 0, result.code
    preserved()
    checks.append('rpm_gui_two_real_video_sessions_and_worker_reaping')
    run('rpm', '--erase', package_name)
    assert not prefix.exists()
    assert not Path('/usr/bin/farpane-maintenance').exists()
    assert not Path('/usr/bin/farpane-user-integration').exists()
    assert native_bundle.verify(staged) == manifest
    assert native_bundle.verify(upgraded_staged) == upgraded_manifest
    preserved()
    checks.append('rpm_erase_removes_candidate_and_retains_active_process_units_and_data')
    result = {'result': 'pass', 'checks': checks, 'artifact_id': upgraded_manifest['artifact_id'],
              'initial_artifact_id': manifest['artifact_id'], 'installed_version': version,
              'packages': {p.name: native_bundle.digest(p) for p in packages},
              'gpu': False, 'host_modified': False, 'systemd_activation_tested': False,
              'selinux_desktop_tested': False,
              'preserved_process': 'private shell blocked on a pipe, not an actual installed service'}
    (output / 'rpm-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
finally:
    sentinel.terminate()
    sentinel.wait(timeout=5)
