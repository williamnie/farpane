"""Exercise the actual app in an isolated container, without network/display/GPU."""
import json
from pathlib import Path
import subprocess
import tomllib

assert Path('/.dockerenv').exists()
config = Path('/root/.config/farpane')


def run(flag):
    result = subprocess.run(['/app/farpane', flag], check=True, capture_output=True,
                            text=True, timeout=15)
    return json.loads(result.stdout)


paths = run('--farpane-paths')
assert paths['app_name'] == 'FarPane'
assert not config.exists(), 'Path diagnostic must not initialize an identity'
fresh = run('--farpane-identity')
assert 1_000_000_000 <= int(fresh['id']) < 2_000_000_000
assert fresh['identity_version'] == '1'
assert fresh == run('--farpane-identity'), 'Fresh identity changed on restart'
print('PASS fresh independent ID persists across app restart')

# Model the reported collision in the disposable FarPane config only.
(config / 'FarPane.toml').write_text('id = "26140219"\n')
(config / 'FarPane2.toml').write_text(
    '[options]\nlinux-gpu-media = "Y"\ncustom-rendezvous-server = "fixture.invalid"\n')
fixed = run('--farpane-identity')
assert fixed['id'] != '26140219'
assert 1_000_000_000 <= int(fixed['id']) < 2_000_000_000
assert fixed['gpu_enabled']
assert fixed['registration_uuid'] == fresh['registration_uuid']
assert fixed == run('--farpane-identity'), 'Migrated identity changed on restart'
options = tomllib.loads((config / 'FarPane2.toml').read_text())['options']
assert options['custom-rendezvous-server'] == 'fixture.invalid'
assert not Path('/root/.config/rustdesk').exists()
print('PASS legacy colliding ID migrated locally; restart, GPU and server options preserved')
