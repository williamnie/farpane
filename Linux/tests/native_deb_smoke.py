"""Actual dpkg transactions and GUI sessions, confined to an owned container."""
import hashlib
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
assert len(packages) == 2 and all(p.is_relative_to(Path('/workspace/Build/Linux/debian')) for p in packages)
output.mkdir(parents=True)
os.chown(output, uid, gid)
(output / 'os-release.txt').write_bytes(Path('/etc/os-release').read_bytes())
package_name = 'farpane-native-candidate'
prefix = Path('/usr/lib') / package_name
payload = prefix / 'payload'
store = Store()
assert not store.base.exists()
store.units.mkdir(parents=True, exist_ok=True)
store.initialize()
old = store.base / 'releases/farpane-retained-test'
old.mkdir()
shutil.copy2('/bin/dash', old / 'farpane')
(store.base / 'current').symlink_to('releases/' + old.name)
unit = store.units / 'farpane.service'
unit.write_text('# private pre-existing service sentinel\n')
unrelated = store.units / 'rustdesk.service'
unrelated.write_text('# private unrelated service sentinel\n')
config = Path('/run/farpane-native-test/retained-configuration')
config.write_text('synthetic preserved configuration\n')
before = {p: p.read_bytes() for p in (unit, unrelated, config, old / 'farpane')}
sentinel = subprocess.Popen([str(old / 'farpane'), '-c', 'read sentinel_line'], stdin=subprocess.PIPE)
checks = []


def run(*args, ok=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90,
                            env=dict(os.environ, DEBIAN_FRONTEND='noninteractive'))
    with (output / 'dpkg.log').open('a') as stream:
        stream.write(json.dumps({'argv': args, 'exit': result.returncode}) + '\n')
        stream.write(result.stdout + result.stderr)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
    return result.stdout


def preserved():
    assert store.current() == old.name and sentinel.poll() is None
    assert before == {p: p.read_bytes() for p in before}


try:
    run('dpkg', '--install', str(packages[0]))
    assert run('dpkg-query', '-W', '-f=${Status}', package_name) == 'install ok installed'
    manifest = native_bundle.verify(payload)
    staged = store.base / '.staged' / manifest['artifact_id']
    assert native_bundle.verify(staged) == manifest
    preserved()
    checks.append('real_dpkg_install_declared_dependencies_and_private_staging')
    run('/usr/bin/farpane-maintenance', '--help')
    run('/usr/bin/farpane-user-integration', '--help')
    assert not list(prefix.rglob('__pycache__'))
    metadata = json.loads((prefix / 'candidate.json').read_text())
    for name, expected in metadata['installer_sources'].items():
        assert native_bundle.digest(prefix / 'control' / name) == expected
    checks.append('standalone_installer_commands_and_exact_sources')

    # A pending maintenance transaction must prevent automatic staging; dpkg
    # can resume configuration once the separate transaction is resolved.
    store.journal.write_text('private pending-transaction fixture\n')
    run('dpkg', '--install', str(packages[1]), ok=False)
    assert store.journal.read_text() == 'private pending-transaction fixture\n'
    preserved()
    checks.append('pending_maintenance_refuses_package_configuration_without_switching')
    store.journal.unlink()
    run('dpkg', '--configure', package_name)
    installed_version = run('dpkg-query', '-W', '-f=${Version}', package_name)
    assert installed_version == run('dpkg-deb', '-f', str(packages[1]), 'Version').strip()
    upgraded_manifest = native_bundle.verify(payload)
    upgraded_metadata = json.loads((prefix / 'candidate.json').read_text())
    assert upgraded_metadata['artifact_id'] == upgraded_manifest['artifact_id']
    upgraded_staged = store.base / '.staged' / upgraded_manifest['artifact_id']
    assert native_bundle.verify(upgraded_staged) == upgraded_manifest
    assert native_bundle.verify(staged) == manifest
    for name, expected in upgraded_metadata['installer_sources'].items():
        assert native_bundle.digest(prefix / 'control' / name) == expected
    preserved()
    checks.append('real_dpkg_upgrade_and_configuration_retry_preserve_active_release')

    # Run the upgraded payload, including upgrades that change the application
    # artifact rather than only the Debian package version. The fixture owns
    # the root-owned execution copy and both private X servers.
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
    checks.append('upgraded_deb_gui_two_real_video_sessions_and_worker_reaping')
    run('dpkg', '--purge', package_name)
    assert not prefix.exists()
    assert not Path('/usr/bin/farpane-maintenance').exists()
    assert not Path('/usr/bin/farpane-user-integration').exists()
    assert native_bundle.verify(staged) == manifest
    assert native_bundle.verify(upgraded_staged) == upgraded_manifest
    preserved()
    checks.append('purge_removes_candidate_tools_preserves_release_process_units_and_configuration')
    result = {'result': 'pass', 'checks': checks, 'artifact_id': upgraded_manifest['artifact_id'],
              'initial_artifact_id': manifest['artifact_id'],
              'packages': {p.name: native_bundle.digest(p) for p in packages},
              'gpu': False, 'host_modified': False, 'systemd_activation_tested': False,
              'preserved_process': 'private shell blocked on a pipe, not an actual installed service'}
    (output / 'deb-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
finally:
    sentinel.terminate()
    sentinel.wait(timeout=5)
