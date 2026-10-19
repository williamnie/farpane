"""Assemble a guest disk in an owned container; no host filesystem mount."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

assert os.geteuid() == 0 and Path('/.dockerenv').is_file()
assert not any(Path(p).exists() for p in ('/dev/kvm', '/dev/uinput', '/dev/dri'))
output = Path(sys.argv[1])
uid, gid = map(int, sys.argv[2:4])
artifact = Path(sys.argv[4])
sys.path.insert(0, '/workspace/Linux/packaging')
import native_bundle
manifest = native_bundle.verify(artifact)
guest = Path('/guest-root')
guest.mkdir()
subprocess.run(['tar', '--extract', '--preserve-permissions', '--file', '/input/rootfs.tar',
                '--directory', str(guest)], check=True)
(guest / '.dockerenv').unlink(missing_ok=True)
release = guest / 'opt/farpane-native-test/releases' / manifest['artifact_id']
shutil.copytree(artifact, release, symlinks=True)
assert native_bundle.verify(release) == manifest
(guest / 'opt/farpane').mkdir()
(guest / 'opt/farpane/current').symlink_to('../farpane-native-test/releases/' + release.name)
# Existing packaged GUI smoke activation requires both this marker and the
# native-test release path. This is explicitly a guest test fixture, not Docker
# isolation; the launcher/PID-1 marker and separate kernel establish isolation.
(guest / '.dockerenv').touch()
test = guest / 'opt/farpane-input-test'
test.mkdir()
shutil.copy2('/workspace/Linux/tests/native_input_vm_init.py', test / 'init.py')
(test / 'init.py').chmod(0o755)
for name in ('native_input_vm_service.py', 'native_input_vm_desktop.py',
             'native_input_vm_network.py', 'native_input_vm_wire.py', 'native_gnome_input_smoke.py',
             'native_maintenance_vm.py', 'native_desktop_launch_vm.py', 'native_desktop_lifecycle_vm.py'):
    shutil.copy2('/workspace/Linux/tests/'+name, test/name)
stage = sys.argv[5]
target = sys.argv[6]
input_driver = sys.argv[7]
packages = [Path(p).resolve(strict=True) for p in sys.argv[8:]]
maintenance = bool(packages)
launch_probe = os.environ.get('FARPANE_VM_DESKTOP_LAUNCH')=='1'
lifecycle_probe = os.environ.get('FARPANE_VM_DESKTOP_LIFECYCLE')=='1'
index_settle = int(os.environ.get('FARPANE_VM_DESKTOP_INDEX_SETTLE', '0'))
assert index_settle in (0, 7) and (index_settle == 0 or lifecycle_probe or launch_probe)
launch_transport = os.environ.get('FARPANE_VM_DESKTOP_LAUNCH_TRANSPORT', 'original')
assert launch_transport in ('original', 'exec') and (launch_transport == 'original' or launch_probe)
assert not (launch_probe and lifecycle_probe)
assert not (launch_probe or lifecycle_probe) or maintenance
assert not maintenance or (len(packages)==2 and stage=='desktop' and target=='entry' and input_driver=='gtk')
package_records=[]
if maintenance:
    # The fixture's compatibility symlink must not masquerade as an installed
    # maintenance store. Real package commands create their own /opt/farpane.
    (guest/'opt/farpane/current').unlink()
    (guest/'opt/farpane').rmdir()
    directory=test/'packages';directory.mkdir()
    for index,package in enumerate(packages):
        assert package.is_relative_to(Path('/workspace/Build/Linux/debian')) and package.suffix=='.deb'
        destination=directory/f'{index}.deb';shutil.copyfile(package,destination)
        package_records.append({'file':destination.name,'source':str(package),
                                'sha256':hashlib.sha256(destination.read_bytes()).hexdigest()})
assert stage in ('bootstrap','service','viewer-notice','viewer','desktop')
assert target in ('entry','terminal','browser') and (target=='entry' or stage=='desktop')
assert input_driver in ('gtk','wire') and (input_driver=='gtk' or stage=='desktop')
pin = json.loads(Path('/workspace/Linux/tests/native-input-vm.lock.json').read_text())
if input_driver=='wire':
    for entry in pin['wire_reference_sources']:
        assert hashlib.sha256((Path('/workspace')/entry['path']).read_bytes()).hexdigest()==entry['sha256']
browser_hash=None
if target=='browser':
    source=Path('/input/chrome');rows=[]
    for path in sorted(source.rglob('*')):
        name=str(path.relative_to(source))
        if path.is_symlink():
            assert path.resolve().is_relative_to(source)
            rows.append([name,'symlink',str(path.readlink())])
        elif path.is_file():
            with path.open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest()
            rows.append([name,'file',path.stat().st_mode&0o777,path.stat().st_size,sha])
    browser_hash=hashlib.sha256(json.dumps(rows,separators=(',',':')).encode()).hexdigest()
    assert browser_hash==pin['browser_program_manifest_sha256']
    shutil.copytree(source,guest/'opt/farpane-test-chrome',symlinks=True)
if stage == 'desktop':
    # Only public module bytes in the guest image. No host modprobe, DRM node,
    # initramfs, module directory or credential store is exposed to QEMU.
    for entry in pin['guest_modules']:
        source = Path('/workspace/Build/Linux/native-input-vm/modules')/entry['file']
        data = source.read_bytes()
        assert len(data)==entry['bytes'] and hashlib.sha256(data).hexdigest()==entry['sha256']
        destination = guest/'lib/modules'/pin['kernel']['version']/entry['kernel_path']
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(data)
    subprocess.run(['depmod','-b',str(guest),pin['kernel']['version']],check=True)
    unit_dir = guest/'etc/systemd/system'
    unit_dir.mkdir(parents=True,exist_ok=True)
    for name in ('farpane-input-test.target','farpane-input-test.service','farpane-input-session.service'):
        shutil.copy2('/workspace/Linux/tests/input-vm/'+name,unit_dir/name)
    if maintenance:
        controller=unit_dir/'farpane-input-test.service'
        controller.write_text(controller.read_text().replace('native_input_vm_desktop.py','native_maintenance_vm.py')
                              .replace('TimeoutStartSec=140','TimeoutStartSec=260'))
        session_unit=unit_dir/'farpane-input-session.service'
        session_unit.write_text(session_unit.read_text()+'\nStandardOutput=journal\nStandardError=journal\n')
    (unit_dir/'serial-getty@ttyS0.service').symlink_to('/dev/null')
    shutil.copy2('/workspace/Linux/tests/input-vm/pam-session',guest/'etc/pam.d/farpane-input-test')
    (guest/'etc/udev/rules.d').mkdir(parents=True,exist_ok=True)
    rules=(guest/'usr/lib/udev/rules.d/61-mutter.rules').read_text().splitlines()
    ignored={'ENV{ID_PATH}=="platform-vkms", TAG+="mutter-device-ignore"',
             'ENV{DEVPATH}=="/devices/faux/vkms/drm/card[0-9]*", TAG+="mutter-device-ignore"'}
    assert set(line for line in rules if 'mutter-device-ignore' in line)==ignored
    # Remove only the two VKMS ignore rules before any add event. In the
    # recorded failed run, a later TAG-= override did not unignore this device.
    (guest/'etc/udev/rules.d/61-mutter.rules').write_text('\n'.join(line for line in rules if line not in ignored)+'\n')
else:
    # Controlled loginctl remains only for the earlier, explicitly scoped tests.
    shutil.copy2('/workspace/Linux/tests/native_service_loginctl.py', guest/'usr/bin/loginctl')
    (guest/'usr/bin/loginctl').chmod(0o755)
marker = {'isolation': 'guest-kernel-uinput', 'artifact': manifest['artifact_id'], 'stage':stage,'target':target,'input_driver':input_driver,
          'scenario':'maintenance' if maintenance else 'input','maintenance_packages':package_records,
          'desktop_launch_probe':launch_probe,'desktop_lifecycle_probe':lifecycle_probe,
          'desktop_index_settle_seconds':index_settle,'desktop_launch_transport':launch_transport}
(guest / '.farpane-input-vm').write_text(json.dumps(marker) + '\n')
# Exported container hostnames/resolvers are not guest configuration inputs.
for name, value in [('etc/hostname', 'farpane-input-vm\n'), ('etc/resolv.conf', ''),
                    ('etc/hosts', '127.0.0.1 localhost farpane-input-vm\n')]:
    path = guest / name
    path.unlink(missing_ok=True)
    path.write_text(value)
image = output / 'guest-root.raw'
with image.open('xb') as stream:
    stream.truncate(8 * 1024**3)
subprocess.run(['mkfs.ext4', '-F', '-q', '-L', 'farpane-input-vm',
                '-d', str(guest), str(image)], check=True)
os.chown(image, uid, gid)
metadata = {'artifact': manifest['artifact_id'], 'disk_bytes': image.stat().st_size,
            'stage':stage,
            'scenario':marker['scenario'],'maintenance_packages':package_records,
            'desktop_launch_probe':launch_probe,
            'desktop_lifecycle_probe':lifecycle_probe,
            'desktop_index_settle_seconds':index_settle,
            'desktop_launch_transport':launch_transport,
            'target':target,'browser_program_manifest_sha256':browser_hash,
            'input_driver':input_driver,
            'wire_reference_sources':pin['wire_reference_sources'] if input_driver=='wire' else [],
            'runtime_image': pin['image'],
            'guest_modules': pin['guest_modules'] if stage=='desktop' else [],
            'guest_unit_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in Path('/workspace/Linux/tests/input-vm').iterdir()} if stage=='desktop' else {},
            'guest_mutter_rules_sha256': hashlib.sha256((guest/'etc/udev/rules.d/61-mutter.rules').read_bytes()).hexdigest() if stage=='desktop' else None,
            'guest_init_sha256': hashlib.sha256((test/'init.py').read_bytes()).hexdigest(),
            'guest_test_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in test.iterdir() if p.is_file()},
            'guest_actual_unit_sha256': {name:hashlib.sha256((guest/'etc/systemd/system'/name).read_bytes()).hexdigest()
                for name in ('farpane-input-test.target','farpane-input-test.service','farpane-input-session.service')} if stage=='desktop' else {},
            'loginctl_sha256': hashlib.sha256((guest/'usr/bin/loginctl').read_bytes()).hexdigest(),
            'loginctl_provider': 'systemd' if stage=='desktop' else 'controlled-fixture',
            'rootfs_source_sha256': hashlib.file_digest(Path('/input/rootfs.tar').open('rb'), 'sha256').hexdigest(),
            'no_host_mount_or_input_device': True}
record = output / 'disk.json'
record.write_text(json.dumps(metadata, indent=2) + '\n')
os.chown(record, uid, gid)
print(json.dumps(metadata), flush=True)
